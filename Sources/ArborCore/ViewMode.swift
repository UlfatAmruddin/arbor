import Foundation

/// Explorer's eight layouts (spec §6.1), in the order of its Ctrl+Shift+1…8 shortcuts.
/// "Compact view" is a separate density setting, not a mode.
public enum ViewMode: String, CaseIterable, Sendable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles, content

    public var title: String {
        switch self {
        case .extraLargeIcons: return "Extra large icons"
        case .largeIcons: return "Large icons"
        case .mediumIcons: return "Medium icons"
        case .smallIcons: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        case .content: return "Content"
        }
    }

    /// 1…8, matching Ctrl+Shift+digit in Explorer (⇧⌘digit here).
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public var symbolName: String {
        switch self {
        case .extraLargeIcons, .largeIcons: return "square.grid.2x2"
        case .mediumIcons: return "square.grid.3x2"
        case .smallIcons: return "square.grid.3x3"
        case .list: return "list.bullet"
        case .details: return "list.bullet.rectangle"
        case .tiles: return "rectangle.grid.2x2"
        case .content: return "rectangle.grid.1x2"
        }
    }
}
