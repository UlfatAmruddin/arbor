import AppKit
import ArborCore

/// Script steps and log lines for Gallery and Libraries (TESTING.md):
///
///     gallerysources:/a|/b        replace the collection (headless prefs only)
///     gallerytoggle:/a            check/uncheck a folder in Collection ▾
///     galleryselect:a.jpg|b.png   select tiles by file name
///     galleryyear:2024            jump with the date rail
///     gallerysize:smallIcons      View ▾ size (same as click:view.mode.smallIcons)
///     galleryhover:x,y            hover the grid at a document point (shows the check box)
///     managecollection            open "Gallery Locations"
///     managelibrary:Documents     open "Documents Library Locations"
///     dialog:add:/p | dialog:remove:/p | dialog:save:/p | dialog:moveup:/p | dialog:movedown:/p
///     dialog:optimize:music | dialog:restore | dialog:ok | dialog:cancel
///     showlibraries:1|0           navigation pane "Show libraries"
///     librarydef:Name=/a|/b       create a library if needed and set its folders (first = save location)
///     libraryselect:Name          select a tile on the Libraries page
///     librarytree:cmd:Name        run a tile/tree-menu command on a library, e.g. librarytree:library.delete:Name
///     librarymenu:Name:/path      append a tile's context menu
///     resetfolders                what Folder Options' Reset Folders does, without its prompt
///     sheettext:New name          type into the text field of the window's sheet (Rename in Gallery)
///     collectionmenu:/path        append the Collection ▾ menu
extension GalleryLibrariesFeature {
    static func registerDebugSteps() {
        DebugScript.registerStep("gallerysources") { arg, _ in
            GalleryPrefs.collection = GalleryCollection(sources: arg.split(separator: "|").map { GallerySource(URL(fileURLWithPath: String($0))) })
            return 1
        }
        DebugScript.registerStep("gallerytoggle") { arg, _ in
            var collection = GalleryPrefs.collection
            let url = URL(fileURLWithPath: arg)
            let included = collection.sources.first { $0.path == Location.normalizedKey(url) }?.included ?? true
            collection.setIncluded(url, !included)
            GalleryPrefs.collection = collection
            return 0.8
        }
        DebugScript.registerStep("galleryselect") { arg, window in
            let page = window?.activeTab.page as? GalleryPageController
            page?.select(names: arg.isEmpty ? [] : arg.components(separatedBy: "|"))
            page?.grid.window?.makeFirstResponder(page?.grid)
            return 0.5
        }
        DebugScript.registerStep("gallerykey") { arg, window in
            // gallerykey:124 or gallerykey:124:shift — a key press in the grid (virtual key code).
            let parts = arg.split(separator: ":")
            guard let code = parts.first.flatMap({ UInt16($0) }),
                  let grid = (window?.activeTab.page as? GalleryPageController)?.grid, let win = grid.window else { return 0.3 }
            let flags: NSEvent.ModifierFlags = parts.contains("shift") ? [.shift] : []
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                            windowNumber: win.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                            isARepeat: false, keyCode: code) {
                grid.keyDown(with: event)
            }
            return 0.4
        }
        DebugScript.registerStep("galleryyear") { arg, window in
            if let year = Int(arg), (window?.activeTab.page as? GalleryPageController)?.rail.jump(toYear: year) != true {
                NSLog("DebugScript: no year \(arg) in Gallery")
            }
            return 0.8
        }
        DebugScript.registerStep("gallerysize") { arg, _ in
            if let mode = ViewMode(rawValue: arg) { GalleryPrefs.size = mode }
            return 0.8
        }
        DebugScript.registerStep("galleryhover") { arg, window in
            let xy = arg.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let grid = (window?.activeTab.page as? GalleryPageController)?.grid, let win = grid.window else { return 0.3 }
            let point = grid.convert(NSPoint(x: xy[0], y: xy[1]), to: nil)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                grid.mouseMoved(with: event)
            }
            return 0.4
        }
        DebugScript.registerStep("managecollection") { _, window in
            LocationsDialog(mode: .gallery).present(in: window?.window)
            return 0.8
        }
        DebugScript.registerStep("managelibrary") { arg, window in
            LocationsDialog(mode: .library(arg)).present(in: window?.window)
            return 0.8
        }
        DebugScript.registerStep("dialog") { arg, _ in
            guard let dialog = LocationsDialog.current else { NSLog("DebugScript: no locations dialog"); return 0.3 }
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let path = parts.count > 1 ? URL(fileURLWithPath: parts[1]) : nil
            switch parts.first {
            case "add": if let path { dialog.add(path) }
            case "remove": if let path { dialog.remove(path) }
            case "save": if let path { dialog.setSave(path) }
            case "moveup": if let path { dialog.move(path, by: -1) }
            case "movedown": if let path { dialog.move(path, by: 1) }
            case "optimize":
                let wanted = parts.count > 1 ? parts[1] : ""
                if let value = FolderTemplate.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(wanted.lowercased()) }) { dialog.setTemplate(value) }
            case "restore": dialog.restore()
            case "ok": dialog.confirm(nil)
            case "cancel": dialog.dismiss(nil)
            default: NSLog("DebugScript: bad dialog step \(arg)")
            }
            return 0.8
        }
        DebugScript.registerStep("showlibraries") { arg, _ in
            Prefs.showLibraries = arg != "0"
            return 0.8
        }
        DebugScript.registerStep("librarydef") { arg, _ in
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first else { return 0.3 }
            let folders = parts.count > 1 ? parts[1].split(separator: "|").map { URL(fileURLWithPath: String($0)) } : []
            if LibraryStore.definition(name) == nil { try? LibraryStore.edit { try $0.create(named: name) } }
            guard let library = LibraryStore.definition(name) else { NSLog("DebugScript: can't create that library"); return 0.3 }
            try? LibraryActions.commit(LibraryDefinition(name: name, folders: folders, template: library.template))
            return 0.8
        }
        DebugScript.registerStep("resetfolders") { _, _ in
            FolderViews.shared.resetFolders()
            return 0.8
        }
        DebugScript.registerStep("libraryselect") { arg, window in
            guard let page = window?.activeTab.page as? LibrariesPageController else { NSLog("DebugScript: not on the Libraries page"); return 0.3 }
            page.select(names: arg.isEmpty ? [] : arg.components(separatedBy: "|"))
            page.view.window?.makeFirstResponder(page.grid)
            return 0.4
        }
        DebugScript.registerStep("librarytree") { arg, window in
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let window else { return 0.3 }
            var ctx = window.context(surface: .treeContextMenu, sender: nil)
            ctx.selection = []
            ctx.targetFolder = nil
            ctx.treeLocation = .library(parts[1])
            if !CommandRegistry.shared.perform(parts[0], context: ctx) { NSLog("DebugScript: library command unavailable") }
            return 0.8
        }
        DebugScript.registerStep("librarymenu") { arg, window in
            guard let colon = arg.range(of: ":", options: .backwards),
                  let page = window?.activeTab.page as? LibrariesPageController,
                  let menu = page.tileMenu(for: String(arg[..<colon.lowerBound])) else { return 0.3 }
            menu.update()
            let lines = menu.items.map { $0.isSeparatorItem ? "---" : $0.title + ($0.isEnabled ? "" : " (disabled)") }
            appendLine("tile menu:\n" + lines.joined(separator: "\n") + "\n---\n", to: String(arg[colon.upperBound...]))
            return 0.3
        }
        DebugScript.registerStep("sheettext") { arg, window in
            let sheet = window?.window?.attachedSheet
            if let field = findField(in: sheet?.contentView) {
                field.stringValue = arg
                sheet?.makeFirstResponder(field)
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            return 0.5
        }
        DebugScript.registerStep("collectionmenu") { path, window in
            let lines = collectionMenuItems().map { item -> String in
                item.isSeparatorItem ? "---" : item.title + (item.state == .on ? " ✓" : "")
            }
            appendLine("collection menu:\n" + lines.joined(separator: "\n") + "\n---\n", to: path)
            return 0.3
        }

        DebugScript.registerLogger("gallery-libraries.log") { window in
            var lines: [String] = []
            if let page = window.activeTab.page as? GalleryPageController {
                let store = GalleryStore.shared
                let months = page.grid.sections.map { "\($0.title) (\($0.items.count))" }.joined(separator: ", ")
                lines.append("gallery: items=\(page.grid.itemCount) scanning=\(store.isScanning) size=\(GalleryPrefs.size.rawValue) newestFirst=\(GalleryPrefs.newestFirst)")
                lines.append("gallery months: \(months)")
                lines.append("gallery order: \(page.grid.allItems.map(\.url.lastPathComponent).joined(separator: " "))")
                lines.append("gallery selected: \(page.grid.selectedItems.map(\.url.lastPathComponent).joined(separator: " "))")
                lines.append("gallery " + page.rail.debugSummary)
                lines.append("gallery unavailable: \(store.unavailable.map(\.path).joined(separator: ", "))")
            }
            lines.append("gallery sources: " + GalleryPrefs.collection.sources.map { $0.path + ($0.included ? "" : " (off)") }.joined(separator: " | "))
            lines.append("libraries: show=\(Prefs.showLibraries) " + LibraryStore.all.map { lib in
                "\(lib.name)=[" + lib.folders.map { ($0 == lib.saveLocation ? "*" : "") + $0 }.joined(separator: ", ") + "]"
            }.joined(separator: " "))
            lines.append("library types: " + LibraryStore.all.map { "\($0.name)=\($0.template.rawValue)" }.joined(separator: " "))
            if let page = window.activeTab.page as? LibrariesPageController {
                lines.append("library tiles: \(page.shown.map(\.name).joined(separator: " | "))  selected: \(page.selectedNames.joined(separator: " | "))")
            }
            if let name = libraryName(window.activeTab.displayedLocation) {
                let target = LibraryProvider().targetFolder(for: .library(name))
                lines.append("library target: \(target?.path ?? "none")")
                let view = (window.itemView as? DetailsViewController)?.folder ?? (window.itemView as? IconViewController)?.folder
                lines.append("library drop target: \(view?.path ?? "none")")
                let folders = window.visibleItems.map { "\($0.name)@\(LibraryMerge.folderColumnText(for: $0.url))" }
                lines.append("library rows: \(folders.joined(separator: " | "))")
            }
            if let details = window.itemView as? DetailsViewController {
                lines.append("details columns: \(details.table.tableColumns.map(\.title).joined(separator: ", "))")
            }
            if let dialog = LocationsDialog.current { lines.append(dialog.debugSummary) }
            if let sheet = window.window?.attachedSheet {
                lines.append("sheet text: " + texts(in: sheet.contentView).joined(separator: " / "))
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var result: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { result.append(field.stringValue) }
        if let button = view as? NSButton, !button.title.isEmpty { result.append("[\(button.title)]") }
        for sub in view.subviews { result += texts(in: sub) }
        return result
    }

    private static func findField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = findField(in: sub) { return found } }
        return nil
    }

    private static func appendLine(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
