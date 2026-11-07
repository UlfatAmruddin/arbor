import Foundation

/// Copies one item (file, symbolic link, folder tree or package) with copyfile(3).
/// Used only from a job's worker thread; blocking there (pause, waiting for a decision) is fine.
///
/// Fidelity (FE-123, FE-124):
/// - `COPYFILE_ALL`: data, permissions, owner where allowed, ACLs, flags, extended attributes
///   (Finder tags, Finder info, quarantine, resource forks), access and modification dates.
///   The creation date is restored afterwards (copyfile sets it only when cloning).
/// - `COPYFILE_CLONE`: an APFS clone when source and destination allow it, else a normal copy.
/// - `COPYFILE_DATA_SPARSE`: holes in sparse files stay holes.
/// - `COPYFILE_NOFOLLOW`: symbolic links are copied as links; their targets are never read.
/// - `COPYFILE_EXCL`: never writes over an existing item, even one created a moment ago.
/// - Each path is copied on its own, so two hard links become two independent files and editing
///   one copy never changes the other.
/// - Folders are walked here, not by copyfile, so pause/cancel/skip work per file and folder dates
///   and permissions are applied after their contents. Packages (.app, .rtfd…) are units: a
///   package that can't be copied completely is removed again, and a moved package's original is
///   deleted only after the whole package copied.
///
/// Partial files: copyfile removes the destination when it fails or is cancelled; the engine also
/// removes it itself if it is still there and is provably the file this job opened (same inode).
final class CopyEngine {
    struct Hooks {
        /// Bytes copied since the last call (negative when a failed file's bytes are un-counted).
        var bytes: (Int64) -> Void = { _ in }
        /// One entry (file, link, folder, package) finished or was skipped.
        var entryDone: (_ totals: TransferTotals) -> Void = { _ in }
        /// The file being worked on.
        var current: (URL) -> Void = { _ in }
        /// Blocking: what to do about a failure.
        var failure: (TransferFailure) -> FailureDecision = { _ in FailureDecision(.skip) }
        /// Problems below the top-level item (reported in the job's details).
        var detail: (ItemResult) -> Void = { _ in }
    }

    enum Outcome: Equatable {
        case done
        /// Some entries inside a folder were skipped or failed.
        case partial
        case skipped(String)
        case failed(String)
        /// `leftContent`: something this job made is still at the destination.
        case cancelled(leftContent: Bool)
    }

    let control: TransferControl
    let allowClone: Bool
    var hooks = Hooks()
    /// The bytes still to copy in the job, for disk-full messages.
    var bytesRemaining: () -> Int64? = { nil }
    /// Debug/testing: caps the data rate so progress, pause and cancel can be observed.
    var bytesPerSecondLimit: Int64?
    private var throttleStart: Date?
    private var throttledBytes: Int64 = 0
    private let verb: String

    init(control: TransferControl, allowClone: Bool, verb: String) {
        self.control = control
        self.allowClone = allowClone
        self.verb = verb
    }

    /// Copies `source` to `target` (which must not exist). With `moveSource`, each original
    /// entry is removed right after its own copy succeeded (cross-volume move, FE-122).
    func copyItem(_ source: URL, to target: URL, moveSource: Bool) -> Outcome {
        guard control.checkpoint() else { return .cancelled(leftContent: false) }
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            return fail(source, target, .copying, errno: errno, retry: { [self] in copyItem(source, to: target, moveSource: moveSource) })
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            if Self.isPackage(source) { return copyPackage(source, to: target, moveSource: moveSource) }
            return copyFolder(source, to: target, moveSource: moveSource)
        case S_IFREG, S_IFLNK:
            return copyLeaf(source, to: target, size: (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_size) : 0,
                            moveSource: moveSource)
        default:
            hooks.entryDone(TransferTotals(items: 1))
            return .skipped("Special files (pipes, sockets, devices) aren't copied.")
        }
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    // MARK: Files and links

