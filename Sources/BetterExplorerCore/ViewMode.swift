import Foundation

/// Explorer's eight layouts (spec §6.1) in Ctrl+Shift+1…8 order. "Compact view" is a density setting, not a mode.
public enum ViewMode: String, CaseIterable, Sendable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles, content

    public var title: String {
        switch self {
        case .extraLargeIcons: return L10n.tr("Extra large icons")
        case .largeIcons: return L10n.tr("Large icons")
        case .mediumIcons: return L10n.tr("Medium icons")
        case .smallIcons: return L10n.tr("Small icons")
        case .list: return L10n.tr("List")
        case .details: return L10n.tr("Details")
        case .tiles: return L10n.tr("Tiles")
        case .content: return L10n.tr("Content")
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
