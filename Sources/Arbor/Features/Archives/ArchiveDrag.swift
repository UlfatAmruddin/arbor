import AppKit
import ArborCore
import UniformTypeIdentifiers

/// Dragging a member out of an archive (FE-163): a file promise. The member is extracted only when
/// the drop target asks for it (Finder, the Desktop, another Arbor window), into the folder it names.
final class ArchiveMemberPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    let ref: ArchiveItemRef
    let isFolder: Bool
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 2
        return q
    }()

    init(ref: ArchiveItemRef, isFolder: Bool) {
        self.ref = ref
        self.isFolder = isFolder
        super.init()
        let type = isFolder ? UTType.folder : (UTType(filenameExtension: (ref.name as NSString).pathExtension) ?? .data)
        fileType = type.identifier
        delegate = self
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { ref.name }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    /// `url` is the final location the receiver chose (its name is already unique there).
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            let folder = try ArchiveJobs.freshSessionFolder()
            final class Box: @unchecked Sendable { var failure: Error? }
            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                let request = ArchiveJobs.ExtractRequest(archive: self.ref.archive, roots: [self.ref.innerPath], base: self.ref.parentPath,
                                                         destination: folder, verb: "Extracting “\(self.ref.name)”")
                ArchiveJobs.extract(request, window: nil) { result in
                    if case .failure(let error) = result { box.failure = error }
                    semaphore.signal()
                }
            }
            semaphore.wait()
            if let failure = box.failure { throw failure }
            try FileManager.default.moveItem(at: folder.appendingPathComponent(ref.name), to: url)
            try? FileManager.default.removeItem(at: folder)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// Accepts file promises dropped on an Arbor folder (archive members from another window, Mail or
/// Photos items): they're received into a staging folder on the destination's volume, then moved in
/// with the usual conflict rules, so nothing is ever overwritten without a decision.
enum PromiseDrop {
    static func register() {
        ItemHooks.registerDropHandler(ItemHooks.DropHandler(
            types: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) },
            operation: { info, destination in
                guard canReceive(info), ArchiveCatalog.ref(for: destination) == nil else { return nil }
                return .copy
            },
            accept: { info, destination, window in
                guard let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
                      !receivers.isEmpty else { return false }
                receive(receivers, into: destination, window: window)
                return true
            }))
    }

    static func canReceive(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    static func receive(_ receivers: [NSFilePromiseReceiver], into destination: URL, window: NSWindow?) {
        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        } catch {
            ArchiveFeature.alert("The items couldn't be received.", error.localizedDescription, in: window)
            return
        }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let group = DispatchGroup()
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var received: [URL] = []
            var errors: [String] = []
        }
        let collected = Collected()
        for receiver in receivers {
            for _ in receiver.fileNames.isEmpty ? [""] : receiver.fileNames { group.enter() }
            receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: queue) { url, error in
                collected.lock.withLock {
                    if let error { collected.errors.append(error.localizedDescription) } else { collected.received.append(url) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let errors = collected.errors
            let sources = collected.received.filter { $0.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL }
            guard !sources.isEmpty else {
                try? FileManager.default.removeItem(at: staging)
                if !errors.isEmpty { ArchiveFeature.alert("The items couldn't be received.", errors.prefix(4).joined(separator: "\n"), in: window) }
                return
            }
            // A copy (a clone on APFS) rather than a move, so Undo never points into the deleted staging folder.
            guard let browser = window?.windowController as? BrowserWindowController else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            browser.startTransfer(.copy, sources, to: destination) { _ in try? FileManager.default.removeItem(at: staging) }
        }
    }
}
