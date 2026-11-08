import Foundation
import ArborCore

/// Translations of the verbs that transfers and presented jobs carry as English words ("Copying", "moved",
/// "extracted"). The progress, conflict and failure dialogs place them into sentences; the string table gets
/// them from here, so the transfer model itself stays free of presentation.
enum TransferWords {
    private static let words: [String: String] = [
        "Copying": L10n.tr("Copying"), "Moving": L10n.tr("Moving"), "Extracting": L10n.tr("Extracting"),
        "copied": L10n.tr("copied"), "moved": L10n.tr("moved"), "extracted": L10n.tr("extracted"),
    ]

    static func localized(_ word: String) -> String { words[word] ?? L10n.tr(word) }
}