    private func copyLeaf(_ source: URL, to target: URL, size: Int64, moveSource: Bool) -> Outcome {
        while true {
            hooks.current(source)
            let error = copyData(source, to: target, size: size)
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
        if moveSource { removeOriginal(source, copiedTo: target, isFolder: false) }
        return .done
    }

    /// Returns 0 or an errno. Never leaves a partial file behind.
    func copyData(_ source: URL, to target: URL, size: Int64) -> Int32 {
        guard let state = copyfile_state_alloc() else { return ENOMEM }
        defer { copyfile_state_free(state) }
        let context = CallbackContext(engine: self)
        var flags = COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_DATA_SPARSE
        if allowClone { flags |= COPYFILE_CLONE }
        let result: Int32 = withExtendedLifetime(context) {
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
            return copyfile(source.path, target.path, state, copyfile_flags_t(flags))
        }
        var error = result == 0 ? 0 : errno
        if error != 0, let reportedError = context.failure, reportedError != 0 { error = reportedError }
        if error == 0 {
            var cloned: Int32 = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &cloned)
            if cloned == 0 { Self.restoreCreationDate(from: source, to: target) }
            // Clones and sparse holes report fewer (or no) bytes: count the rest now.
            if size > context.reported { hooks.bytes(size - context.reported) }
            return 0
        }
        if context.reported > 0 { hooks.bytes(-context.reported) }
        if let identity = context.destination, FileStamp(target).map({ $0.device == identity.device && $0.inode == identity.inode }) == true {
            unlink(target.path)
        }
        return error == EEXIST ? EEXIST : (error == 0 ? EIO : error)
    }

    /// Per-chunk callback state.
    final class CallbackContext {
        unowned let engine: CopyEngine
        var reported: Int64 = 0
        var destination: (device: UInt64, inode: UInt64)?
        /// The errno of a data error reported through the callback.
        var failure: Int32?
        init(engine: CopyEngine) { self.engine = engine }

        func handle(_ what: Int32, _ stage: Int32, _ state: copyfile_state_t?) -> Int32 {
            if destination == nil, stage == COPYFILE_START, let state {
                var fd: Int32 = -1
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &fd) == 0, fd >= 0 {
                    var info = stat()
                    if fstat(fd, &info) == 0 { destination = (UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino)) }
                }
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_ERR {
                // copyfile retries a failed write forever if told to continue (seen with ENOSPC):
                // stop and report the real error.
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
        try? url.setResourceValues(values)   // best effort: locked items or some volumes refuse
    }

    // MARK: Folders

