import Foundation

public enum TransferKind: String, Sendable {
    case copy, move

    public var progressVerb: String { self == .copy ? "Copying" : "Moving" }
    public var pastVerb: String { self == .copy ? "copied" : "moved" }
    public var verb: String { self == .copy ? "copy" : "move" }
}

public enum ConflictKind: Sendable, Hashable {
    case fileOverFile
    case folderOverFolder
    /// A file where a folder exists or vice versa. Never silently coerced.
    case typeMismatch
}

public struct Conflict: Sendable {
    public let source: URL
    public let destination: URL
    public let kind: ConflictKind
    /// Both sides as they were when the conflict was found (sizes and dates for the dialogs;
    /// the destination stamp also detects a change while the decision was pending, FE-250).
    public let sourceStamp: FileStamp?
    public let destinationStamp: FileStamp?

    public init(source: URL, destination: URL, kind: ConflictKind,
                sourceStamp: FileStamp? = nil, destinationStamp: FileStamp? = nil) {
        self.source = source
        self.destination = destination
        self.kind = kind
        self.sourceStamp = sourceStamp
        self.destinationStamp = destinationStamp
    }
}

public enum ConflictChoice: Sendable, Equatable {
    /// The existing destination item is disposed of (moved to the Trash by default) first.
    case replace
    /// Folders only: combine contents; nested conflicts are asked separately.
    case merge
    case keepBoth
    case skip
    case cancel
}

public struct ConflictDecision: Sendable, Equatable {
    public var choice: ConflictChoice
    /// Applies to the rest of this job, for this conflict kind only (FE-119).
    public var applyToRemaining: Bool

    public init(_ choice: ConflictChoice, applyToRemaining: Bool = false) {
        self.choice = choice
        self.applyToRemaining = applyToRemaining
    }
}

public enum ItemOutcome: Sendable, Equatable {
    case succeeded(URL)
    /// Folder merged into an existing folder at this URL.
    case merged(URL)
    case skipped(String)
    case failed(String)
    /// Cross-volume move: the copy exists, but the original could not be removed.
    case copiedButSourceRemains(URL, String)
    /// A folder that exists at the destination but is incomplete (items inside failed or the
    /// job was cancelled partway). What did arrive is kept; nothing is rolled back.
    case partial(URL, String)
    case cancelled

    public var isProblem: Bool {
        switch self {
        case .failed, .copiedButSourceRemains, .partial: return true
        default: return false
        }
    }
}

public struct ItemResult: Sendable, Equatable {
    public let source: URL
    public let outcome: ItemOutcome
}

public struct TransferProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        /// "Discovering items…": counting what will be copied. Totals are unknown; `itemsDone`
        /// and `bytesDone` hold what has been found so far.
        case discovering
        case running
        /// Waiting for the user to answer a conflict or error dialog.
        case waiting
        case paused
        case finishing
    }

    /// Top-level items finished.
    public var completed: Int
    /// Top-level items requested.
    public var total: Int
    public var currentName: String?
    public var phase: Phase
    /// Every entry (files, folders, links) finished, including those inside folders.
    public var itemsDone: Int
    /// Known after discovery; nil while counting.
    public var itemsTotal: Int?
    public var bytesDone: Int64
    /// Known after discovery; nil while counting and for same-volume moves (renames have no bytes).
    public var bytesTotal: Int64?

    public init(completed: Int, total: Int, currentName: String?, phase: Phase = .running,
                itemsDone: Int = 0, itemsTotal: Int? = nil, bytesDone: Int64 = 0, bytesTotal: Int64? = nil) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
        self.phase = phase
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// 0…1 by bytes when known, else by entries, else by top-level items. Nil while discovering.
    public var fraction: Double? {
        if phase == .discovering { return nil }
        if let total = bytesTotal, total > 0 { return min(1, Double(max(0, bytesDone)) / Double(total)) }
        if let total = itemsTotal, total > 0 { return min(1, Double(itemsDone) / Double(total)) }
        return total > 0 ? min(1, Double(completed) / Double(total)) : nil
    }

    public var itemsRemaining: Int? { itemsTotal.map { max(0, $0 - itemsDone) } }
    public var bytesRemaining: Int64? { bytesTotal.map { max(0, $0 - bytesDone) } }
}

