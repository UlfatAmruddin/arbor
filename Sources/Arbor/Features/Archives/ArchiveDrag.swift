import AppKit
import ArborCore
import UniformTypeIdentifiers

/// Dragging an archive member out (FE-163): a file promise, extracted only when the drop target asks.
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
            defer { try? FileManager.default.removeItem(at: folder) }   // also after a failed or cancelled extraction
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
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
