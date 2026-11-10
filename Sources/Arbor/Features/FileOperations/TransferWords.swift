import Foundation
import ArborCore

/// Whole sentences for the English verbs transfers carry ("Copying", "moved"), so the transfer model stays presentation-free.
enum TransferWords {
    /// A format with the item count first, then the source and destination it has. Keys spelled out for the string table.
    static func fromToTemplate(verb: String, hasSource: Bool, hasDestination: Bool) -> String {
        switch (verb, hasSource, hasDestination) {
        case ("Moving", true, true): return L10n.template("Moving %@ from %@ to %@")
        case ("Moving", true, false): return L10n.template("Moving %@ from %@")
        case ("Moving", false, true): return L10n.template("Moving %@ to %@")
        case ("Moving", false, false): return L10n.template("Moving %@")
        case ("Extracting", true, true): return L10n.template("Extracting %@ from %@ to %@")
        case ("Extracting", true, false): return L10n.template("Extracting %@ from %@")
        case ("Extracting", false, true): return L10n.template("Extracting %@ to %@")
        case ("Extracting", false, false): return L10n.template("Extracting %@")
        case (_, true, true): return L10n.template("Copying %@ from %@ to %@")
        case (_, true, false): return L10n.template("Copying %@ from %@")
        case (_, false, true): return L10n.template("Copying %@ to %@")
        case (_, false, false): return L10n.template("Copying %@")
        }
    }

    static func failedTitle(_ kind: TransferKind, count: Int) -> String {
        let number = StatusText.number(count)
        if kind == .copy { return count == 1 ? L10n.tr("1 item couldn't be copied.") : L10n.format("%@ items couldn't be copied.", number) }
        return count == 1 ? L10n.tr("1 item couldn't be moved.") : L10n.format("%@ items couldn't be moved.", number)
    }

    static func succeededLine(_ kind: TransferKind, count: Int) -> String {
        let number = StatusText.number(count)
        if kind == .copy { return count == 1 ? L10n.tr("1 item was copied successfully.") : L10n.format("%@ items were copied successfully.", number) }
        return count == 1 ? L10n.tr("1 item was moved successfully.") : L10n.format("%@ items were moved successfully.", number)
    }

    static func folderBeing(_ pastVerb: String) -> String {
        switch pastVerb {
        case "moved": return L10n.tr("Folder being moved")
        case "extracted": return L10n.tr("Folder being extracted")
        default: return L10n.tr("Folder being copied")
        }
    }

    static func fileWillBeNamed(_ pastVerb: String, _ name: String) -> String {
        switch pastVerb {
        case "moved": return L10n.format("The file being moved will be named “%@”.", name)
        case "extracted": return L10n.format("The file being extracted will be named “%@”.", name)
        default: return L10n.format("The file being copied will be named “%@”.", name)
        }
    }

    static func folderWillBeNamed(_ pastVerb: String, _ name: String) -> String {
        switch pastVerb {
        case "moved": return L10n.format("The folder being moved will be named “%@”.", name)
        case "extracted": return L10n.format("The folder being extracted will be named “%@”.", name)
        default: return L10n.format("The folder being copied will be named “%@”.", name)
        }
    }
}
