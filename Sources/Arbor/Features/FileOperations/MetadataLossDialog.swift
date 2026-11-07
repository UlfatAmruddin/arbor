import AppKit
import ArborCore

/// Windows' "Property Loss" dialog: "Are you sure you want to copy this file without its
/// properties?" with Yes · Skip · Cancel and "Do this for all current items" (windows11-reference
/// §9.6). Asked when the destination volume can't store an item's Finder tags, comments, resource
/// fork, other extended attributes or access list (FAT32, exFAT, SMB shares without named streams).
final class MetadataLossDialog: FileOpsDialog {
    private let completion: (MetadataLossDecision) -> Void
    private let applyAll = NSButton(checkboxWithTitle: "Do this for all current items", target: nil, action: nil)
    private var answered = false
    let loss: MetadataLoss

    static func install() {
        OperationCenter.prepareJob = { job in
            job.transfer.metadataLossResolver = { loss in await MetadataLossDialog.resolve(loss, job: job) }
        }
    }

    static func resolve(_ loss: MetadataLoss, job: OperationCenter.Job) async -> MetadataLossDecision {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MetadataLossDialog(loss, job: job) { continuation.resume(returning: $0) }.present(over: job.window)
            }
        }
    }

    init(_ loss: MetadataLoss, job: OperationCenter.Job, completion: @escaping (MetadataLossDecision) -> Void) {
        self.loss = loss
        self.completion = completion
        super.init(title: "Property Loss", width: 470)
        let transfer = job.transfer
        let header = fromToLine(verb: transfer.kind.progressVerb, count: transfer.sources.count,
                                source: transfer.sources.first?.deletingLastPathComponent(), destination: transfer.destination,
                                open: ConflictFlow.open)
        let isFolder = FileOps.isPlainFolder(loss.source)
        let instruction = FileOpsStyle.label("Are you sure you want to copy this \(isFolder ? "item" : "file") without its properties?",
                                             font: FileOpsStyle.instructionFont, wraps: true)
        instruction.preferredMaxLayoutWidth = 430
        let item = FailureDialog.itemRow(loss.source)
        let hint = FileOpsStyle.label(Self.explanation(loss), color: Theme.secondaryText, wraps: true)
        hint.preferredMaxLayoutWidth = 430
        applyAll.font = FileOpsStyle.bodyFont
        let body = setBody([header, instruction, item, hint, applyAll], spacing: 10)
        body.setCustomSpacing(16, after: instruction)
        setButtons([WinButton("Yes", accent: true) { [weak self] in self?.answer(.copyWithout) },
                    WinButton("Skip") { [weak self] in self?.answer(.skip) },
                    WinButton("Cancel") { [weak self] in self?.answer(.cancel) }])
    }

    /// Names the drive, its format and what can't be kept, in plain words.
    static func explanation(_ loss: MetadataLoss) -> String {
        let caps = loss.capabilities
        let drive = caps.volumeName.map { "“\($0)”" } ?? "The destination"
        let format = caps.formatName.isEmpty ? "" : " (\(caps.formatName))"
        var text = "\(drive)\(format) can't store this item's \(loss.lost.description)."
        let attributes = loss.lost.subtracting(.accessList)
        if !attributes.isEmpty {
            text += " macOS keeps Mac-only properties in hidden “._” files there, which Windows and other devices ignore or delete."
        }
        if loss.lost.contains(.accessList) { text += " Access-list permissions are left out." }
        return text
    }

    private func answer(_ choice: MetadataLossChoice) {
        guard !answered else { return }
        answered = true
        dismiss()
        completion(MetadataLossDecision(choice, applyToRemaining: choice != .cancel && applyAll.state == .on))
    }

    override func cancelled() { answer(.cancel) }
}
