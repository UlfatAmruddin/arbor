import Foundation

/// Copies one item with copyfile(3); worker thread only, so blocking is fine (FE-123, FE-124).
/// Flags: ALL (creation date restored after), CLONE, DATA_SPARSE, NOFOLLOW, EXCL (never overwrites).
/// Hard links become independent files. Folders are walked here so pause/cancel/skip work per file;
/// packages are all-or-nothing. Partial files are removed only if provably ours (same inode).
final class CopyEngine {
    struct Hooks {
        /// Delta since the last call; negative when a failed file is un-counted.
        var bytes: (Int64) -> Void = { _ in }
        /// An entry finished or was skipped.
        var entryDone: (_ totals: TransferTotals) -> Void = { _ in }
        var current: (URL) -> Void = { _ in }
        /// Blocking.
        var failure: (TransferFailure) -> FailureDecision = { _ in FailureDecision(.skip) }
        /// Problems below the top-level item.
        var detail: (ItemResult) -> Void = { _ in }
        /// Blocking: the destination can't hold the file's properties.
        var metadata: (_ source: URL, _ target: URL) -> MetadataLossChoice = { _, _ in .copyWithout }
    }

    enum Outcome: Equatable {
        case done
        case partial
        case skipped(String)
        case failed(String)
        /// `leftContent`: something this job made is still there.
        case cancelled(leftContent: Bool)
    }

    let control: TransferControl
    let allowClone: Bool
    var hooks = Hooks()
    /// For disk-full messages.
    var bytesRemaining: () -> Int64? = { nil }
    /// False once the job's destination is no longer on the volume it started on.
    var destinationIsIntact: () -> Bool = { true }
    /// The folder the job writes into, to tell a problem with it from one with a folder inside it.
    var jobDestination: URL?
    /// Testing: caps the rate so progress, pause and cancel can be observed.
    var bytesPerSecondLimit: Int64?
    private var throttleStart: Date?
    private var throttledBytes: Int64 = 0
    private let verb: String

    init(control: TransferControl, allowClone: Bool, verb: String) {
        self.control = control
        self.allowClone = allowClone
        self.verb = verb
    }

