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
        if kind == .copy { return L10n.plural(one: "%lld item couldn't be copied.", other: "%lld items couldn't be copied.", count) }
        return L10n.plural(one: "%lld item couldn't be moved.", other: "%lld items couldn't be moved.", count)
    }

    static func succeededLine(_ kind: TransferKind, count: Int) -> String {
        if kind == .copy { return L10n.plural(one: "%lld item was copied successfully.", other: "%lld items were copied successfully.", count) }
        return L10n.plural(one: "%lld item was moved successfully.", other: "%lld items were moved successfully.", count)
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