public struct TransferReport: Sendable {
    public let kind: TransferKind
    public let destination: URL
    /// One result per requested top-level source, in request order.
    public let results: [ItemResult]
    /// Nested problems and skips found while merging or copying folders.
    public let details: [ItemResult]
    public let wasCancelled: Bool
    /// Copies only: how each committed copy looked right after it was made, for Undo Copy.
    public let fingerprints: [URL: ItemFingerprint]

    public var problems: [ItemResult] {
        (results + details).filter(\.outcome.isProblem)
    }

    /// Items whose final committed location is known. The committed name can differ
    /// from the requested one after "keep both" (FE-255).
    public var committed: [(source: URL, destination: URL)] {
        results.compactMap {
            if case .succeeded(let url) = $0.outcome { return ($0.source, url) }
            return nil
        }
    }
}

/// Copies or moves a frozen list of sources into a destination folder (spec §9).
///
/// Safety rules: sources and destination are fixed at creation. Conflicts at each folder level
/// are found first and asked together; every decision is re-checked when the item is reached and
/// asked again if the destination changed meanwhile (FE-250). "Replace" moves the existing item
/// to the Trash first (DEC-010). Nothing is ever written over (`COPYFILE_EXCL`, `RENAME_EXCL`).
/// A cross-volume move removes each original only after its own copy succeeded (FE-122).
/// Cancelling never rolls back finished work; the file being copied is removed.
///
/// The work runs on a dedicated thread so pausing or waiting for a dialog never blocks Swift's
/// shared executor threads.
public final class FileTransfer: @unchecked Sendable {
    public typealias ConflictResolver = @Sendable (Conflict) async -> ConflictDecision
    /// Answers all conflicts found at one folder level, one decision per conflict, in order.
    public typealias ConflictBatchResolver = @Sendable ([Conflict]) async -> [ConflictDecision]
    public typealias FailureResolver = @Sendable (TransferFailure) async -> FailureDecision
    public typealias Disposer = @Sendable (URL) throws -> Void
    public typealias VolumeCheck = @Sendable (URL, URL) -> Bool

    public static let trashDisposer: Disposer = { url in
        try SystemTrash.trash(url)
    }

    public struct Options: Sendable {
        /// APFS clones where possible (instant, no extra space).
        public var allowClone = true
        /// Debug/testing: caps the data rate so progress, pause and cancel can be watched.
        public var bytesPerSecondLimit: Int64?
        /// Fingerprint each committed copy so Undo Copy can prove it is unchanged.
        public var fingerprintCopies = true
        /// Minimum time between progress reports (state changes are always reported).
        public var progressInterval: TimeInterval = 0.1

        public init(allowClone: Bool = true, bytesPerSecondLimit: Int64? = nil, fingerprintCopies: Bool = true,
                    progressInterval: TimeInterval = 0.1) {
            self.allowClone = allowClone
            self.bytesPerSecondLimit = bytesPerSecondLimit
            self.fingerprintCopies = fingerprintCopies
            self.progressInterval = progressInterval
        }
    }

    public let kind: TransferKind
    public let sources: [URL]
    public let destination: URL
    public let control = TransferControl()
    public let journal: JobJournal?

    private let fileManager: FileManager
    private let disposeReplaced: Disposer
    private let sameVolume: VolumeCheck
    private let options: Options

    // Worker state. Written only on the worker thread; `lock` guards what `emit` reads.
    private let lock = NSLock()
    private var counters = TransferProgress(completed: 0, total: 0, currentName: nil, phase: .discovering)
    private var lastEmit: TimeInterval = 0
    private var progressSink: (@Sendable (TransferProgress) -> Void)?
    private var conflictResolver: ConflictBatchResolver?
    private var failureResolver: FailureResolver?
    private var sticky: [ConflictKind: ConflictChoice] = [:]
    private var skipFailures: Set<FailureKind> = []
    private var details: [ItemResult] = []
    private var fingerprints: [URL: ItemFingerprint] = [:]
    private var discovered = false
    private var currentTopSource: URL?
    private lazy var engine: CopyEngine = makeEngine()

