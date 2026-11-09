import Foundation

/// One promised item as the receiving side sees it: `NSFilePromiseReceiver` in the app, fakes in tests.
public protocol FilePromiseSource: AnyObject {
    /// What the provider declared, read on the main thread; may stay empty even after delivery starts (FE-258). Never used as a path.
    var promisedNames: [String] { get }
    /// Starts delivery into `folder`; `reader` runs once per file, on any thread.
    func receive(into folder: URL, reader: @escaping @Sendable (URL, Error?) -> Void)
}

/// Why one promised item didn't arrive. `name` is already safe to show.
public struct PromiseFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The provider's own error, already safe to show.
        case providerError(String)
        /// It reported success, but nothing is there.
        case notDelivered
        /// A location outside the staging folder, a name that isn't one, a link or a special file.
        case unsafeDelivery
        /// It stopped answering, or quit.
        case providerUnavailable
    }

    public let name: String?
    public let reason: Reason

    public init(name: String?, reason: Reason) {
        self.name = name
        self.reason = reason
    }

    public var explanation: String {
        switch reason {
        case .providerError(let text): return text
        case .notDelivered: return L10n.tr("The app said it had finished, but the file isn't there.")
        case .unsafeDelivery: return L10n.tr("The app gave a name or location that isn't safe, so the file was left out.")
        case .providerUnavailable: return L10n.tr("The app offering it stopped responding or has quit.")
        }
    }

    /// An alert's title and text for these failures; nil when there are none.
    public static func summary(_ failures: [PromiseFailure]) -> (title: String, detail: String)? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            let title = first.name.map { L10n.format("“%@” couldn't be received.", $0) } ?? L10n.tr("The item couldn't be received.")
            return (title, first.explanation)
        }
        let shown = 8
        var lines = failures.prefix(shown).map { failure in
            failure.name.map { L10n.format("• %@: %@", $0, failure.explanation) } ?? "• \(failure.explanation)"
        }
        if failures.count > shown { lines.append(L10n.format("…and %d more.", failures.count - shown)) }
        return (L10n.format("%d items couldn't be received.", failures.count), lines.joined(separator: "\n"))
    }
}

public enum PromiseReceptionError: Error, Equatable, LocalizedError {
    case nothingOffered
    case tooManyItems

    public var errorDescription: String? {
        switch self {
        case .nothingOffered: return L10n.tr("The app didn't offer any files.")
        case .tooManyItems: return L10n.format("Arbor can receive at most %d promised items in one drop.", PromiseReception.maxPromises)
        }
    }
}

