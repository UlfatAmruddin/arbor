import AppKit
import ArborCore

/// Records files opened with Open With ▸ in Home ▸ Recent too; archive member temp copies never are.
enum OpenedFilesRecorder {
    static func register() {
        CommandRegistry.shared.adjustSubmenu("file.openWith", "consistency.record-opened-files") { items, ctx in
            guard !ArchiveFeature.inArchive(ctx) else { return items }
            let urls = ctx.selection.filter { !$0.isFolder }.map(\.url)
            guard !urls.isEmpty else { return items }
            return items.map { wrap($0, urls: urls, window: ctx.window) }
        }
    }

    /// The same item, also posting `LocationEvents.didOpenFiles` (headless runs only log the launch).
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
