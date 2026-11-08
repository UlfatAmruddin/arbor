import AppKit
import Quartz
import ArborCore

/// Scripted checks for docs/features/consistency.md (TESTING.md). Log lines are added to `log:`.
enum ConsistencyDebug {
    static func register() {
        DebugScript.registerLogger("consistency.log") { window in
            guard !window.tabs.isEmpty else { return "consistency: no tabs" }
            let tab = window.activeTab
            let order = tab.sortOrder
            var lines = [
                "consistency: searchbox enabled=\(window.searchBox.field.isEnabled) placeholder=“\(window.searchBox.placeholder)”",
                "consistency: sort primary=\(order.primaryColumn.rawValue) ascending=\(order.ascending) foldersFirst=\(order.foldersFirst)",
                "consistency: recent=[\(HomeStore.recentLog.records.map { $0.reference.path.components(separatedBy: "/").last ?? "" }.joined(separator: ","))]",
                "consistency: " + MemberPreview.debugLine,
            ]
            if case .search(let r)? = tab.displayedLocation {
                lines.append("consistency: search scope=\(r.scope?.path ?? "-") extras=\(r.extraScopes.map(\.lastPathComponent).joined(separator: ",")) origin=\(r.originKey ?? "-") title=\(tab.title)")
            }
            if let page = tab.page as? LocationPageViewState {
                lines.append("consistency: page selection=[\(page.savedSelection.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: ","))] scroll=\(page.savedScroll ?? "-")")
            }
            if let gallery = tab.page as? GalleryPageController {
                lines.append("consistency: gallery shown=\(gallery.grid.itemCount) filter=“\(gallery.filterText)”")
            }
            if let network = tab.page as? NetworkTilesPage {
                lines.append("consistency: network tiles=[\(network.grid.allTiles.map(\.titleText).joined(separator: ","))]")
            }
            if let pane = window.sidePane.subviews.compactMap({ $0 as? MemberAwarePreviewPane }).first ?? findPane(window.sidePane) {
                lines.append("consistency: preview message=\(pane.messageText ?? "-")")
            }
            if let first = window.selectedItems.first {
                lines.append("consistency: quicklook url=\(PreviewHooks.url(for: first).path)")
            }
            let navTypes = window.navPane.outline.registeredDraggedTypes
            lines.append("consistency: nav pane accepts promises=\(navTypes.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) })")
            return lines.joined(separator: "\n")
        }

        // openwith:1 — chooses the Nth entry of Open With ▸ for the selection (headless: records only).
        DebugScript.registerStep("openwith") { arg, window in
            guard let window, let command = CommandRegistry.shared.command("file.openWith") else { return nil }
            let items = command.submenuItems(window.context(surface: .itemContextMenu, sender: nil))
            let index = max(0, (Int(arg) ?? 1) - 1)
            guard index < items.count, let action = items[index].action else { NSLog("DebugScript: no Open With entry \(arg)"); return 0.3 }
            NSApp.sendAction(action, to: items[index].target, from: items[index])
            return 0.6
        }

        // scopedrequest:/out — what the search box would search from the place shown (without running it).
        DebugScript.registerStep("scopedrequest") { arg, window in
            guard let window else { return nil }
            let shown = window.activeTab.displayedLocation ?? window.location
            let line: String
            if let r = ConsistentSearch.request(for: shown, window: window) {
                line = "scoped request from \(shown.key): scope=\(r.scope?.path ?? "-") extras=[\(r.extraScopes.map(\.path).joined(separator: ", "))] origin=\(r.originKey ?? "-")"
            } else {
                line = "scoped request from \(shown.key): default (searchable=\(ExplorerSearchController.isSearchable(shown)))"
            }
            append(line + "\n", to: arg)
            return 0.2
        }

        // pageclick:Name / pagehover:Name — a plain click or pointer rest on an item of a page (Home, This Mac, Gallery).
        DebugScript.registerStep("pageclick") { arg, window in
            if let window { ItemActionsEverywhere.scriptClick(window, name: arg) }
            return 1.0
        }
        DebugScript.registerStep("pagehover") { arg, window in
            if let window { ItemActionsEverywhere.scriptHover(window, name: arg) }
            return 0.8
        }
        DebugScript.registerLogger("consistency.log-2") { window in
            var line = "consistency: " + ItemActionsEverywhere.debugLine
            if let grid = window.itemView?.focusView as? ItemGridView {
                let underlined = grid.items.indices.filter { ItemViewHooks.underlinesName.first((grid, $0)) == true }.map { grid.items[$0].name }
                line += "\nconsistency: icon underlined=[\(underlined.joined(separator: ","))] click=\(Prefs.singleClickToOpen) underline=\(Prefs.underlineTitles) hover=\(ItemClickBehavior.shared.debugLine)"
            }
            return line
        }

        // renametab / renamebacktab — Tab or Shift-Tab in the inline rename field.
        for (name, selector) in [("renametab", #selector(NSResponder.insertTab(_:))), ("renamebacktab", #selector(NSResponder.insertBacktab(_:)))] {
            DebugScript.registerStep(name) { _, window in
                (window?.window?.firstResponder as? NSTextView)?.doCommand(by: selector)
                return 1.0
            }
        }

        // setpref:clickItems=single — sets a preference as the Folder Options dialog would (posts Prefs.changed).
        DebugScript.registerStep("setpref") { arg, _ in
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return 0.2 }
            let value: Any = parts[1] == "true" || parts[1] == "false" ? (parts[1] == "true") as Any : parts[1] as Any
            Prefs.store.set(value, forKey: parts[0])
            NotificationCenter.default.post(name: Prefs.changed, object: nil, userInfo: ["key": parts[0]])
            return 0.5
        }

        // homescroll:400 — scrolls the Home page.
        DebugScript.registerStep("homescroll") { arg, window in
            guard let page = window?.activeTab.page as? ExplorerHomePage, let scroll = page.scrollView else { return nil }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(Double(arg) ?? 0)))
            scroll.reflectScrolledClipView(scroll.contentView)
            return 0.3
        }

        // quicklook — toggles the Quick Look panel for the selection (the panel is hidden in headless runs).
        DebugScript.registerStep("quicklook") { _, window in
            window?.toggleQuickLook()
            if AppDelegate.isHeadless, QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.alphaValue = 0 }
            return 1.0
        }

        // opendoc:/path — opens a file as if double-clicked in Finder (application(_:open:)).
        DebugScript.registerStep("opendoc") { arg, _ in
            (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [URL(fileURLWithPath: arg)])
            return 1.5
        }
    }

    static func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func findPane(_ view: NSView) -> MemberAwarePreviewPane? {
        for sub in view.subviews {
            if let pane = sub as? MemberAwarePreviewPane { return pane }
            if let found = findPane(sub) { return found }
        }
        return nil
    }
}
