import Foundation
import ArborCore

/// Translations of the English verbs transfers carry ("Copying", "moved"), so the transfer model stays presentation-free.
enum TransferWords {
    private static let words: [String: String] = [
        "Copying": L10n.tr("Copying"), "Moving": L10n.tr("Moving"), "Extracting": L10n.tr("Extracting"),
        "copied": L10n.tr("copied"), "moved": L10n.tr("moved"), "extracted": L10n.tr("extracted"),
    ]

    static func localized(_ word: String) -> String { words[word] ?? L10n.tr(word) }
}