/// Receives dropped file promises into a private staging folder (FE-102, FE-240, FE-256).
///
/// Only the provider's completion report makes an item count: a file that merely exists proves nothing, and a report
/// proves nothing without a plain item in the promise's own folder. Files arrive on disk, never in memory. Nothing
/// outside staging is touched here, so a failed or cancelled promise can't harm what the destination already holds;
/// the caller places `received` with a normal transfer and then calls `discard`. Everything runs on one private queue.
public final class PromiseReception: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public let completed: Int
        public let total: Int
        /// Written to staging so far; promises declare no size, so there is no percentage within an item.
        public let bytes: Int64
        /// Safe to show; set when one item with a known name is being received.
        public let soleName: String?

        public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    }

    public struct Outcome: Sendable {
        /// Inside staging, and valid until `discard`. Empty after a cancel.
        public let received: [URL]
        public let failures: [PromiseFailure]
        public let wasCancelled: Bool
    }

    /// A drag is a person's gesture; far more than this is not one.
    public static let maxPromises = 4096
    /// Long enough for a slow mail server; Cancel is available throughout.
    public static let defaultStallLimit: TimeInterval = 120
    /// How long a promise with no declared names must stay silent before no more files are expected.
    public static let defaultQuietWindow: TimeInterval = 10
    /// Stops a hostile folder from turning every progress sample into a long walk.
    static let sampleEntryLimit = 20_000
    /// The conflict dialog shows this as where the files come from.
    static var slotDisplayName: String { L10n.tr("Dropped items") }

    private struct Slot {
        var source: FilePromiseSource?
        let folder: URL
        var names: [String]
        var reports = 0
        var received: [URL] = []

        var expected: Int { max(names.count, 1) }
        var isDone: Bool { reports >= expected }
        /// With no declared names there's no telling how many files are coming.
        var mayReport: Bool { reports < (names.isEmpty ? PromiseReception.maxPromises : names.count) }
    }

    private enum Ending { case delivered, cancelled, stalled }

    private let queue = DispatchQueue(label: "arbor.promise-reception", qos: .userInitiated)
    private let staging: URL
    private let stallLimit: TimeInterval
    private let sampleInterval: TimeInterval
    private let quietWindow: TimeInterval
    private var slots: [Slot]
    private var failures: [PromiseFailure] = []
    private var ended = false
    private var timer: DispatchSourceTimer?
    private var lastActivity: TimeInterval = 0
    private var lastTotals = TransferTotals()
    private var progressSink: (@Sendable (Progress) -> Void)?
    private var completion: (@Sendable (Outcome) -> Void)?

    /// Makes the staging folder on `destination`'s volume, so the final copy can clone instead of copying twice.
    public init(sources: [FilePromiseSource], near destination: URL,
                stallLimit: TimeInterval = defaultStallLimit, sampleInterval: TimeInterval = 1,
                quietWindow: TimeInterval = defaultQuietWindow) throws {
        guard !sources.isEmpty else { throw PromiseReceptionError.nothingOffered }
        guard sources.count <= Self.maxPromises else { throw PromiseReceptionError.tooManyItems }
        let manager = FileManager.default
        let root = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        do {
            slots = try sources.enumerated().map { index, source in
                // One folder per promise: same-named items reach the conflict dialog instead of being renamed unseen.
                let folder = root.appendingPathComponent("\(index)", isDirectory: true)
                    .appendingPathComponent(Self.slotDisplayName, isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                return Slot(source: source, folder: folder, names: source.promisedNames)
            }
        } catch {
            TemporaryFiles.removeTree(root)
            throw error
        }
        staging = root
        self.stallLimit = stallLimit
        self.sampleInterval = sampleInterval
        self.quietWindow = quietWindow
    }

    public var stagingFolder: URL { staging }

    /// Call on the main thread, which AppKit's receivers expect. Both callbacks run on the private queue; `completion` runs once.
    public func start(progress: @escaping @Sendable (Progress) -> Void, completion: @escaping @Sendable (Outcome) -> Void) {
        let deliveries = queue.sync { () -> [(FilePromiseSource?, URL)] in
            progressSink = progress
            self.completion = completion
            lastActivity = Self.now
            startSampling()
            report()
            return slots.map { ($0.source, $0.folder) }
        }
        for (index, delivery) in deliveries.enumerated() {
            delivery.0?.receive(into: delivery.1) { [weak self] url, error in
                self?.queue.async { self?.record(index, url, error) }
            }
        }
        // Providers may only name their files once delivery has been asked for (FE-258).
        let declared = deliveries.map { $0.0?.promisedNames ?? [] }
        queue.async { [self] in
            for (index, names) in declared.enumerated() where !names.isEmpty { slots[index].names = names }
            evaluate()
        }
    }

    /// Stops waiting. There is no way to stop another app's writing, so what it delivers from now on is ignored.
    public func cancel() {
        queue.async { [self] in finish(.cancelled) }
    }

    /// Removes staging and anything in it. Late writers find their folder gone.
    public func discard() {
        queue.async { [staging] in TemporaryFiles.removeTree(staging) }
    }

    /// Waits for work already queued (tests).
    func flush() { queue.sync {} }

    // MARK: - Private queue

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func record(_ index: Int, _ url: URL, _ error: Error?) {
        // A provider that reports too often gets no more than it promised.
        guard !ended, slots.indices.contains(index), slots[index].mayReport else { return }
        slots[index].reports += 1
        lastActivity = Self.now

        let name = Self.displayName(url.lastPathComponent) ?? slots[index].names.first.flatMap(Self.displayName)
        if let error {
            failures.append(PromiseFailure(name: name, reason: .providerError(UntrustedText.display(error.localizedDescription, limit: 300))))
        } else {
            switch Self.verifiedDelivery(url, in: slots[index].folder) {
            case .success(let staged):
                if !slots[index].received.contains(staged) { slots[index].received.append(staged) }
            case .failure(let failure):
                failures.append(PromiseFailure(name: name, reason: failure.reason))
            }
        }
        evaluate()
    }

    /// Promises with declared names finish at once; the others when no more arrive (`sample`).
    private func evaluate() {
        guard !ended else { return }
        if slots.allSatisfy({ $0.isDone && !$0.names.isEmpty }) { finish(.delivered) } else { report() }
    }

    private struct DeliveryProblem: Error { let reason: PromiseFailure.Reason }

    /// Where the item really is, built from our folder and never from the reported path.
    private static func verifiedDelivery(_ url: URL, in folder: URL) -> Result<URL, DeliveryProblem> {
        let name = url.lastPathComponent
        guard url.isFileURL, NameRules.validate(name) == nil else { return .failure(DeliveryProblem(reason: .unsafeDelivery)) }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(DeliveryProblem(reason: .notDelivered)) }
        defer { close(fd) }
        var own = stat(), parent = stat(), entry = stat()
        guard fstat(fd, &own) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0,
              own.st_dev == parent.st_dev, own.st_ino == parent.st_ino else {
            return .failure(DeliveryProblem(reason: .unsafeDelivery))
        }
        guard fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { return .failure(DeliveryProblem(reason: .notDelivered)) }
        switch entry.st_mode & S_IFMT {
        case S_IFREG, S_IFDIR: return .success(folder.appendingPathComponent(name))
        default: return .failure(DeliveryProblem(reason: .unsafeDelivery))
        }
    }

    private static func displayName(_ raw: String) -> String? {
        let shown = UntrustedText.display(raw, limit: 80)
        return shown.isEmpty || shown == "/" ? nil : shown
    }

    private func startSampling() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    private func sample() {
        guard !ended else { return }
        let probe = TransferControl()
        let totals = TransferDiscovery.measure(staging, control: probe) { partial in
            if partial.items > Self.sampleEntryLimit { probe.cancel() }
        }
        // A walk cut off at the entry limit proves nothing, so it can't count as activity.
        if let totals, totals != lastTotals {
            lastTotals = totals
            lastActivity = Self.now
            report()
            return
        }
        // Only promises with undeclared names get here done; declared ones finish on their last report.
        if slots.allSatisfy(\.isDone), Self.now - lastActivity >= quietWindow {
            finish(.delivered)
        } else if Self.now - lastActivity >= stallLimit {
            finish(.stalled)
        }
    }

    private func report() {
        let total = slots.reduce(0) { $0 + $1.expected }
        let completed = slots.reduce(0) { $0 + min($1.reports, $1.expected) }
        let soleName = total == 1 ? slots.first?.names.first.flatMap(Self.displayName) : nil
        progressSink?(Progress(completed: completed, total: total, bytes: lastTotals.bytes, soleName: soleName))
    }

    private func finish(_ ending: Ending) {
        guard !ended else { return }
        ended = true
        timer?.cancel()
        timer = nil
        if ending == .stalled {
            for slot in slots where !slot.isDone {
                failures.append(PromiseFailure(name: slot.names.count == 1 ? Self.displayName(slot.names[0]) : nil, reason: .providerUnavailable))
            }
        }
        let outcome = Outcome(received: ending == .cancelled ? [] : slots.flatMap(\.received),
                              failures: ending == .cancelled ? [] : failures,
                              wasCancelled: ending == .cancelled)
        for index in slots.indices { slots[index].source = nil }
        let done = completion
        completion = nil
        progressSink = nil
        done?(outcome)
    }
}