    private func copyFolder(_ source: URL, to target: URL, moveSource: Bool) -> Outcome {
        while mkdir(target.path, 0o700) != 0 {
            let error = errno
            switch decide(source, target, .creatingFolder, error) {
            case .retry: continue
            case .skip(let why):
                hooks.entryDone(TransferDiscovery.measure(source) ?? TransferTotals(items: 1))
                return .failed(why)
            case .cancel: return .cancelled(leftContent: false)
            }
        }
        var names: [String]
        while true {
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: source.path)
                break
            } catch {
                let code = Int32((error as NSError).underlyingErrors.first.map { ($0 as NSError).code } ?? Int(EACCES))
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
        var problems = 0
        var cancelled = false
        for name in names {
            guard control.checkpoint() else { cancelled = true; break }
            let child = source.appendingPathComponent(name)
            let outcome = copyItem(child, to: target.appendingPathComponent(name), moveSource: moveSource)
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
        if moveSource, problems == 0 { removeOriginal(source, copiedTo: target, isFolder: true) }
        return problems == 0 ? .done : .partial
    }

    /// Permissions, flags, dates, ACLs and extended attributes of a folder, applied after its
    /// contents so writing the contents doesn't change the dates (and a read-only folder could
    /// still be filled).
    private func applyFolderMetadata(from source: URL, to target: URL) {
        _ = copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
        Self.restoreCreationDate(from: source, to: target)
    }

    // MARK: Packages

    private func copyPackage(_ source: URL, to target: URL, moveSource: Bool) -> Outcome {
        while true {
            hooks.current(source)
            let (error, failedAt, bytes, items) = copyUnit(source, to: target)
            if error == 0 {
                hooks.entryDone(TransferTotals(items: items))
                break
            }
            // Remove the incomplete package: this job created the whole tree.
            hooks.bytes(-bytes)
            if FileOps.exists(target) { try? FileManager.default.removeItem(at: target) }
            if error == ECANCELED, control.isCancelled { return .cancelled(leftContent: false) }
            switch decide(failedAt, target, .copying, error) {
            case .retry: continue
            case .skip(let why):
                hooks.entryDone(TransferDiscovery.measure(source) ?? TransferTotals(items: 1))
                return .failed(why)
            case .cancel: return .cancelled(leftContent: false)
            }
        }
        if moveSource { removeOriginal(source, copiedTo: target, isFolder: false) }
        return .done
    }

    /// Copies a whole tree without prompting. Returns (0 or errno, failing path, bytes reported, entries).
    private func copyUnit(_ source: URL, to target: URL) -> (Int32, URL, Int64, Int) {
        var reported: Int64 = 0
        var items = 0
        let outer = hooks.bytes
        hooks.bytes = { delta in reported += delta; outer(delta) }
        defer { hooks.bytes = outer }
        func walk(_ src: URL, _ dst: URL) -> (Int32, URL) {
            guard control.checkpoint() else { return (ECANCELED, src) }
            var info = stat()
            guard lstat(src.path, &info) == 0 else { return (errno, src) }
            items += 1
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard mkdir(dst.path, 0o700) == 0 else { return (errno, src) }
                let names: [String]
                do { names = try FileManager.default.contentsOfDirectory(atPath: src.path) } catch { return (EACCES, src) }
                for name in names {
                    let r = walk(src.appendingPathComponent(name), dst.appendingPathComponent(name))
                    if r.0 != 0 { return r }
                }
                applyFolderMetadata(from: src, to: dst)
                return (0, src)
            case S_IFREG, S_IFLNK:
                let e = copyData(src, to: dst, size: (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_size) : 0)
                return (e, src)
            default:
                return (0, src)   // special files inside packages are left out
            }
        }
        let (error, at) = walk(source, target)
        return (error, at, reported, items)
    }

    // MARK: Moving

    /// Removes an original after its copy succeeded. A folder is removed only when empty
    /// (apart from Finder's .DS_Store): originals are never deleted recursively unless they are a
    /// package that was just copied completely.
    private func removeOriginal(_ source: URL, copiedTo target: URL, isFolder: Bool) {
        while true {
            let error: Int32
            if isFolder {
                guard FileOps.isEffectivelyEmpty(source) else { return }
                unlink(source.appendingPathComponent(".DS_Store").path)
                error = rmdir(source.path) == 0 ? 0 : errno
            } else if Self.isPackage(source) {
                error = (try? FileManager.default.removeItem(at: source)) != nil ? 0 : EACCES
            } else {
                error = unlink(source.path) == 0 ? 0 : errno
            }
            if error == 0 || error == ENOENT { return }
            switch decide(source, target, .removingSource, error) {
            case .retry: continue
            case .skip, .cancel:
                hooks.detail(ItemResult(source: source, outcome: .copiedButSourceRemains(
                    target, "Copied, but the original couldn't be removed. \(String(cString: strerror(error)))")))
                return
            }
        }
    }

    // MARK: Failures

    enum Resolution { case retry, skip(String), cancel }

    private func decide(_ source: URL, _ target: URL, _ stage: FailureStage, _ error: Int32) -> Resolution {
        let failure = TransferFailure.classify(errno: error, source: source, destination: target, stage: stage,
                                               bytesNeeded: bytesRemaining())
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
