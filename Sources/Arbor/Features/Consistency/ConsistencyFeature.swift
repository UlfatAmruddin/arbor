import AppKit
import ArborCore

/// Makes features built separately behave the same everywhere: the search box per location, Back
/// restoring Home, Recent recording, item actions in every layout, context menus per location, sorting
/// by every column, previews of archive members, saved searches opened from Finder, and drive
/// capabilities in Properties. Requires the features whose contributions it adjusts (see `requires`).
/// See docs/features/consistency.md.
enum ConsistencyFeature: ExplorerFeature {
    static let id = "consistency"
    /// It adjusts what these install: the search box, context menus of their commands, sort values of their
    /// columns, archive member previews (outside the cloud gate) and click behaviors in every layout.
    static let requires = ["search", "archives", "trash", "cloud", "gallery-libraries", "folder-options", "item-actions", "home", "network", "properties"]
    static func register() {
        ConsistentSearch.register()
        ConsistentSorting.register()
        OpenedFilesRecorder.register()
        MenuAudit.register()
        MemberPreview.register()
        ItemActionsEverywhere.register()
        ConsistencyDebug.register()
    }
}
