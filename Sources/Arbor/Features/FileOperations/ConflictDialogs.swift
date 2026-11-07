import AppKit
import ArborCore
import UniformTypeIdentifiers

/// Conflict handling in Explorer's words (FE-117, FE-118, FE-119; windows11-reference §9.2–9.4).
/// A batch is answered in Explorer's order: folders first ("Confirm Folder Replace"), then files
/// ("Replace or Skip Files", optionally the compare dialog), then file/folder name clashes.
enum ConflictFlow {
    /// Called from the job's worker; returns one decision per conflict, in order.
    static func resolve(_ conflicts: [Conflict], job: OperationCenter.Job) async -> [ConflictDecision] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                run(conflicts, job: job) { continuation.resume(returning: $0) }
            }
        }
    }

    static func run(_ conflicts: [Conflict], job: OperationCenter.Job, completion: @escaping ([ConflictDecision]) -> Void) {
        var answers = Array(repeating: ConflictDecision(.cancel), count: conflicts.count)
        let folders = conflicts.indices.filter { conflicts[$0].kind == .folderOverFolder }
        let files = conflicts.indices.filter { conflicts[$0].kind == .fileOverFile }
        let mismatches = conflicts.indices.filter { conflicts[$0].kind == .typeMismatch }

        func finish() { completion(answers) }
        func cancelAll() { completion(conflicts.map { _ in ConflictDecision(.cancel) }) }

        func askMismatches(_ remaining: ArraySlice<Int>) {
            guard let index = remaining.first else { return finish() }
            NameClashDialog(conflicts[index], job: job) { decision in
                answers[index] = decision
                if decision.choice == .cancel { return cancelAll() }
                if decision.applyToRemaining {
                    for other in remaining.dropFirst() { answers[other] = decision }
                    return finish()
                }
                askMismatches(remaining.dropFirst())
            }.present(over: job.window)
        }

        func askFiles() {
            guard !files.isEmpty else { return askMismatches(mismatches[...]) }
            ReplaceOrSkipDialog(files.map { conflicts[$0] }, job: job) { decisions in
                guard let decisions else { return cancelAll() }
                for (index, decision) in zip(files, decisions) { answers[index] = decision }
                askMismatches(mismatches[...])
            }.present(over: job.window)
        }

        func askFolders(_ remaining: ArraySlice<Int>) {
            guard let index = remaining.first else { return askFiles() }
            if Prefs.hideFolderMergeConflicts {
                for other in remaining { answers[other] = ConflictDecision(.merge) }
                return askFiles()
            }
            FolderMergeDialog(conflicts[index], job: job) { decision in
                answers[index] = decision
                if decision.choice == .cancel { return cancelAll() }
                if decision.applyToRemaining {
                    for other in remaining.dropFirst() { answers[other] = decision }
                    return askFiles()
                }
                askFolders(remaining.dropFirst())
            }.present(over: job.window)
        }

        askFolders(folders[...])
    }

    // MARK: Shared formatting

    static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func icon(for url: URL, isFolder: Bool, size: CGFloat) -> NSImage {
        let image: NSImage
        if isFolder {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            image = NSWorkspace.shared.icon(for: type)
        }
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: size, height: size)
        return copy
    }

    static func open(_ url: URL) {
        BrowserWindowController.active?.openTab(.folder(url))
    }
}

// MARK: - Replace or Skip Files

/// "Replace or Skip Files": one dialog for every file conflict found at one folder level.
final class ReplaceOrSkipDialog: FileOpsDialog {
    private let conflicts: [Conflict]
    private let job: OperationCenter.Job
    private let completion: ([ConflictDecision]?) -> Void
    private let applyAll = NSButton(checkboxWithTitle: "Do this for all current items", target: nil, action: nil)
    private let details = NSStackView()
    private var answered = false

