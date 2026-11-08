import AppKit
import ArborCore

/// Properties window (⌥↩ = Explorer's Alt+Enter, also ⌘I), the Windows 11 Details pane, and Finder
/// tags/comments editing. FE-099, FE-148, FE-150–FE-157, FE-160, FE-161, FE-245.
enum PropertiesFeature: ExplorerFeature {
    static let id = "properties"
    /// Posted with the folder URL after its "Optimize this folder for" changes (format: `FolderTemplateStore`).
    static let folderTemplateChanged = Notification.Name("ArborFolderTemplateChanged")

    static func register() {
        CommandRegistry.shared.register(ExplorerCommand(
            id: "file.properties", title: "Properties", symbol: "info.circle",
            tooltip: "Properties",
            shortcut: Shortcut("\r", [.option]),
            keyBindings: [KeyBinding(36, [.option], scope: .window), KeyBinding(76, [.option], scope: .window),
                          KeyBinding(34, [.command], scope: .window)],   // ⌥↩, ⌥Enter, ⌘I
            placements: [.itemContextMenu(.properties, 10), .backgroundContextMenu(.properties, 10),
                         .treeContextMenu(.properties, 10), .seeMore(.properties, 10), .mainMenu("File", .properties, 10)],
            isAvailable: { ctx in !targets(ctx).isEmpty || ctx.surface == .menuBar },
            isEnabled: { ctx in !targets(ctx).isEmpty },
            perform: { ctx in PropertiesWindowController.show(targets(ctx), relativeTo: ctx.window?.window) }))

        SidePaneRegistry.register(SidePaneDescriptor(id: "details", title: "Details pane") { DetailsSidePane() })
        registerScriptSteps()
    }

    /// The selection, else the right-clicked tree node, else the folder on screen.
    static func targets(_ ctx: CommandContext) -> [FileItem] {
        if !ctx.selection.isEmpty { return ctx.selection }
        if ctx.surface == .itemContextMenu { return [] }
        if ctx.surface == .treeContextMenu {
            return ctx.treeLocation?.folderURL.flatMap { FileItem(url: $0) }.map { [$0] } ?? []
        }
        guard let folder = ctx.location?.folderURL ?? ctx.targetFolder, let item = FileItem(url: folder) else { return [] }
        return [item]
    }

    /// After Properties renamed or changed items: refresh windows showing their folder.
    static func itemsChanged(old: URL, new: URL) {
        let folder = new.deletingLastPathComponent()
        for controller in (NSApp.delegate as? AppDelegate)?.controllers ?? [] {
            guard let shown = controller.location.folderURL, Location.folder(shown) == Location.folder(folder) else { continue }
            var urls = controller.selectedItems.map(\.url)
            if let i = urls.firstIndex(where: { $0.standardizedFileURL == old.standardizedFileURL }) { urls[i] = new }
            controller.refreshSelecting(urls: urls)
        }
    }

    // MARK: - Scripted checks (TESTING.md)

    private static func front() -> PropertiesWindowController? { PropertiesWindowController.front }

    private static func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func findButton(_ title: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let b = view as? SheetButton, b.title == title { return b }
        if let b = view as? NSButton, b.title == title { return b }
        if let c = view as? SheetCheckbox, c.title == title { return c }
        for sub in view.subviews { if let found = findButton(title, in: sub) { return found } }
        return nil
    }

