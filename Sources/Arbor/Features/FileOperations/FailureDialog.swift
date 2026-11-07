import AppKit
import ArborCore

/// "File In Use", "File Access Denied", "Not Enough Space", "Item Not Found", "Interrupted Action"
/// (FE-120, FE-121; windows11-reference §9.6). Names the item, says why, and offers Try Again,
/// Skip (when skipping makes sense) and Cancel. The job waits; nothing is retried automatically.
final class FailureDialog: FileOpsDialog {
    private let completion: (FailureDecision) -> Void
    private let applyAll = NSButton(checkboxWithTitle: "Do this for all current items", target: nil, action: nil)
    private var answered = false

    static func resolve(_ failure: TransferFailure, job: OperationCenter.Job) async -> FailureDecision {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                FailureDialog(failure, job: job) { continuation.resume(returning: $0) }.present(over: job.window)
            }
        }
    }

    init(_ failure: TransferFailure, job: OperationCenter.Job, completion: @escaping (FailureDecision) -> Void) {
        self.completion = completion
        super.init(title: failure.title, width: 470)
        let transfer = job.transfer
        let header = fromToLine(verb: transfer.kind.progressVerb, count: transfer.sources.count,
                                source: transfer.sources.first?.deletingLastPathComponent(), destination: transfer.destination,
                                open: ConflictFlow.open)
        let volume = (try? transfer.destination.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        let instruction = FileOpsStyle.label(failure.message(verb: transfer.kind.verb, volumeName: volume),
                                             font: FileOpsStyle.instructionFont, wraps: true)
        instruction.preferredMaxLayoutWidth = 430
        let item = Self.itemRow(failure.source)
        let hint = FileOpsStyle.label(failure.hint, color: Theme.secondaryText, wraps: true)
        hint.preferredMaxLayoutWidth = 430
        applyAll.font = FileOpsStyle.bodyFont
        applyAll.isHidden = !failure.allowsSkip
        let body = setBody([header, instruction, item, hint, applyAll], spacing: 10)
        body.setCustomSpacing(16, after: instruction)
        var buttons: [NSView] = [WinButton("Try Again", accent: true) { [weak self] in self?.answer(.retry) }]
        if failure.allowsSkip { buttons.append(WinButton("Skip") { [weak self] in self?.answer(.skip) }) }
        buttons.append(WinButton("Cancel") { [weak self] in self?.answer(.cancel) })
        setButtons(buttons)
    }

    /// Icon, name, type, size and date of the item, like Explorer's error dialogs.
    static func itemRow(_ url: URL) -> NSView {
        let item = FileItem(url: url)
        let icon = NSImageView(image: item.map { IconProvider.shared.icon(for: $0, size: 40) } ?? ConflictFlow.icon(for: url, isFolder: false, size: 40))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        var lines = [FileOpsStyle.label(url.lastPathComponent, font: .systemFont(ofSize: 13, weight: .semibold))]
        if let item {
            var facts: [String] = []
            if let size = item.size { facts.append("Size: \(StatusText.bytes(size))") }
            if let date = item.modified { facts.append("Date modified: \(ConflictFlow.dates.string(from: date))") }
            if !facts.isEmpty { lines.append(FileOpsStyle.label(facts.joined(separator: "   "), font: FileOpsStyle.captionFont, color: Theme.secondaryText)) }
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        return row
    }

    private func answer(_ choice: FailureChoice) {
        guard !answered else { return }
        answered = true
        dismiss()
        completion(FailureDecision(choice, applyToRemaining: choice == .skip && applyAll.state == .on))
    }

    override func cancelled() { answer(.cancel) }
}