    init(_ conflicts: [Conflict], job: OperationCenter.Job, completion: @escaping ([ConflictDecision]?) -> Void) {
        self.conflicts = conflicts
        self.job = job
        self.completion = completion
        super.init(title: "Replace or Skip Files", width: 470)
        let many = conflicts.count > 1
        let transfer = job.transfer
        let header = fromToLine(verb: job.presentedAs?.progressVerb ?? transfer.kind.progressVerb, count: transfer.sources.count,
                                source: job.presentedAs?.source ?? conflicts.first?.source.deletingLastPathComponent(),
                                destination: conflicts.first?.destination.deletingLastPathComponent(), open: ConflictFlow.open)
        let instruction = FileOpsStyle.label(
            many ? "The destination has \(conflicts.count) files with the same names"
                 : "The destination already has a file named “\(conflicts[0].destination.lastPathComponent)”",
            font: FileOpsStyle.instructionFont, wraps: true)
        instruction.preferredMaxLayoutWidth = 430
        let replace = CommandLinkButton(symbol: "checkmark",
                                        title: many ? "Replace the files in the destination" : "Replace the file in the destination",
                                        detail: many ? "The existing files go to the Trash." : "The existing file goes to the Trash.") { [weak self] in
            self?.answer(conflicts.map { _ in .replace })
        }
        let skip = CommandLinkButton(symbol: "arrowshape.turn.up.right",
                                     title: many ? "Skip these files" : "Skip this file") { [weak self] in
            self?.answer(conflicts.map { _ in .skip })
        }
        let decide = CommandLinkButton(symbol: "rectangle.on.rectangle",
                                       title: many ? "Let me decide for each file" : "Compare info for both files") { [weak self] in
            self?.compare()
        }
        applyAll.font = FileOpsStyle.bodyFont
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 3
        details.isHidden = true
        for conflict in conflicts.prefix(6) {
            let text = "\(conflict.destination.lastPathComponent): incoming \(Self.describe(conflict.sourceStamp)); existing \(Self.describe(conflict.destinationStamp))"
            details.addArrangedSubview(FileOpsStyle.label(text, font: FileOpsStyle.captionFont, color: Theme.secondaryText))
        }
        if conflicts.count > 6 {
            details.addArrangedSubview(FileOpsStyle.label("…and \(conflicts.count - 6) more", font: FileOpsStyle.captionFont, color: Theme.secondaryText))
        }
        let options = NSStackView(views: [replace, skip, decide])
        options.orientation = .vertical
        options.spacing = 2
        options.alignment = .leading
        for option in [replace, skip, decide] { option.widthAnchor.constraint(equalToConstant: 430).isActive = true }
        let body = setBody([header, instruction, options, applyAll, details], spacing: 10)
        body.setCustomSpacing(16, after: instruction)
        let toggle = DetailsToggle()
        toggle.onToggle = { [weak self] expanded in
            self?.details.isHidden = !expanded
            self?.refit()
        }
        setButtons([], leading: [toggle])
    }

    static func describe(_ stamp: FileStamp?) -> String {
        guard let stamp else { return "unavailable" }
        return "\(StatusText.bytes(stamp.size)), modified \(ConflictFlow.dates.string(from: stamp.modified))"
    }

    private func answer(_ choices: [ConflictChoice]) {
        guard !answered else { return }
        answered = true
        let all = applyAll.state == .on
        dismiss()
        completion(choices.map { ConflictDecision($0, applyToRemaining: all) })
    }

    private func compare() {
        guard !answered else { return }
        answered = true
        dismiss()
        // Per-file answers: "Do this for all current items" can't name one choice here.
        CompareDialog(conflicts, job: job, completion: completion).present(over: job.window)
    }

    override func cancelled() {
        guard !answered else { return }
        answered = true
        dismiss()
        completion(nil)
    }
}

// MARK: - Compare ("Let me decide for each file")

/// "N File Conflicts": pick which version of each file to keep. Both → keep both, with a number
/// added to the copied file's name. Continue is enabled once every file has a choice.
final class CompareDialog: FileOpsDialog, NSTableViewDataSource, NSTableViewDelegate {
    private let conflicts: [Conflict]
    private let completion: ([ConflictDecision]?) -> Void
    private var keepSource: [Bool]
    private var keepExisting: [Bool]
    private let table = NSTableView()
    private let sourceHeader: NSButton
    private let existingHeader: NSButton
    private let skipSame: NSButton
    private let continueButton = WinButton("Continue", accent: true)
    private let sameIndices: Set<Int>
    private var answered = false

