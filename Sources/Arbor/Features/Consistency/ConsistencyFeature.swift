import AppKit
import ArborCore

/// Makes separately built features behave the same everywhere. See docs/features/consistency.md.
enum ConsistencyFeature: ExplorerFeature {
    static let id = "consistency"
    /// Features whose contributions this one adjusts.
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