    public init(kind: TransferKind, sources: [URL], destination: URL,
                fileManager: FileManager = .default,
                disposeReplaced: @escaping Disposer = FileTransfer.trashDisposer,
                sameVolume: @escaping VolumeCheck = { FileOps.sameVolume($0, $1) },
                journal: JobJournal? = nil,
                options: Options = Options()) {
        self.kind = kind
        self.sources = sources.map(\.standardizedFileURL)
        self.destination = destination.standardizedFileURL
        self.fileManager = fileManager
        self.disposeReplaced = disposeReplaced
        self.sameVolume = sameVolume
        self.journal = journal
        self.options = options
        counters.total = self.sources.count
    }

    public var isCancelled: Bool { control.isCancelled }
    public var isPaused: Bool { control.isPaused }
    public func cancel() { control.cancel() }
    public func pause() { control.pause() }
    public func resume() { control.resume() }

    /// When the job ends cancelled, keep its journal instead of deleting it, so the next launch
    /// can show what didn't finish (set when the app quits mid-job).
    public var retainsJournalWhenCancelled: Bool {
        get { lock.withLock { retainJournal } }
        set { lock.withLock { retainJournal = newValue } }
    }
    private var retainJournal = false

    /// The latest progress (any thread).
    public var currentProgress: TransferProgress { lock.withLock { snapshot() } }

    // MARK: - Running

    /// One-conflict-at-a-time resolver (kept for simple callers and tests).
    public func run(progress: @escaping @Sendable (TransferProgress) -> Void = { _ in },
                    resolveConflict: @escaping ConflictResolver,
                    resolveFailure: FailureResolver? = nil) async -> TransferReport {
        await run(progress: progress, resolveConflicts: Self.oneAtATime(resolveConflict), resolveFailure: resolveFailure)
    }

    public func run(progress: @escaping @Sendable (TransferProgress) -> Void = { _ in },
                    resolveConflicts: @escaping ConflictBatchResolver,
                    resolveFailure: FailureResolver? = nil) async -> TransferReport {
        await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                continuation.resume(returning: work(progress: progress, conflicts: resolveConflicts, failures: resolveFailure))
            }
            thread.name = "Arbor \(kind.rawValue) job"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Asks a batch one conflict at a time; "apply to remaining" answers the rest of its kind.
    public static func oneAtATime(_ single: @escaping ConflictResolver) -> ConflictBatchResolver {
        { conflicts in
            var answers: [ConflictDecision] = []
            var remembered: [ConflictKind: ConflictDecision] = [:]
            for conflict in conflicts {
                if answers.last?.choice == .cancel { answers.append(ConflictDecision(.cancel)); continue }
                if let known = remembered[conflict.kind] { answers.append(known); continue }
                let decision = await single(conflict)
                if decision.applyToRemaining { remembered[conflict.kind] = decision }
                answers.append(decision)
            }
            return answers
        }
    }