    init(_ conflicts: [Conflict], job: OperationCenter.Job, completion: @escaping ([ConflictDecision]?) -> Void) {
        self.conflicts = conflicts
        self.completion = completion
        keepSource = Array(repeating: false, count: conflicts.count)
        keepExisting = Array(repeating: false, count: conflicts.count)
        sameIndices = Set(conflicts.indices.filter { i in
            guard let a = conflicts[i].sourceStamp, let b = conflicts[i].destinationStamp else { return false }
            return a.size == b.size && abs(a.modified.timeIntervalSince(b.modified)) < 2
        })
        let source = job.presentedAs.map { $0.source.lastPathComponent }
            ?? conflicts.first.map { displayName(of: $0.source.deletingLastPathComponent()) } ?? ""
        let destination = conflicts.first.map { displayName(of: $0.destination.deletingLastPathComponent()) } ?? ""
        sourceHeader = NSButton(checkboxWithTitle: "Files from \(source)", target: nil, action: nil)
        existingHeader = NSButton(checkboxWithTitle: "Files already in \(destination)", target: nil, action: nil)
        skipSame = NSButton(checkboxWithTitle: "Skip \(sameIndices.count) \(sameIndices.count == 1 ? "file" : "files") with the same date and size",
                            target: nil, action: nil)
        super.init(title: conflicts.count == 1 ? "1 File Conflict" : "\(conflicts.count) File Conflicts", width: 620)

        let heading = FileOpsStyle.label("Which files do you want to keep?", font: FileOpsStyle.instructionFont)
        let hint = FileOpsStyle.label("If you select both versions, the copied file will have a number added to its name.",
                                      font: FileOpsStyle.captionFont, color: Theme.secondaryText, wraps: true)
        hint.preferredMaxLayoutWidth = 580
        for box in [sourceHeader, existingHeader, skipSame] {
            box.font = FileOpsStyle.bodyFont
            box.target = self
        }
        sourceHeader.action = #selector(toggleAllSource)
        existingHeader.action = #selector(toggleAllExisting)
        skipSame.action = #selector(toggleSkipSame)
        skipSame.isHidden = sameIndices.isEmpty
        let headers = NSStackView(views: [sourceHeader, existingHeader])
        headers.distribution = .fillEqually
        headers.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pair"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 74
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let visibleRows = CGFloat(min(conflicts.count, 4))
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: visibleRows * 74 + 2),
            scroll.widthAnchor.constraint(equalToConstant: 580),
            headers.widthAnchor.constraint(equalToConstant: 580),
        ])
        column.width = 578
        setBody([heading, hint, headers, scroll, skipSame], spacing: 10)

        continueButton.onPress = { [weak self] in self?.finish() }
        let cancel = WinButton("Cancel") { [weak self] in self?.cancelled() }
        setButtons([continueButton, cancel])
        refreshState()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { conflicts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let skipping = skipSame.state == .on && sameIndices.contains(row)
        return ConflictPairRow(conflicts[row], keepSource: keepSource[row], keepExisting: keepExisting[row], disabled: skipping) { [weak self] side, value in
            guard let self else { return }
            if side == 0 { keepSource[row] = value } else { keepExisting[row] = value }
            refreshState()
        }
    }

    @objc private func toggleAllSource() {
        keepSource = Array(repeating: sourceHeader.state == .on, count: conflicts.count)
        refreshState(reload: true)
    }

    @objc private func toggleAllExisting() {
        keepExisting = Array(repeating: existingHeader.state == .on, count: conflicts.count)
        refreshState(reload: true)
    }

    @objc private func toggleSkipSame() { refreshState(reload: true) }

    private func refreshState(reload: Bool = false) {
        if reload { table.reloadData() }
        let skipping = skipSame.state == .on
        let decided = conflicts.indices.allSatisfy { (skipping && sameIndices.contains($0)) || keepSource[$0] || keepExisting[$0] }
        continueButton.isEnabled = decided
        sourceHeader.state = keepSource.allSatisfy { $0 } ? .on : .off
        existingHeader.state = keepExisting.allSatisfy { $0 } ? .on : .off
    }

    private func finish() {
        guard !answered, continueButton.isEnabled else { return }
        answered = true
        let skipping = skipSame.state == .on
        let decisions = conflicts.indices.map { i -> ConflictDecision in
            if skipping && sameIndices.contains(i) { return ConflictDecision(.skip) }
            switch (keepSource[i], keepExisting[i]) {
            case (true, true): return ConflictDecision(.keepBoth)
            case (true, false): return ConflictDecision(.replace)
            default: return ConflictDecision(.skip)
            }
        }
        dismiss()
        completion(decisions)
    }

    override func cancelled() {
        guard !answered else { return }
        answered = true
        dismiss()
        completion(nil)
    }

    /// Scripts: "opcompare:source|existing|both|skipsame".
    func scriptChoose(_ what: String) {
        switch what {
        case "source": keepSource = keepSource.map { _ in true }
        case "existing": keepExisting = keepExisting.map { _ in true }
        case "both":
            keepSource = keepSource.map { _ in true }
            keepExisting = keepExisting.map { _ in true }
        case "skipsame": skipSame.state = .on
        default: break
        }
        refreshState(reload: true)
    }
}