    /// `target` must not exist. `moveSource` removes each original after its own copy (FE-122).
    /// `folder`: a descriptor of the source's parent, which the item is then looked up and removed relative to.
    /// `depth`: how many folders down the walk already is.
    func copyItem(_ source: URL, to target: URL, moveSource: Bool, in folder: Int32? = nil, depth: Int = 0) -> Outcome {
        guard control.checkpoint() else { return .cancelled(leftContent: false) }
        let again = { [self] in copyItem(source, to: target, moveSource: moveSource, in: folder, depth: depth) }
        // A leftover mount-point folder accepts writes, which would hide the files under a later remount.
        guard destinationIsIntact() else { return fail(source, target, .copying, errno: ENXIO, retry: again) }
        var info = stat()
        let found = folder.map { fstatat($0, source.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) } ?? lstat(source.path, &info)
        guard found == 0 else {
            return fail(source, target, .copying, errno: errno, retry: again)
        }
        let original = moveSource ? Identity(info) : nil
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // After a parent swap the path judged here may lead elsewhere; only the item found above can be a package.
            var now = stat()
            if Self.isPackage(source), lstat(source.path, &now) == 0, Identity(now) == Identity(info) {
                return copyPackage(source, to: target, identity: Identity(info), original: original, in: folder, depth: depth)
            }
            return copyFolder(source, to: target, identity: Identity(info), original: original, in: folder, depth: depth)
        case S_IFREG, S_IFLNK:
            return copyLeaf(source, to: target, size: (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_size) : 0,
                            original: original, in: folder)
        default:
            hooks.entryDone(TransferTotals(items: 1))
            return .skipped(L10n.tr("Special files (pipes, sockets, devices) aren't copied."))
        }
    }

    /// Device and inode, to tell whether a path still leads to the same item.
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        init(_ info: stat) {
            device = UInt64(bitPattern: Int64(info.st_dev))
            inode = UInt64(info.st_ino)
        }
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    // MARK: Files and links

    private func copyLeaf(_ source: URL, to target: URL, size: Int64, original: Identity?, in folder: Int32?) -> Outcome {
        if let early = checkMetadata(source, target, totals: TransferTotals(items: 1, bytes: size)) { return early }
        while true {
            hooks.current(source)
            let error = copyData(source, to: target, size: size, expected: original)
            if error == 0 { break }
            if error == ECANCELED, control.isCancelled { return .cancelled(leftContent: false) }
            switch decide(source, target, .copying, error) {
            case .retry: continue
            case .skip(let why):
                hooks.entryDone(TransferTotals(items: 1, bytes: size))
                return .failed(why)
            case .cancel: return .cancelled(leftContent: false)
            }
        }
        hooks.entryDone(TransferTotals(items: 1))
        if let original { removeOriginal(source, copiedTo: target, isFolder: false, original: original, in: folder) }
        return .done
    }

    /// 0 or an errno; never leaves a partial file. `expected`: refuse (ENOENT) if the path now opens another item.
    func copyData(_ source: URL, to target: URL, size: Int64, expected: Identity? = nil) -> Int32 {
        guard let state = copyfile_state_alloc() else { return ENOMEM }
        defer { copyfile_state_free(state) }
        let context = CallbackContext(engine: self)
        context.expected = expected
        var flags = COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_DATA_SPARSE
        // Moves only come here across volumes, where a clone can't happen; a clone would skip the source check.
        if allowClone, expected == nil { flags |= COPYFILE_CLONE }
        let result: Int32 = withExtendedLifetime(context) {
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
            return copyfile(source.path, target.path, state, copyfile_flags_t(flags))
        }
        var error = result == 0 ? 0 : errno
        if error != 0, let reportedError = context.failure, reportedError != 0 { error = reportedError }
        if context.sourceChanged { error = ENOENT }
        if error == 0 {
            var cloned: Int32 = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &cloned)
            if cloned == 0 { Self.restoreCreationDate(from: source, to: target) }
            // Clones and sparse holes under-report bytes.
            if size > context.reported { hooks.bytes(size - context.reported) }
            return 0
        }
        if context.reported > 0 { hooks.bytes(-context.reported) }
        if let identity = context.destination, FileStamp(target).map({ $0.device == identity.device && $0.inode == identity.inode }) == true {
            unlink(target.path)
        }
        return error == EEXIST ? EEXIST : (error == 0 ? EIO : error)
    }

    final class CallbackContext {
        unowned let engine: CopyEngine
        var reported: Int64 = 0
        var destination: (device: UInt64, inode: UInt64)?
        var failure: Int32?
        var expected: Identity?
        var sourceChanged = false
        init(engine: CopyEngine) { self.engine = engine }

        func handle(_ what: Int32, _ stage: Int32, _ state: copyfile_state_t?) -> Int32 {
            if destination == nil, stage == COPYFILE_START, let state {
                var fd: Int32 = -1
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &fd) == 0, fd >= 0 {
                    var info = stat()
                    if fstat(fd, &info) == 0 { destination = (UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino)) }
                }
            }
            if sourceChanged { return COPYFILE_QUIT }   // stops the data stage before it copies someone else's file
            if let wanted = expected, stage == COPYFILE_START, let state {
                expected = nil
                // A parent swapped for a link after the item was examined leads the path to someone else's file.
                var fd: Int32 = -1
                var info = stat()
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_SRC_FD), &fd) == 0, fd >= 0,
                   fstat(fd, &info) == 0, Identity(info) != wanted {
                    sourceChanged = true   // copyfile ignores a quit at the extended-attribute stage
                    return COPYFILE_QUIT
                }
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_ERR {
                // copyfile retries a failed write forever on continue (seen with ENOSPC).
                failure = errno
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                let delta = Int64(copied) - reported
                if delta > 0 {
                    reported = Int64(copied)
                    engine.hooks.bytes(delta)
                    engine.throttle(delta)
                }
            }
            return engine.control.checkpoint() ? COPYFILE_CONTINUE : COPYFILE_QUIT
        }
    }

    private func throttle(_ delta: Int64) {
        guard let limit = bytesPerSecondLimit, limit > 0 else { return }
        let start = throttleStart ?? Date()
        throttleStart = start
        throttledBytes += delta
        let due = Double(throttledBytes) / Double(limit)
        let ahead = due - Date().timeIntervalSince(start)
        if ahead > 0 { _ = control.sleep(ahead) }
    }

    static func restoreCreationDate(from source: URL, to target: URL) {
        var info = stat()
        guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return }
        let created = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec) + TimeInterval(info.st_birthtimespec.tv_nsec) / 1e9)
        var values = URLResourceValues()
        values.creationDate = created
        var url = target
        try? url.setResourceValues(values)   // best effort
    }

    /// Asks when the destination can't store the item's properties; nil means go ahead.
    private func checkMetadata(_ source: URL, _ target: URL, totals: TransferTotals?) -> Outcome? {
        switch hooks.metadata(source, target) {
        case .copyWithout: return nil
        case .skip:
            hooks.entryDone(totals ?? TransferDiscovery.measure(source) ?? TransferTotals(items: 1))
            return .skipped(L10n.tr("Skipped: the destination can't keep this item's properties."))
        case .cancel:
            control.cancel()
            return .cancelled(leftContent: false)
        }
    }

    // MARK: Folders

    /// 0 or an errno; past the depth cap nothing is created.
    private func makeFolder(_ target: URL, depth: Int) -> Int32 {
        guard depth < PathLimits.maxFolderDepth else { return ENAMETOOLONG }
        return mkdir(target.path, 0o700) == 0 ? 0 : errno
    }

    private func copyFolder(_ source: URL, to target: URL, identity: Identity, original: Identity?, in parent: Int32?, depth: Int) -> Outcome {
        // The folder's own properties; Skip leaves the whole folder out, as in Explorer.
        if let early = checkMetadata(source, target, totals: nil) { return early }
        while true {
            let error = makeFolder(target, depth: depth)
            if error == 0 { break }
            switch decide(source, target, .creatingFolder, error) {
            case .retry: continue
            case .skip(let why):
                hooks.entryDone(TransferDiscovery.measure(source) ?? TransferTotals(items: 1))
                return .failed(why)
            case .cancel: return .cancelled(leftContent: false)
            }
        }
        // Children are reached through this descriptor, so a folder swapped for a link later is never followed.
        var folder: Int32 = -1
        var names: [String]
        while true {
            let (fd, listed, code) = Self.openFolder(source, in: parent, identity: identity)
            if let listed {
                folder = fd
                names = listed
                break
            } else {
                switch decide(source, target, .readingFolder, code) {
                case .retry: continue
                case .skip(let why):
                    applyFolderMetadata(from: source, to: target)
                    hooks.entryDone(TransferTotals(items: 1))
                    return .failed(why)
                case .cancel:
                    applyFolderMetadata(from: source, to: target)
                    return .cancelled(leftContent: true)
                }
            }
        }
        defer { close(folder) }
        var problems = 0
        var cancelled = false
        for name in names {
            guard control.checkpoint() else { cancelled = true; break }
            let child = source.appendingPathComponent(name)
            let outcome = copyItem(child, to: target.appendingPathComponent(name), moveSource: original != nil, in: folder, depth: depth + 1)
            switch outcome {
            case .done: break
            case .partial: problems += 1
            case .skipped(let why):
                problems += 1
                hooks.detail(ItemResult(source: child, outcome: .skipped(why)))
            case .failed(let why):
                problems += 1
                hooks.detail(ItemResult(source: child, outcome: .failed(why)))
            case .cancelled:
                cancelled = true
            }
            if cancelled { break }
        }
        applyFolderMetadata(from: source, to: target)
        if cancelled { return .cancelled(leftContent: true) }
        hooks.entryDone(TransferTotals(items: 1))
        if let original, problems == 0 { removeOriginal(source, copiedTo: target, isFolder: true, original: original, in: parent) }
        return problems == 0 ? .done : .partial
    }

    /// The folder's descriptor and names while it is still the item with `identity`; else (-1, nil, errno).
    static func openFolder(_ source: URL, in parent: Int32?, identity: Identity) -> (Int32, [String]?, Int32) {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let fd = parent.map { openat($0, source.lastPathComponent, flags) } ?? open(source.path, flags)
        guard fd >= 0 else { return (-1, nil, errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, Identity(info) == identity else { close(fd); return (-1, nil, ENOENT) }
        guard let names = FileOps.entryNames(of: fd) else { let error = errno; close(fd); return (-1, nil, error) }
        return (fd, names, 0)
    }

    /// Applied after the contents so dates stay put and read-only folders can be filled.
    private func applyFolderMetadata(from source: URL, to target: URL) {
        _ = copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
        Self.restoreCreationDate(from: source, to: target)
    }

    // MARK: Packages

    private func copyPackage(_ source: URL, to target: URL, identity: Identity, original: Identity?, in folder: Int32?, depth: Int) -> Outcome {
        if let early = checkMetadata(source, target, totals: nil) { return early }
        while true {
            hooks.current(source)
            let (error, failedAt, bytes, items, created) = copyUnit(source, to: target, identity: identity, moving: original != nil, in: folder, depth: depth)
            if error == 0 {
                hooks.entryDone(TransferTotals(items: items))
                break
            }
            hooks.bytes(-bytes)
            // Only the tree this job made: an item that appeared at the target meanwhile is kept.
            var info = stat()
            if let created, lstat(target.path, &info) == 0, Identity(info) == created {
                try? FileManager.default.removeItem(at: target)
            }
            if error == ECANCELED, control.isCancelled { return .cancelled(leftContent: false) }
            switch decide(failedAt, target, .copying, error) {
            case .retry: continue
            case .skip(let why):
                hooks.entryDone(TransferDiscovery.measure(source) ?? TransferTotals(items: 1))
                return .failed(why)
            case .cancel: return .cancelled(leftContent: false)
            }
        }
        if let original { removeOriginal(source, copiedTo: target, isFolder: false, original: original, in: folder) }
        return .done
    }

    /// No prompts. Walks through descriptors from `folder`, so only the item with `identity` is copied.
    /// Returns (errno or 0, failing path, bytes reported, entries, the root folder it made).
    private func copyUnit(_ source: URL, to target: URL, identity: Identity, moving: Bool, in folder: Int32?, depth: Int) -> (Int32, URL, Int64, Int, Identity?) {
        var reported: Int64 = 0
        var items = 0
        var created: Identity?
        let outer = hooks.bytes
        hooks.bytes = { delta in reported += delta; outer(delta) }
        defer { hooks.bytes = outer }
        func walk(_ src: URL, _ dst: URL, in parent: Int32?, wanted: Identity?, depth: Int) -> (Int32, URL) {
            guard control.checkpoint() else { return (ECANCELED, src) }
            var info = stat()
            let found = parent.map { fstatat($0, src.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) } ?? lstat(src.path, &info)
            guard found == 0 else { return (errno, src) }
            if let wanted, Identity(info) != wanted { return (ENOENT, src) }
            items += 1
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard depth < PathLimits.maxFolderDepth else { return (ENAMETOOLONG, src) }
                let (fd, listed, code) = Self.openFolder(src, in: parent, identity: Identity(info))
                guard let names = listed else { return (code, src) }
                defer { close(fd) }
                guard mkdir(dst.path, 0o700) == 0 else { return (errno, src) }
                if dst == target, lstat(dst.path, &info) == 0 { created = Identity(info) }
                for name in names {
                    let r = walk(src.appendingPathComponent(name), dst.appendingPathComponent(name), in: fd, wanted: nil, depth: depth + 1)
                    if r.0 != 0 { return r }
                }
                applyFolderMetadata(from: src, to: dst)
                return (0, src)
            case S_IFREG, S_IFLNK:
                let e = copyData(src, to: dst, size: (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_size) : 0,
                                 expected: moving ? Identity(info) : nil)
                return (e, src)
            default:
                return (0, src)   // special files inside packages are left out
            }
        }
        let (error, at) = walk(source, target, in: folder, wanted: identity, depth: depth)
        return (error, at, reported, items, created)
    }

    // MARK: Moving

    /// Folders only when empty (bar .DS_Store); never recursive except a fully copied package.
    private func removeOriginal(_ source: URL, copiedTo target: URL, isFolder: Bool, original: Identity, in folder: Int32?) {
        while true {
            guard let error = removeIfUnchanged(source, isFolder: isFolder, original: original, in: folder) else {
                hooks.detail(ItemResult(source: source, outcome: .copiedButSourceRemains(
                    target, L10n.tr("Copied, but the original was replaced during the move, so it was kept."))))
                return
            }
            if error == 0 || error == ENOENT { return }
            switch decide(source, target, .removingSource, error) {
            case .retry: continue
            case .skip, .cancel:
                hooks.detail(ItemResult(source: source, outcome: .copiedButSourceRemains(
                    target, L10n.format("Copied, but the original couldn't be removed. %@", String(cString: strerror(error))))))
                return
            }
        }
    }

    /// 0 or an errno; nil when the path no longer leads to the item that was copied.
    private func removeIfUnchanged(_ source: URL, isFolder: Bool, original: Identity, in folder: Int32?) -> Int32? {
        // unlinkat below stays in this folder; the identity check refuses an item the path no longer leads to.
        let parent = folder.map { dup($0) } ?? open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return errno }
        defer { close(parent) }
        let name = source.lastPathComponent
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
        guard Identity(info) == original else { return nil }
        if isFolder { return FileOps.removeEmptyFolder(name, in: parent, ifStill: { Identity($0) == original }) }
        // A fully copied package: removed level by level from the checked folder, never through a link.
        if (info.st_mode & S_IFMT) == S_IFDIR { return FileOps.removeTree(name, in: parent) }
        return unlinkat(parent, name, 0) == 0 ? 0 : errno
    }

    // MARK: Failures

    enum Resolution { case retry, skip(String), cancel }

    private func decide(_ source: URL, _ target: URL, _ stage: FailureStage, _ error: Int32) -> Resolution {
        // A forced eject surfaces as EIO and the like; only the destination check can say what really happened.
        let writing = stage == .copying || stage == .creatingFolder
        let failure = TransferFailure.classify(errno: error, source: source, destination: target, stage: stage,
                                               bytesNeeded: bytesRemaining(), destinationLost: writing && !destinationIsIntact(),
                                               jobDestination: jobDestination)
        let decision = hooks.failure(failure)
        switch decision.choice {
        case .retry: return .retry
        case .skip: return .skip(failure.summary)
        case .cancel:
            control.cancel()
            return .cancel
        }
    }

    private func fail(_ source: URL, _ target: URL, _ stage: FailureStage, errno error: Int32, retry: () -> Outcome) -> Outcome {
        switch decide(source, target, stage, error) {
        case .retry: return retry()
        case .skip(let why):
            hooks.entryDone(TransferTotals(items: 1))
            return .failed(why)
        case .cancel: return .cancelled(leftContent: false)
        }
    }
}

private let copyCallback: copyfile_callback_t = { what, stage, state, _, _, context in
    guard let context else { return COPYFILE_CONTINUE }
    return Unmanaged<CopyEngine.CallbackContext>.fromOpaque(context).takeUnretainedValue().handle(what, stage, state)
}