    private func work(progress: @escaping @Sendable (TransferProgress) -> Void,
                      conflicts: @escaping ConflictBatchResolver,
                      failures: FailureResolver?) -> TransferReport {
        progressSink = progress
        conflictResolver = conflicts
        failureResolver = failures
        control.onChange = { [weak self] in self?.emit(force: true) }
        defer { control.onChange = nil }

        var perSource: [TransferTotals?] = Array(repeating: nil, count: sources.count)
        let needsDiscovery = kind == .copy || sources.contains { !sameVolume($0, destination) }
        if needsDiscovery {
            update { $0.phase = .discovering }
            emit(force: true)
            var sum = TransferTotals()
            for (index, source) in sources.enumerated() {
                let base = sum
                guard let totals = TransferDiscovery.measure(source, control: control, onProgress: { [self] partial in
                    let found = base + partial
                    update { $0.currentName = source.lastPathComponent; $0.itemsDone = found.items; $0.bytesDone = found.bytes }
                    emit()
                }) else { break }
                perSource[index] = totals
                sum = sum + totals
                update { $0.itemsDone = sum.items; $0.bytesDone = sum.bytes }
            }
            if !isCancelled {
                discovered = true
                update { $0.itemsTotal = sum.items; $0.bytesTotal = sum.bytes; $0.itemsDone = 0; $0.bytesDone = 0 }
            }
        } else {
            update { $0.itemsTotal = sources.count }
        }

        let outcomes: [ItemOutcome]
        if isCancelled {
            outcomes = sources.map { _ in .cancelled }
            for index in sources.indices { journal?.record(index, .cancelled) }
        } else {
            update { $0.phase = .running }
            emit(force: true)
            outcomes = processLevel(sources, into: destination, top: true, totals: perSource)
        }
        update { $0.phase = .finishing; $0.currentName = nil; $0.completed = $0.total }
        emit(force: true)
        if isCancelled, retainsJournalWhenCancelled { journal?.abandon() } else { journal?.finish() }
        return TransferReport(kind: kind, destination: destination,
                              results: zip(sources, outcomes).map { ItemResult(source: $0, outcome: $1) },
                              details: details, wasCancelled: isCancelled, fingerprints: fingerprints)
    }

    // MARK: - Progress

    private func update(_ change: (inout TransferProgress) -> Void) {
        lock.withLock { change(&counters) }
    }

    private func snapshot() -> TransferProgress {
        var p = counters
        if control.isPaused, p.phase == .running { p.phase = .paused }
        return p
    }

    private func emit(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let progress: TransferProgress? = lock.withLock {
            guard force || now - lastEmit >= options.progressInterval else { return nil }
            lastEmit = now
            return snapshot()
        }
        if let progress { progressSink?(progress) }
    }

    private func account(_ totals: TransferTotals) {
        update { $0.itemsDone += totals.items; $0.bytesDone += totals.bytes }
        emit()
    }

    /// Counts an item that was handled without copying data (renamed, skipped, failed early).
    private func accountWhole(_ url: URL, known: TransferTotals?, top: Bool) {
        if let known { account(known); return }
        if discovered {
            account(TransferDiscovery.measure(url) ?? TransferTotals(items: 1))
        } else if top {
            account(TransferTotals(items: 1))
        }
    }

    private func makeEngine() -> CopyEngine {
        let engine = CopyEngine(control: control, allowClone: options.allowClone, verb: kind.verb)
        engine.bytesPerSecondLimit = options.bytesPerSecondLimit
        engine.bytesRemaining = { [unowned self] in lock.withLock { counters.bytesRemaining } }
        engine.hooks.bytes = { [unowned self] delta in
            update { $0.bytesDone += delta }
            emit()
        }
        engine.hooks.entryDone = { [unowned self] totals in account(totals) }
        engine.hooks.current = { [unowned self] url in
            update { $0.currentName = url.lastPathComponent }
            emit()
        }
        engine.hooks.failure = { [unowned self] failure in askFailure(failure) }
        engine.hooks.detail = { [unowned self] result in
            // The top-level item's own problem becomes its result, not a detail.
            if result.source.standardizedFileURL != currentTopSource { details.append(result) }
        }
        return engine
    }

    // MARK: - Decisions (block the worker until the UI answers)

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private func block<T>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private func waiting<T>(_ body: () -> T) -> T {
        let previous = lock.withLock { () -> TransferProgress.Phase in
            let p = counters.phase
            counters.phase = .waiting
            return p
        }
        emit(force: true)
        defer {
            update { $0.phase = previous }
            emit(force: true)
        }
        return body()
    }

