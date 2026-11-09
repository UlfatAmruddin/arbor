import ArborCore

/// What a place can refuse; every provider answers for each one, so a greyed command always has a reason (FE-231).
enum LocationAction: CaseIterable {
    case newItem, paste, cut, copy, rename, trash, deletePermanently

    /// The commands that carry the action out.
    var commandIDs: [String] {
        switch self {
        case .newItem: return ["file.newFolder", "menu.new"]
        case .paste: return ["edit.paste", "edit.pasteMove", "edit.pasteShortcut"]
        case .cut: return ["edit.cut"]
        case .copy: return ["edit.copy"]
        case .rename: return ["file.rename"]
        case .trash: return ["file.trash"]
        case .deletePermanently: return ["file.deletePermanently"]
        }
    }

    private static let byCommandID = Dictionary(uniqueKeysWithValues: allCases.flatMap { action in action.commandIDs.map { ($0, action) } })

    init?(commandID: String) {
        guard let action = Self.byCommandID[commandID] else { return nil }
        self = action
    }

    /// The answer of a page that isn't a folder. `itemsAreFiles`: what it shows can still be cut, renamed or deleted.
    func notAFolderLimitation(itemsAreFiles: Bool = false) -> String? {
        switch self {
        case .newItem, .paste:
            return L10n.tr("This page isn't a folder, so new or pasted items have nowhere to go. Open a folder first.")
        case .copy:
            return nil
        case .cut, .rename, .trash, .deletePermanently:
            return itemsAreFiles ? nil : L10n.tr("Items on this page can't be changed from here. Open the folder that holds them first.")
        }
    }
}
