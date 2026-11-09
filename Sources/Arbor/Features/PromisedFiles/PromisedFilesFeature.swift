import AppKit
import ArborCore

/// Files promised by other apps, such as Mail attachments and archive members (docs/features/promised-files.md).
enum PromisedFilesFeature: ExplorerFeature {
    static let id = "promised-files"
    static let requires = ["file-operations"]

    static func register() {
        PromiseDrop.register()
        PromiseDropScripts.register()
    }
}

extension NSFilePromiseReceiver: FilePromiseSource {
    public var promisedNames: [String] { fileNames }

    public func receive(into folder: URL, reader: @escaping @Sendable (URL, Error?) -> Void) {
        receivePromisedFiles(atDestination: folder, options: [:], operationQueue: PromiseDrop.deliveryQueue, reader: reader)
    }
}

/// Accepts dropped file promises: received into staging as a cancellable status bar activity, then copied in as a
/// normal job, so nothing is overwritten without a decision (FE-102, FE-256).
enum PromiseDrop {
    /// The last failure text and staging folder, for scripted checks.
    private(set) static var lastReport: String?
    private(set) static var lastStaging: URL?

    fileprivate static let deliveryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    static func register() {
        ItemHooks.registerDropHandler(ItemHooks.DropHandler(
            types: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) },
            operation: { info, destination in operation(info, onto: destination) },
            accept: { info, destination, window in
                guard let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
                      !receivers.isEmpty else { return false }
                receive(receivers, into: destination, window: window)
                return true
            }))
    }

    /// Hovering only reads the types, so no promise starts before the drop (FE-258). The result is always new files.
    static func operation(_ info: NSDraggingInfo, onto destination: URL) -> NSDragOperation? {
        guard info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil),
              ArchiveCatalog.ref(for: destination) == nil else { return nil }
        let mask = info.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        return mask.contains(.generic) ? .generic : nil
    }

    static var stallLimit: TimeInterval {
        let scripted = AppDelegate.isHeadless ? Automation.environment["ARBOR_PROMISE_STALL"].flatMap(Double.init) : nil
        guard let scripted, scripted.isFinite, scripted > 0 else { return PromiseReception.defaultStallLimit }
        return min(scripted, PromiseReception.defaultStallLimit)
    }

    static func receive(_ sources: [FilePromiseSource], into destination: URL, window: NSWindow?) {
        let reception: PromiseReception
        do {
            reception = try PromiseReception(sources: sources, near: destination, stallLimit: stallLimit)
        } catch {
            show(title: L10n.tr("The items couldn't be received."), detail: error.localizedDescription, window: window)
            return
        }
        lastStaging = reception.stagingFolder
        let activity = OperationCenter.Activity(text: L10n.format("Receiving %@", StatusText.items(sources.count))) { reception.cancel() }
        OperationCenter.shared.begin(activity)
        reception.start(
            progress: { progress in
                DispatchQueue.main.async { OperationCenter.shared.update(activity, text: statusText(progress), fraction: progress.fraction) }
            },
            completion: { [weak window] outcome in
                DispatchQueue.main.async {
                    OperationCenter.shared.end(activity)
                    finish(outcome, of: reception, into: destination, window: window)
                }
            })
    }

    private static func statusText(_ progress: PromiseReception.Progress) -> String {
        let what = progress.soleName.map { "“\($0)”" } ?? StatusText.items(progress.total)
        let text = L10n.format("Receiving %@", what)
        return progress.bytes > 0 ? "\(text) · \(StatusText.bytes(progress.bytes))" : text
    }

    private static func finish(_ outcome: PromiseReception.Outcome, of reception: PromiseReception, into destination: URL, window: NSWindow?) {
        let browser = window?.windowController as? BrowserWindowController
        if outcome.wasCancelled {
            reception.discard()
            browser?.statusBar.setMessage(L10n.tr("Cancelled."))
            return
        }
        guard !outcome.received.isEmpty else {
            reception.discard()
            report(outcome.failures, window: window)
            return
        }
        // A copy rather than a move, so Undo never points into the staging folder that is about to go.
        let done: (TransferReport) -> Void = { [weak window] _ in
            reception.discard()
            report(outcome.failures, window: window)
        }
        if let browser {
            browser.startTransfer(.copy, outcome.received, to: destination, preflighted: true, then: done)
        } else {
            OperationCenter.shared.start(.copy, sources: outcome.received, destination: destination, window: window, completion: done)
        }
    }

    private static func report(_ failures: [PromiseFailure], window: NSWindow?) {
        guard let summary = PromiseFailure.summary(failures) else { return }
        show(title: summary.title, detail: summary.detail, window: window)
    }

    private static func show(title: String, detail: String, window: NSWindow?) {
        lastReport = "\(title) \(detail)"
        NSAlert.show(title, detail, in: window)
    }
}