    private func ask(_ conflicts: [Conflict]) -> [ConflictDecision] {
        guard let resolver = conflictResolver else { return conflicts.map { _ in ConflictDecision(.cancel) } }
        let answers = waiting { block { await resolver(conflicts) } }
        return conflicts.indices.map { answers.indices.contains($0) ? answers[$0] : ConflictDecision(.cancel) }
    }

    private func askFailure(_ failure: TransferFailure) -> FailureDecision {
        if skipFailures.contains(failure.kind), failure.allowsSkip { return FailureDecision(.skip) }
        guard let resolver = failureResolver else { return FailureDecision(.skip) }
        let decision = waiting { block { await resolver(failure) } }
        if decision.choice == .skip, decision.applyToRemaining { skipFailures.insert(failure.kind) }
        return decision
    }

    // MARK: - One folder level

    private struct Plan {
        enum Action {
            case immediate(ItemOutcome)
            case copy
            case conflict(ConflictKind, FileStamp?)
        }
        let source: URL
        let target: URL
        let action: Action
        let sourceIsFolder: Bool
    }

    private func plan(_ source: URL, in folder: URL) -> Plan {
        guard FileOps.exists(source) else {
            return Plan(source: source, target: folder, action: .immediate(.failed("The item no longer exists.")), sourceIsFolder: false)
        }
        let isFolder = FileOps.isPlainFolder(source)
        var target = folder.appendingPathComponent(source.lastPathComponent)
        // The destination may spell the source's own folder differently (other letter case,
        // a symbolic link): the "existing item" is then the source itself and must never be
        // offered for replacing (QA-CORE-1).
        let intoOwnFolder = target.standardizedFileURL == source || FileOps.isSameEntry(target, source)
        if isFolder && !intoOwnFolder && FileOps.isSameOrInsideOnDisk(folder, source) {
            return Plan(source: source, target: folder,
                        action: .immediate(.failed("The destination folder is inside the folder being \(kind.pastVerb).")),
                        sourceIsFolder: isFolder)
        }
        if intoOwnFolder {
            if kind == .move {
                return Plan(source: source, target: target, action: .immediate(.skipped("The item is already in this folder.")),
                            sourceIsFolder: isFolder)
            }
            let name = NameRules.duplicateName(for: source.lastPathComponent, treatAsFolder: isFolder) {
                FileOps.exists(folder.appendingPathComponent($0))
            }
            target = folder.appendingPathComponent(name)
            return Plan(source: source, target: target, action: .copy, sourceIsFolder: isFolder)
        }
        guard FileOps.exists(target) else { return Plan(source: source, target: target, action: .copy, sourceIsFolder: isFolder) }
        return Plan(source: source, target: target, action: .conflict(conflictKind(source: isFolder, target: target), FileStamp(target)),
                    sourceIsFolder: isFolder)
    }

    private func conflictKind(source isFolder: Bool, target: URL) -> ConflictKind {
        switch (isFolder, FileOps.isPlainFolder(target)) {
        case (true, true): return .folderOverFolder
        case (false, false): return .fileOverFile
        default: return .typeMismatch
        }
    }

    private func conflict(for plan: Plan, kind: ConflictKind, stamp: FileStamp?) -> Conflict {
        Conflict(source: plan.source, destination: plan.target, kind: kind,
                 sourceStamp: FileStamp(plan.source), destinationStamp: stamp)
    }

