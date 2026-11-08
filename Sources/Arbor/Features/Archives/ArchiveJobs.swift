import AppKit
import ArborCore

/// Extraction, compression, new ZIPs and disk-image mounts; all run off the main thread as
/// cancellable `OperationCenter` activities.
enum ArchiveJobs {
    // MARK: - Session folder for opened members and clipboard copies

    /// Per-launch temporary folder; earlier launches' folders are removed lazily.
    static let sessionFolder: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Arbor Archives", isDirectory: true)
        let mine = root.appendingPathComponent("session-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .background).async {
            for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                // session-<pid>-…: keep folders of processes that are still running.
                let parts = old.lastPathComponent.split(separator: "-")
                guard parts.count >= 3, parts[0] == "session", let pid = Int32(parts[1]), old != mine else { continue }
                if kill(pid, 0) != 0 { try? FileManager.default.removeItem(at: old) }
            }
        }
        return mine
    }()

    static func freshSessionFolder() throws -> URL {
        let url = sessionFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Extraction

    struct ExtractRequest {
        let archive: URL
        /// Inner paths of the items to extract; [""] = everything.
        let roots: [String]
        /// Inner folder being shown; the items land in `destination` relative to it.
        let base: String
        let destination: URL
        /// Status bar wording ("Extracting “a.zip”").
        let verb: String
    }

    struct ExtractResult {
        /// Committed top-level items in the destination.
        var placed: [URL] = []
        var report: TransferReport?
        var rejected: [(entry: ArchiveEntry, reason: ExtractionPlanner.Rejection)] = []
        var removedAfterwards: [String] = []
    }

    enum Failure: Error, LocalizedError {
        case expansion(String)
        case message(String)
        var errorDescription: String? {
            switch self {
            case .expansion(let text), .message(let text): return text
            }
        }
    }

    /// Extracts into staging on the destination's volume, verifies, then moves into place with the
    /// conflict rules (Keep Both default, Replace = Trash).
    static func extract(_ request: ExtractRequest, window: NSWindow?, completion: @escaping (Result<ExtractResult, Error>) -> Void) {
        let cancel = JobCancel()
        let process = cancel.process
        let activity = OperationCenter.Activity(text: request.verb) { cancel.cancel() }
        OperationCenter.shared.begin(activity)
        let finish: (Result<ExtractResult, Error>) -> Void = { result in
            DispatchQueue.main.async {
                OperationCenter.shared.end(activity)
                completion(result)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // bsdtar's view of the names is what its patterns must match (renamed for ZIPs made on Windows).
                let (listing, rewritesBackslashes) = try ArchiveTool.extractionListing(request.archive, process: process)
                // bsdtar's listing doesn't flag ZIP encryption; the central directory does.
                if ArchiveFormat.detect(request.archive) == .zip, let zipEntries = try? ZipDirectory.read(request.archive) {
                    let locked = zipEntries.filter(\.isEncrypted)
                    if request.roots.contains(where: { !ArchiveIndex.entries(under: $0, from: locked).isEmpty }) { throw ArchiveError.encrypted }
                }
                let plan = ExtractionPlanner.plan(entries: listing.entries, roots: request.roots, base: request.base)
                if plan.hasEncrypted { throw ArchiveError.encrypted }
                if plan.isEmpty {
                    throw plan.rejected.isEmpty ? ArchiveError.nothingToExtract : Failure.message(rejectionText(plan.rejected, header: L10n.tr("Nothing could be extracted safely.")))
                }

                // Zip-bomb and space guard before anything is written (FE-170).
                let policy = ExpansionPolicy()
                let archiveSize = Int64((try? request.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let free = freeSpace(at: request.destination)
                switch policy.check(archiveSize: archiveSize, totalBytes: plan.totalBytes, freeSpace: free) {
                case .ok: break
                case .tooLarge(let total):
                    throw Failure.expansion("“\(request.archive.lastPathComponent)” would expand to \(StatusText.bytes(total)). Arbor doesn't extract archives that large.")
                case .noSpace(let needed, let available):
                    throw Failure.expansion("There isn't enough space to extract “\(request.archive.lastPathComponent)”. It needs \(StatusText.bytes(needed)), and \(StatusText.bytes(available)) is available.")
                case .suspicious(let ratio):
                    // Asked in a sheet on the window; this worker waits for the answer.
                    let answered = DispatchSemaphore(value: 0)
                    let go = Counter()
                    DispatchQueue.main.async {
                        confirmExpansion(request.archive, total: plan.totalBytes, ratio: ratio, window: window) { yes in
                            if yes { go.increment() }
                            answered.signal()
                        }
                    }
                    answered.wait()
                    if go.value == 0 { throw ArchiveError.cancelled }
                }

                let jobRoot = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                          appropriateFor: request.destination, create: true)
                defer { try? FileManager.default.removeItem(at: jobRoot) }
                let staging = jobRoot.appendingPathComponent("content", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

                // Stops the tool if it writes far more than the archive declared (lying headers) or fills the disk.
                let limit = policy.writeLimit(declared: plan.totalBytes)
                let startFree = freeSpace(at: staging) ?? 0
                let total = max(plan.included.count, 1)
                let counter = Counter()
                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                let overrun = Counter()
                watchdog.schedule(deadline: .now() + 0.3, repeating: 0.3)
                watchdog.setEventHandler {
                    if let now = freeSpace(at: staging), startFree > 0 {
                        if startFree - now > limit || now < policy.reserve / 4 {
                            overrun.increment()
                            process.cancel()
                        }
                    }
                    let fraction = Double(counter.value) / Double(total) * 0.9
                    DispatchQueue.main.async { OperationCenter.shared.update(activity, fraction: fraction) }
                }
                watchdog.resume()
                defer { watchdog.cancel() }
                do {
                    try ArchiveTool.extract(request.archive, plan: plan, into: staging, process: process,
                                           rewritesBackslashes: rewritesBackslashes) { counter.increment() }
                } catch ArchiveError.cancelled where overrun.value > 0 {
                    throw Failure.expansion("Extracting “\(request.archive.lastPathComponent)” was stopped because it was writing far more data than the archive declares, or the disk was almost full. Archives like this are usually built to fill the disk (a “zip bomb”).")
                }
                watchdog.cancel()

                let verified = ExtractionVerifier.verify(staging: staging, base: plan.base,
                                                         quarantine: ExtractionVerifier.quarantine(of: request.archive))
                if verified.bytes > limit {
                    throw Failure.expansion("“\(request.archive.lastPathComponent)” contains more data than it declares, so nothing was extracted.")
                }

                let sources = placementSources(request, staging: staging)
                if sources.isEmpty { throw ArchiveError.nothingToExtract }
                try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)

                let transfer = FileTransfer(kind: .move, sources: sources, destination: request.destination)
                cancel.transfer = transfer
                DispatchQueue.main.async { OperationCenter.shared.update(activity, fraction: 0.95) }
                let report = place(transfer, archive: request.archive, window: window)
                if report.wasCancelled, report.committed.isEmpty { throw ArchiveError.cancelled }
                var result = ExtractResult()
                result.report = report
                result.placed = report.committed.map(\.destination)
                result.placed += report.results.compactMap { if case .merged(let url) = $0.outcome { return url } else { return nil } }
                result.rejected = plan.rejected
                result.removedAfterwards = verified.removed
                finish(.success(result))
            } catch {
                finish(.failure(process.isCancelled && !(error is Failure) ? ArchiveError.cancelled : error))
            }
        }
    }

    /// Runs the move from staging into the destination (blocking), asking about conflicts on the main thread.
    private static func place(_ transfer: FileTransfer, archive: URL, window: NSWindow?) -> TransferReport {
        final class Box: @unchecked Sendable { var report: TransferReport? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.report = await transfer.run(resolveConflict: { conflict in
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        // Same conflict dialogs as copy/move (ConflictFlow).
                        let job = OperationCenter.Job(transfer: transfer, window: window)
                        job.presentedAs = .extracting(archive)
                        ConflictFlow.run([conflict], job: job) { continuation.resume(returning: $0.first ?? ConflictDecision(.cancel)) }
                    }
                }
            })
            semaphore.signal()
        }
        semaphore.wait()
        return box.report!
    }

    /// Top-level items to move: the selected roots, or the contents of the shown folder for "everything".
    private static func placementSources(_ request: ExtractRequest, staging: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for root in request.roots {
            let parts = ArchivePath.components(root) ?? []
            let baseParts = ArchivePath.components(request.base) ?? []
            if parts.count <= baseParts.count {
                let folder = baseParts.isEmpty ? staging : staging.appendingPathComponent(baseParts.joined(separator: "/"))
                urls += ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            } else {
                let url = staging.appendingPathComponent(parts.joined(separator: "/"))
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    urls.append(url)
                }
            }
        }
        return urls.map(\.standardizedFileURL)
    }

    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        var info = statfs()
        guard statfs(probe.path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    private static func confirmExpansion(_ archive: URL, total: Int64, ratio: Double, window: NSWindow?, answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.format("“%@” would expand to %@.", "\(archive.lastPathComponent)", "\(StatusText.bytes(total))")
        alert.informativeText = L10n.format("That's about %@ times its own size. Archives that expand this much are often built to fill the disk (a “zip bomb”). Extract it only if you trust where it came from.", "\(Int(ratio.rounded()))")
        let cancel = alert.addButton(withTitle: L10n.tr("Cancel"))
        let go = alert.addButton(withTitle: L10n.tr("Extract Anyway"))
        cancel.keyEquivalent = "\r"
        go.keyEquivalent = ""
        if AppDelegate.isHeadless { ArchiveFeature.lastAlert = alert.messageText }
        AlertSheets.present(alert, in: window) { answer($0 == .alertSecondButtonReturn) }
    }

    static func rejectionText(_ rejected: [(entry: ArchiveEntry, reason: ExtractionPlanner.Rejection)], header: String) -> String {
        let lines = rejected.prefix(8).map {
            "• \($0.entry.rawPath.isEmpty ? ExtractionPlanner.unreadableName : $0.entry.rawPath): \($0.reason.text)"
        }
        let more = rejected.count > 8 ? "\n" + L10n.format("…and %d more.", rejected.count - 8) : ""
        return header + "\n\n" + lines.joined(separator: "\n") + more
    }

    /// Reports skipped and removed items after a successful extraction.
    static func reportSkipped(_ result: ExtractResult, window: NSWindow?) {
        var rejected = result.rejected
        rejected += result.removedAfterwards.map { (ArchiveEntry(rawPath: $0, kind: .special), ExtractionPlanner.Rejection.linkOutside) }
        guard !rejected.isEmpty else { return }
        let count = rejected.count
        let header = count == 1 ? L10n.tr("This item was left out for your safety:") : L10n.tr("These items were left out for your safety:")
        let title = count == 1 ? L10n.tr("1 item wasn't extracted.") : L10n.format("%d items weren't extracted.", count)
        ArchiveFeature.alert(title, rejectionText(rejected, header: header), in: window)
    }

    static func show(_ error: Error, title: String, window: NSWindow?) {
        if case ArchiveError.cancelled = error {
            BrowserWindowController.active?.statusBar.setMessage(L10n.tr("Cancelled."))
            return
        }
        ArchiveFeature.alert(title, error.localizedDescription, in: window)
    }

    // MARK: - Compression

    /// One archive next to the selection, named after the first item, then inline rename (FE-164).
    static func compress(_ items: [FileItem], format: ArchiveCreateFormat, window controller: BrowserWindowController?) {
        guard let first = items.first else { return }
        let folder = first.url.deletingLastPathComponent().standardizedFileURL
        let sources = items.map(\.url)
        let process = ToolProcess()
        let name = ArchiveNaming.archiveName(for: first.name, isFolder: first.isFolder, format: format) {
            FileOps.exists(folder.appendingPathComponent($0))
        }
        let activity = OperationCenter.Activity(text: "Compressing \(items.count == 1 ? "“\(first.name)”" : StatusText.items(items.count))") {
            process.cancel()
        }
        OperationCenter.shared.begin(activity)
        weak let weakController = controller
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome: Result<URL, Error> = .failure(ArchiveError.toolFailed("The archive couldn't be saved in the folder."))
            do {
                let total = max(countFiles(sources, limit: 200_000), 1)
                let counter = Counter()
                let jobRoot = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                          appropriateFor: folder, create: true)
                defer { try? FileManager.default.removeItem(at: jobRoot) }
                let output = jobRoot.appendingPathComponent(name)
                try ArchiveTool.create(format: format, sources: sources, output: output, process: process) {
                    counter.increment()
                    let fraction = Double(counter.value) / Double(total)
                    DispatchQueue.main.async { OperationCenter.shared.update(activity, fraction: fraction * 0.98) }
                }
                // Never overwrite: take the next free "name (n).zip" if something appeared meanwhile.
                var finalName = name
                for _ in 0..<1000 {
                    let target = folder.appendingPathComponent(finalName)
                    do {
                        try FileManager.default.moveItem(at: output, to: target)
                        outcome = .success(target)
                        break
                    } catch CocoaError.fileWriteFileExists {
                        finalName = ArchiveNaming.uniqueName(name) { FileOps.exists(folder.appendingPathComponent($0)) }
                    }
                }
            } catch {
                outcome = .failure(process.isCancelled ? ArchiveError.cancelled : error)
            }
            DispatchQueue.main.async {
                OperationCenter.shared.end(activity)
                switch outcome {
                case .success(let url):
                    registerUndoCreate(url, action: "Compress")
                    guard let c = weakController else { return }
                    if Location.folder(folder) == c.location {
                        c.refreshSelecting([url.lastPathComponent], rename: url.lastPathComponent)
                    } else {
                        c.statusBar.setMessage(L10n.format("Created “%@” in “%@”.", "\(url.lastPathComponent)", "\(displayName(of: folder))"))
                    }
                case .failure(let error):
                    show(error, title: L10n.format("Couldn't create “%@”.", "\(name)"), window: weakController?.window)
                }
            }
        }
    }

    /// Counts files for progress; stops early past `limit` (bounded, job-scoped scan).
    private static func countFiles(_ urls: [URL], limit: Int) -> Int {
        var count = 0
        for url in urls {
            count += 1
            guard FileOps.isPlainFolder(url), let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            while walker.nextObject() != nil {
                count += 1
                if count >= limit { return count }
            }
        }
        return count
    }

    /// New ▸ Compressed (zipped) Folder: a valid empty ZIP, then inline rename.
    static func newZip(in folder: URL, window controller: BrowserWindowController) {
        let name = ArchiveNaming.newZipName { FileOps.exists(folder.appendingPathComponent($0)) }
        let url = folder.appendingPathComponent(name)
        do {
            try ArchiveNaming.emptyZip.write(to: url, options: .withoutOverwriting)
        } catch {
            ArchiveFeature.alert(L10n.format("Couldn't create “%@” in “%@”.", "\(name)", "\(displayName(of: folder))"), error.localizedDescription, in: controller.window)
            return
        }
        registerUndoCreate(url, action: "New")
        if Location.folder(folder) == controller.location { controller.refreshSelecting([name], rename: name) }
    }

    /// Undo trashes the created archive unless it changed since (FE-129); Redo puts it back.
    static func registerUndoCreate(_ url: URL, action: String) {
        let stamp = ArchiveCatalog.stamp(of: url)
        let um = OperationCenter.shared.undoManager
        um.registerUndo(withTarget: OperationCenter.shared) { _ in
            guard ArchiveCatalog.stamp(of: url) == stamp else {
                ArchiveFeature.alert(L10n.format("“%@” changed after it was created, so it wasn't removed.", "\(url.lastPathComponent)"), "", in: NSApp.keyWindow)
                return
            }
            if let trashed = try? SystemTrash.trash(url) {
                OperationCenter.shared.registerUndoTrash([(url, trashed)], actionName: action)
            }
        }
        um.setActionName(action)
    }

    // MARK: - Disk images (FE-171)

    /// Attaches a disk image with `hdiutil` and opens its volume.
    static func mount(_ image: URL, window controller: BrowserWindowController?, fallbackToBrowse: Bool) {
        let process = ToolProcess()
        let activity = OperationCenter.Activity(text: "Mounting “\(image.lastPathComponent)”") { process.cancel() }
        OperationCenter.shared.begin(activity)
        weak let weakController = controller
        DispatchQueue.global(qos: .userInitiated).async {
            let args = ["attach", "-plist"] + SystemOpen.attachArguments(for: image) + [image.path]
            let output = try? process.run("/usr/bin/hdiutil", args)
            DispatchQueue.main.async {
                OperationCenter.shared.end(activity)
                guard let output, !output.wasCancelled else { return }
                let mounts = DiskImage.mountPoints(fromPlist: output.stdout)
                if output.status == 0, let mount = mounts.first {
                    ArchiveFeature.lastMount = mount
                    weakController?.navigate(to: .folder(mount))
                    return
                }
                let reason = ArchiveError.summarize(output.stderr).replacingOccurrences(of: "hdiutil: attach failed - ", with: "")
                if fallbackToBrowse, ArchiveFormat.detect(image) == .iso {
                    weakController?.navigate(to: .archive(image, innerPath: ""))
                    weakController?.statusBar.setMessage(L10n.format("“%@” couldn't be mounted (%@). Showing its contents read-only instead.", "\(image.lastPathComponent)", "\(reason)"))
                    return
                }
                ArchiveFeature.alert(L10n.format("“%@” couldn't be mounted.", "\(image.lastPathComponent)"),
                             (reason.isEmpty ? "The disk image may be damaged or in an unsupported format." : reason.prefix(1).uppercased() + reason.dropFirst() + ".")
                                + L10n.tr("\n\nYou can also open it with DiskImageMounter from Finder."), in: weakController?.window)
            }
        }
    }
}

/// Cancels whichever stage a job is in: the tool, then the move into place.
final class JobCancel: @unchecked Sendable {
    let process = ToolProcess()
    private let lock = NSLock()
    private var _transfer: FileTransfer?
    var transfer: FileTransfer? {
        get { lock.withLock { _transfer } }
        set { lock.withLock { _transfer = newValue } }
    }
    func cancel() {
        process.cancel()
        transfer?.cancel()
    }
}

/// A thread-safe counter for progress callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
