import AppKit
import ArborCore

/// Files opened from Arbor go to Home ▸ Recent however they were opened (docs/features/consistency.md):
/// double-click and Return in any view already go through `BrowserWindowController.open`; "Open With ▸"
/// launched apps directly, so its items now report the files too. Read-only temporary copies of
/// archive members are never recorded (they are deleted later and aren't the user's files).
enum OpenedFilesRecorder {
    static func register() {
        CommandRegistry.shared.adjustSubmenu("file.openWith", "consistency.record-opened-files") { items, ctx in
            guard !ArchiveFeature.inArchive(ctx) else { return items }
            let urls = ctx.selection.filter { !$0.isFolder }.map(\.url)
            guard !urls.isEmpty else { return items }
            return items.map { wrap($0, urls: urls, window: ctx.window) }
        }
    }

    /// The same item, also posting `LocationEvents.didOpenFiles`. (Headless test runs only log the launch:
    /// the item opens through `SystemOpen`.)
    static func wrap(_ item: NSMenuItem, urls: [URL], window: BrowserWindowController?) -> NSMenuItem {
        guard let action = item.action, item.submenu == nil, !item.isSeparatorItem else { return item }
        let original = item
        let wrapped = ClosureMenuItem(item.title, image: item.image) { [weak window] in
            NSApp.sendAction(action, to: original.target, from: original)
            NotificationCenter.default.post(name: LocationEvents.didOpenFiles, object: window, userInfo: ["urls": urls])
        }
        wrapped.toolTip = item.toolTip
        wrapped.isEnabled = item.isEnabled
        return wrapped
    }
}