/// One file in the compare dialog: its name, then incoming (left) and existing (right) versions.
final class ConflictPairRow: NSView {
    private let onChange: (Int, Bool) -> Void

    init(_ conflict: Conflict, keepSource: Bool, keepExisting: Bool, disabled: Bool, onChange: @escaping (Int, Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        let name = FileOpsStyle.label(conflict.destination.lastPathComponent, font: .systemFont(ofSize: 13, weight: .semibold))
        let newer = Self.compare(conflict.sourceStamp, conflict.destinationStamp)
        let left = side(conflict.source, conflict.sourceStamp, checked: keepSource, tag: 0, newer: newer.sourceNewer, larger: newer.sourceLarger, disabled: disabled)
        let right = side(conflict.destination, conflict.destinationStamp, checked: keepExisting, tag: 1, newer: newer.existingNewer, larger: newer.existingLarger, disabled: disabled)
        let pair = NSStackView(views: [left, right])
        pair.distribution = .fillEqually
        let column = NSStackView(views: [name, pair])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            pair.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -8),
        ])
        alphaValue = disabled ? 0.45 : 1
    }
    required init?(coder: NSCoder) { fatalError() }

    static func compare(_ a: FileStamp?, _ b: FileStamp?) -> (sourceNewer: Bool, existingNewer: Bool, sourceLarger: Bool, existingLarger: Bool) {
        guard let a, let b else { return (false, false, false, false) }
        // Whole seconds, like Explorer's displayed dates: sub-second differences aren't "newer".
        let delta = a.modified.timeIntervalSince(b.modified)
        return (delta >= 1, delta <= -1, a.size > b.size, b.size > a.size)
    }

    private func side(_ url: URL, _ stamp: FileStamp?, checked: Bool, tag: Int, newer: Bool, larger: Bool, disabled: Bool) -> NSView {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        box.tag = tag
        box.state = checked ? .on : .off
        box.isEnabled = !disabled
        box.setAccessibilityLabel(tag == 0 ? "Keep the file being copied" : "Keep the existing file")
        let icon = NSImageView(image: ConflictFlow.icon(for: url, isFolder: false, size: 32))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let date = stamp.map { ConflictFlow.dates.string(from: $0.modified) + (newer ? " (newer)" : "") } ?? "Date unavailable"
        let size = stamp.map { StatusText.bytes($0.size) + (larger ? " (larger)" : "") } ?? ""
        let info = NSStackView(views: [FileOpsStyle.label(date, font: FileOpsStyle.captionFont),
                                       FileOpsStyle.label(size, font: FileOpsStyle.captionFont, color: Theme.secondaryText)])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 1
        let row = NSStackView(views: [box, icon, info])
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    @objc private func toggled(_ sender: NSButton) { onChange(sender.tag, sender.state == .on) }
}

// MARK: - Folder merge

/// "Confirm Folder Replace" (windows11-reference §9.4), worded for what Arbor does: the folders
/// are merged and files with the same names are asked about separately, never replaced silently.
final class FolderMergeDialog: FileOpsDialog {
    private let completion: (ConflictDecision) -> Void
    private let applyAll = NSButton(checkboxWithTitle: "Do this for all current items", target: nil, action: nil)
    private var answered = false

    init(_ conflict: Conflict, job: OperationCenter.Job, completion: @escaping (ConflictDecision) -> Void) {
        self.completion = completion
        super.init(title: "Confirm Folder Replace", width: 470)
        let name = conflict.destination.lastPathComponent
        let instruction = FileOpsStyle.label("This destination already contains a folder named “\(name)”.",
                                             font: FileOpsStyle.instructionFont, wraps: true)
        instruction.preferredMaxLayoutWidth = 430
        let explain = FileOpsStyle.label(
            "If the files in the existing folder have the same names as files in the folder you're \(job.presentedAs?.gerund ?? (job.transfer.kind == .copy ? "copying" : "moving")), you'll be asked whether to replace them. Do you still want to \(job.presentedAs?.verb ?? job.transfer.kind.verb) the folder?",
            wraps: true)
        explain.preferredMaxLayoutWidth = 430
        let existing = Self.folderRow(conflict.destination, conflict.destinationStamp, caption: "Existing folder")
        let incoming = Self.folderRow(conflict.source, conflict.sourceStamp, caption: "Folder being \(job.presentedAs?.pastVerb ?? job.transfer.kind.pastVerb)")
        applyAll.font = FileOpsStyle.bodyFont
        let body = setBody([instruction, explain, existing, incoming, applyAll], spacing: 10)
        body.setCustomSpacing(16, after: explain)
        let yes = WinButton("Yes", accent: true) { [weak self] in self?.answer(.merge) }
        let no = WinButton("No") { [weak self] in self?.answer(.skip) }
        let cancel = WinButton("Cancel") { [weak self] in self?.answer(.cancel) }
        setButtons([yes, no, cancel])
    }