    private static func registerScriptSteps() {
        // propertiesof:<path> — open Properties for any path ("/" = the startup drive).
        DebugScript.registerStep("propertiesof") { arg, window in
            let urls = arg.components(separatedBy: "|").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let items = urls.compactMap { FileItem(url: $0) }
            PropertiesWindowController.show(items, relativeTo: window?.window)
            return 1.2
        }
        // proptab:Security — select a tab of the front Properties window.
        DebugScript.registerStep("proptab") { arg, _ in
            if front()?.select(title: arg) != true { NSLog("DebugScript: no tab \(arg)") }
            return 0.8
        }
        // proplog:/path — the front Properties window's title, tabs and the selected tab's values.
        DebugScript.registerStep("proplog") { arg, _ in
            append((front()?.debugText ?? "no properties window") + "\n---\n", to: arg)
            return 0.3
        }
        // propsnapshot:/path.png — image of the front Properties window.
        DebugScript.registerStep("propsnapshot") { arg, _ in
            front()?.snapshot(to: arg)
            return 0.3
        }
        // propbutton:Advanced… — click a button or check box in the front Properties window or its sheet.
        DebugScript.registerStep("propbutton") { arg, _ in
            guard let window = front()?.window else { return 0.5 }
            let target = findButton(arg, in: window.attachedSheet?.contentView) ?? findButton(arg, in: window.contentView)
            switch target {
            case let b as SheetButton: b.performClick(nil)
            case let b as NSButton: b.performClick(nil)
            case let c as SheetCheckbox: c.toggle()
            default: NSLog("DebugScript: no button \(arg)")
            }
            return 0.8
        }
        // propsheetsnapshot:/path.png — image of the sheet attached to the front Properties window.
        DebugScript.registerStep("propsheetsnapshot") { arg, _ in
            guard let sheet = front()?.window?.attachedSheet, let view = sheet.contentView?.superview else { return 0.3 }
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
            return 0.3
        }
        // propset:name=New.txt | locked=1 | hidden=0 | mode=0640 | tags=A;B | comment=… | unblock=1 | template=Pictures:1
        DebugScript.registerStep("propset") { arg, _ in
            guard let controller = front() else { return 0.5 }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return 0.5 }
            let (key, value) = (parts[0], parts[1])
            let model = controller.model
            switch key {
            case "name": model.edit { e, _ in e.name = value }
            case "locked": model.edit { e, _ in e.locked = value == "1" }
            case "hidden": model.edit { e, _ in e.hidden = value == "1" }
            case "mode": if let m = UInt16(value, radix: 8) { model.edit { e, _ in e.mode = m } }
            case "tags":
                if let tab = controller.tabs.compactMap({ $0 as? DetailsTab }).first { tab.setTagsForScript(value) }
                else { model.edit { e, _ in e.tags = FinderMetadata.parseTags(value) } }
            case "comment":
                if let tab = controller.tabs.compactMap({ $0 as? DetailsTab }).first { tab.setCommentForScript(value) }
                else { model.edit { e, _ in e.comment = value } }
            case "unblock": model.edit { e, _ in e.quarantined = value != "1" }
            case "template":
                let bits = value.split(separator: ":").map(String.init)
                controller.tabs.compactMap { $0 as? CustomizeTab }.first?.selectTemplateForScript(bits[0], subfolders: bits.count > 1 && bits[1] == "1")
            default: NSLog("DebugScript: unknown property \(key)")
            }
            return 0.5
        }
        // propexternal:comment=Other — change the front window's item directly, as another app would.
        DebugScript.registerStep("propexternal") { arg, _ in
            guard let url = front()?.model.single?.url else { return 0.5 }
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return 0.5 }
            switch kv[0] {
            case "comment": try? FinderMetadata.setComment(kv[1], on: url)
            case "hidden": _ = try? FileFlags.update(url, hidden: kv[1] == "1")
            case "name": _ = try? Renamer.rename(url, to: kv[1])
            default: break
            }
            return 0.5
        }
        // propprincipal:2 — select a row of the Security tab's names list (0-based).
        DebugScript.registerStep("propprincipal") { arg, _ in
            front()?.tabs.compactMap { $0 as? SecurityTab }.first?.selectPrincipal(Int(arg) ?? 0)
            return 0.5
        }
        DebugScript.registerStep("propremovemeta") { _, _ in
            front()?.tabs.compactMap { $0 as? DetailsTab }.first?.removePropertiesForScript()
            return 0.8
        }
        DebugScript.registerStep("propapply") { _, _ in front()?.applyPressed(); return 1.0 }
        DebugScript.registerStep("propok") { _, _ in front()?.okPressed(); return 1.0 }
        DebugScript.registerStep("propcancel") { _, _ in front()?.close(); return 0.5 }
        // paneedit:tags=A;B|comment=Note|save — edit and save Finder tags/comments in the Details pane.
        DebugScript.registerStep("paneedit") { arg, window in
            guard let pane = window?.sidePane.provider as? DetailsSidePane else { return 0.5 }
            var tags: String?, comment: String?, save = false
            for part in arg.components(separatedBy: "|") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.first == "tags" { tags = kv.count > 1 ? kv[1] : "" }
                if kv.first == "comment" { comment = kv.count > 1 ? kv[1] : "" }
                if kv.first == "save" { save = true }
            }
            pane.scriptEdit(tags: tags, comment: comment, save: save)
            return 0.8
        }
        DebugScript.registerLogger("properties.log") { window in
            var lines: [String] = []
            if let pane = window.sidePane.provider as? DetailsSidePane { lines.append(pane.debugText) }
            lines.append("properties windows: \(PropertiesWindowController.all.count)")
            return lines.joined(separator: "\n")
        }
    }
}