    private func processLevel(_ items: [URL], into folder: URL, top: Bool, totals: [TransferTotals?]) -> [ItemOutcome] {
        let plans = items.map { plan($0, in: folder) }

        // Ask about this level's conflicts together ("The destination has 3 files with the same names").
        var decisions: [Int: ConflictDecision] = [:]
        let pending = plans.indices.filter { index in
            if case .conflict(let kind, _) = plans[index].action { return sticky[kind] == nil }
            return false
        }
        if !pending.isEmpty, !isCancelled {
            let conflicts = pending.map { index -> Conflict in
                guard case .conflict(let kind, let stamp) = plans[index].action else { fatalError() }
                return conflict(for: plans[index], kind: kind, stamp: stamp)
            }
            let answers = ask(conflicts)
            for (n, index) in pending.enumerated() {
                decisions[index] = answers[n]
                if answers[n].applyToRemaining, answers[n].choice != .cancel { sticky[conflicts[n].kind] = answers[n].choice }
            }
            if answers.contains(where: { $0.choice == .cancel }) { control.cancel() }
        }

        var outcomes: [ItemOutcome] = []
        for (index, plan) in plans.enumerated() {
            if isCancelled {
                outcomes.append(.cancelled)
                if top { journal?.record(index, .cancelled) }
                continue
            }
            if top {
                currentTopSource = plan.source
                update { $0.completed = index; $0.currentName = plan.source.lastPathComponent }
                emit()
                if case .immediate = plan.action {} else { journal?.record(index, .started, destination: plan.target) }
            }
            let known = top && totals.indices.contains(index) ? totals[index] : nil
            let outcome = execute(plan, decision: decisions[index], top: top, known: known)
            if top {
                record(outcome, at: index)
                update { $0.completed = index + 1 }
                emit()
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    private func record(_ outcome: ItemOutcome, at index: Int) {
        guard let journal else { return }
        switch outcome {
        case .succeeded(let url), .merged(let url): journal.record(index, .committed, destination: url)
        case .copiedButSourceRemains(let url, let why): journal.record(index, .sourceRemains, destination: url, note: why)
        case .skipped(let why): journal.record(index, .skipped, note: why)
        case .failed(let why): journal.record(index, .failed, note: why)
        case .partial(let url, let why): journal.record(index, .partial, destination: url, note: why)
        case .cancelled: journal.record(index, .cancelled)
        }
    }

    private func execute(_ plan: Plan, decision: ConflictDecision?, top: Bool, known: TransferTotals?) -> ItemOutcome {
        switch plan.action {
        case .immediate(let outcome):
            accountWhole(plan.source, known: known, top: top)
            return outcome
        case .copy:
            guard FileOps.exists(plan.target) else { return perform(plan.source, to: plan.target, top: top, known: known) }
            // Something appeared there since the level was planned (FE-250): ask now.
            let kind = conflictKind(source: plan.sourceIsFolder, target: plan.target)
            let late = conflict(for: plan, kind: kind, stamp: FileStamp(plan.target))
            let choice = sticky[kind] ?? askOne(late).choice
            return apply(choice, plan, kind, top: top, known: known)
        case .conflict(let kind, let stamp):
            var choice = decision?.choice ?? sticky[kind] ?? .cancel
            if choice != .skip, choice != .cancel, !FileOps.exists(plan.target) {
                // The conflicting item went away meanwhile: nothing to replace, merge or rename around.
                return perform(plan.source, to: plan.target, top: top, known: known)
            }
            if choice == .replace, !(FileStamp(plan.target)?.sameState(as: stamp) ?? false) {
                // Replaced or edited while the dialog was open: the old answer doesn't cover it.
                let current = conflictKind(source: plan.sourceIsFolder, target: plan.target)
                choice = askOne(conflict(for: plan, kind: current, stamp: FileStamp(plan.target))).choice
                return apply(choice, plan, current, top: top, known: known)
            }
            return apply(choice, plan, kind, top: top, known: known)
        }
    }

    private func askOne(_ conflict: Conflict) -> ConflictDecision {
        let decision = ask([conflict])[0]
        if decision.applyToRemaining, decision.choice != .cancel { sticky[conflict.kind] = decision.choice }
        return decision
    }

    private func apply(_ choice: ConflictChoice, _ plan: Plan, _ kind: ConflictKind, top: Bool, known: TransferTotals?) -> ItemOutcome {
        let folder = plan.target.deletingLastPathComponent()
        switch choice {
        case .cancel:
            control.cancel()
            return .cancelled
        case .skip:
            accountWhole(plan.source, known: known, top: top)
            return .skipped("An item with the same name already exists.")
        case .keepBoth:
            let name = NameRules.keepBothName(for: plan.source.lastPathComponent, treatAsFolder: plan.sourceIsFolder) {
                FileOps.exists(folder.appendingPathComponent($0))
            }
            return perform(plan.source, to: folder.appendingPathComponent(name), top: top, known: known)
        case .merge:
            guard kind == .folderOverFolder else {
                accountWhole(plan.source, known: known, top: top)
                return .skipped("Only two folders can be merged.")
            }
            return merge(plan.source, into: plan.target, top: top)
        case .replace:
            if FileOps.isSameOrInsideOnDisk(plan.source, plan.target) {
                accountWhole(plan.source, known: known, top: top)
                return .failed("Can't replace a folder that contains the item being \(self.kind.pastVerb).")
            }
            if FileOps.exists(plan.target) {
                do { try disposeReplaced(plan.target) } catch {
                    accountWhole(plan.source, known: known, top: top)
                    return .failed("The existing “\(plan.target.lastPathComponent)” couldn't be moved to the Trash, so it wasn't replaced. \(error.localizedDescription)")
                }
            }
            return perform(plan.source, to: plan.target, top: top, known: known)
        }
    }

    private func merge(_ source: URL, into target: URL, top: Bool) -> ItemOutcome {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
                .filter { $0.lastPathComponent != ".DS_Store" }
                .map(\.standardizedFileURL)
        } catch {
            accountWhole(source, known: nil, top: top)
            return .failed("Couldn't read “\(source.lastPathComponent)”. \(error.localizedDescription)")
        }
        let outcomes = processLevel(children, into: target, top: false, totals: [])
        if discovered { account(TransferTotals(items: 1)) }   // the folder itself
        var hadProblem = false
        for (child, outcome) in zip(children, outcomes) {
            switch outcome {
            case .succeeded, .merged:
                break
            case .cancelled:
                return .cancelled
            default:
                if outcome.isProblem { hadProblem = true }
                if !details.contains(where: { $0.source == child }) { details.append(ItemResult(source: child, outcome: outcome)) }
            }
        }
        if kind == .move, !hadProblem, FileOps.isEffectivelyEmpty(source) {
            try? fileManager.removeItem(at: source)
        }
        return hadProblem ? .failed("Some items inside couldn't be merged.") : .merged(target)
    }

    // MARK: - Moving data

    private func perform(_ source: URL, to target: URL, top: Bool, known: TransferTotals?) -> ItemOutcome {
        if isCancelled { return .cancelled }
        if kind == .move, sameVolume(source, target.deletingLastPathComponent()) {
            while true {
                guard control.checkpoint() else { return .cancelled }
                if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                    accountWhole(target, known: known, top: top)
                    return .succeeded(target)
                }
                let error = errno
                if error == EXDEV || error == ENOTSUP { break }   // really another volume: copy instead
                let failure = TransferFailure.classify(errno: error, source: source, destination: target, stage: .moving)
                let decision = askFailure(failure)
                switch decision.choice {
                case .retry: continue
                case .skip:
                    accountWhole(source, known: known, top: top)
                    return .failed(failure.summary)
                case .cancel:
                    control.cancel()
                    return .cancelled
                }
            }
        }
        let outcome = engine.copyItem(source, to: target, moveSource: kind == .move)
        switch outcome {
        case .done:
            if kind == .move, FileOps.exists(source), !FileOps.isPlainFolder(source) || !FileOps.isEffectivelyEmpty(source) {
                return .copiedButSourceRemains(target, "Copied, but the original couldn't be removed.")
            }
            if kind == .copy, options.fingerprintCopies, top, let print = ItemFingerprint.of(target) {
                fingerprints[target] = print
            }
            return .succeeded(target)
        case .partial:
            return .partial(target, "Some items inside couldn't be \(kind.pastVerb).")
        case .skipped(let why):
            return .skipped(why)
        case .failed(let why):
            return .failed(why)
        case .cancelled(let leftContent):
            return leftContent ? .partial(target, "Stopped before everything was \(kind.pastVerb).") : .cancelled
        }
    }
}