    static func folderRow(_ url: URL, _ stamp: FileStamp?, caption: String) -> NSView {
        let icon = NSImageView(image: IconProvider.shared.icon(for: .folder(url), size: 32))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let date = stamp.map { "Date modified: \(ConflictFlow.dates.string(from: $0.modified))" } ?? ""
        let text = NSStackView(views: [
            FileOpsStyle.label("\(caption): \(url.lastPathComponent)", font: FileOpsStyle.bodyFont),
            FileOpsStyle.label(date, font: FileOpsStyle.captionFont, color: Theme.secondaryText),
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        return row
    }

    private func answer(_ choice: ConflictChoice) {
        guard !answered else { return }
        answered = true
        dismiss()
        completion(ConflictDecision(choice, applyToRemaining: choice != .cancel && applyAll.state == .on))
    }

    override func cancelled() { answer(.cancel) }
}

// MARK: - File/folder name clash

/// A file where a folder of the same name exists, or the reverse. They can't replace each other,
/// so the choices are to keep both (the incoming item gets a number) or skip it.
final class NameClashDialog: FileOpsDialog {
    private let completion: (ConflictDecision) -> Void
    private let applyAll = NSButton(checkboxWithTitle: "Do this for all current items", target: nil, action: nil)
    private var answered = false

    init(_ conflict: Conflict, job: OperationCenter.Job, completion: @escaping (ConflictDecision) -> Void) {
        self.completion = completion
        super.init(title: "Replace or Skip Files", width: 470)
        let existingIsFolder = conflict.destinationStamp?.isFolder ?? FileOps.isPlainFolder(conflict.destination)
        let name = conflict.destination.lastPathComponent
        let header = fromToLine(verb: job.presentedAs?.progressVerb ?? job.transfer.kind.progressVerb, count: job.transfer.sources.count,
                                source: job.presentedAs?.source ?? conflict.source.deletingLastPathComponent(),
                                destination: conflict.destination.deletingLastPathComponent(), open: ConflictFlow.open)
        let instruction = FileOpsStyle.label("The destination already has a \(existingIsFolder ? "folder" : "file") named “\(name)”",
                                             font: FileOpsStyle.instructionFont, wraps: true)
        instruction.preferredMaxLayoutWidth = 430
        let explain = FileOpsStyle.label("A file and a folder can't replace each other.", color: Theme.secondaryText)
        let newName = NameRules.keepBothName(for: conflict.source.lastPathComponent, treatAsFolder: !existingIsFolder) { _ in false }
        let keep = CommandLinkButton(symbol: "plus.square.on.square", title: "Keep both",
                                     detail: "The \(existingIsFolder ? "file" : "folder") being \(job.presentedAs?.pastVerb ?? job.transfer.kind.pastVerb) will be named “\(newName)”.") { [weak self] in
            self?.answer(.keepBoth)
        }
        let skip = CommandLinkButton(symbol: "arrowshape.turn.up.right", title: "Skip this item") { [weak self] in self?.answer(.skip) }
        for option in [keep, skip] { option.widthAnchor.constraint(equalToConstant: 430).isActive = true }
        applyAll.font = FileOpsStyle.bodyFont
        setBody([header, instruction, explain, keep, skip, applyAll], spacing: 8)
        setButtons([WinButton("Cancel") { [weak self] in self?.answer(.cancel) }])
    }

    private func answer(_ choice: ConflictChoice) {
        guard !answered else { return }
        answered = true
        dismiss()
        completion(ConflictDecision(choice, applyToRemaining: choice != .cancel && applyAll.state == .on))
    }

    override func cancelled() { answer(.cancel) }
}
