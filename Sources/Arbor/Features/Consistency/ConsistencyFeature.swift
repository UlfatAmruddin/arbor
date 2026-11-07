import AppKit
import ArborCore

/// Makes features built separately behave the same everywhere: the search box per location, Back
/// restoring Home, Recent recording, item actions in every layout, context menus per location, sorting
/// by every column, previews of archive members, saved searches opened from Finder, and drive
/// capabilities in Properties. Registered last so it can adjust what the other features installed.
/// See docs/features/consistency.md.
enum ConsistencyFeature {
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
