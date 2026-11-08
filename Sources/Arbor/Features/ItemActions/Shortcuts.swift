import AppKit
import ArborCore
import UniformTypeIdentifiers

/// Shortcuts are macOS aliases (FE-092, spec §14), which follow moved targets; symlinks are a separate action.
enum Shortcuts {
    enum Failure: LocalizedError {
        case cannotCreate(String, String)
        var errorDescription: String? {
            switch self { case .cannotCreate(let name, let why): return L10n.format("Couldn't create a shortcut to “%@”: %@", "\(name)", "\(why)") }
        }
    }

    // MARK: Creating

    /// Writes an alias to `target` in `folder` ("<target> - Shortcut" by default, made unique); never overwrites.
    @discardableResult
    static func createAlias(to target: URL, in folder: URL, name: String? = nil) throws -> URL {
        let finalName = name.map { n in ShortcutNaming.numbered(n) { FileOps.exists(folder.appendingPathComponent($0)) } }
            ?? ShortcutNaming.shortcutName(for: target.lastPathComponent) { FileOps.exists(folder.appendingPathComponent($0)) }
        let destination = folder.appendingPathComponent(finalName)
        do {
            let data = try target.bookmarkData(options: .suitableForBookmarkFile,
                                               includingResourceValuesForKeys: [.isDirectoryKey, .contentTypeKey], relativeTo: nil)
            guard !FileOps.exists(destination) else { throw CocoaError(.fileWriteFileExists) }
            try URL.writeBookmarkData(data, to: destination)
        } catch {
            throw Failure.cannotCreate(target.lastPathComponent, error.localizedDescription)
        }
        return destination
    }

    /// A .webloc for a web address from the Create Shortcut wizard.
    static func createWebLocation(_ url: URL, in folder: URL, name: String) throws -> URL {
        let finalName = ShortcutNaming.numbered(name + ".webloc") { FileOps.exists(folder.appendingPathComponent($0)) }
        let destination = folder.appendingPathComponent(finalName)
        try WebLocation.data(for: url).write(to: destination, options: .withoutOverwriting)
        return destination
    }

    /// A symbolic link (absolute path). Unlike an alias it breaks when the target moves.
    static func createSymbolicLink(to target: URL, in folder: URL) throws -> URL {
        let name = ShortcutNaming.symbolicLinkName(for: target.lastPathComponent) { FileOps.exists(folder.appendingPathComponent($0)) }
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        return destination
    }

    /// Creates shortcuts with one undo; returns the created URLs and reports failures once.
    @discardableResult
    static func createShortcuts(to targets: [URL], in folder: URL, window: BrowserWindowController?) -> [URL] {
        var created: [URL] = []
        var problems: [String] = []
        for target in targets {
            do { created.append(try createAlias(to: target, in: folder)) } catch { problems.append(error.localizedDescription) }
        }
        if !created.isEmpty { registerUndoCreate(created, name: "Create Shortcut") }
        if !problems.isEmpty { NSAlert.show(L10n.tr("Some shortcuts couldn't be created."), problems.joined(separator: "\n"), in: window?.window) }
        return created
    }

    /// Undo moves created shortcuts to the Trash (never deletes); redo puts them back.
    static func registerUndoCreate(_ urls: [URL], name: String) {
        let center = OperationCenter.shared
        center.undoManager.registerUndo(withTarget: center) { center in
            var pairs: [(original: URL, trashed: URL)] = []
            for url in urls where FileOps.exists(url) {
                if let trashed = try? SystemTrash.trash(url) { pairs.append((url, trashed)) }
            }
            center.registerUndoTrash(pairs, actionName: name)
        }
        center.undoManager.setActionName(name)
    }

    // MARK: Recognizing and resolving

    static func isAlias(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
            && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    enum Resolution {
        case target(URL, isFolder: Bool)
        case web(URL)
        /// The target is gone. `lastKnownName` comes from the alias data, if it was recorded.
        case broken(lastKnownName: String?)
    }

    /// Resolves an alias or .webloc without showing UI or mounting volumes.
    static func resolve(_ url: URL) -> Resolution? {
        if url.pathExtension.lowercased() == "webloc" {
            return (try? Data(contentsOf: url)).flatMap(WebLocation.url(from:)).map { .web($0) }
        }
        guard isAlias(url) else { return nil }
        do {
            let target = try URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
            guard FileManager.default.fileExists(atPath: target.path) else { return .broken(lastKnownName: target.lastPathComponent) }
            return .target(target, isFolder: FileOps.isPlainFolder(target) || isFolderLike(target))
        } catch {
            return .broken(lastKnownName: lastKnownTargetName(url))
        }
    }

    private static func isFolderLike(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }

    /// The target's name as recorded inside the alias, without resolving it.
    static func lastKnownTargetName(_ alias: URL) -> String? {
        guard let data = try? URL.bookmarkData(withContentsOf: alias),
              let values = URL.resourceValues(forKeys: [.pathKey, .nameKey], fromBookmarkData: data) else { return nil }
        return values.name ?? values.path.map { ($0 as NSString).lastPathComponent }
    }

    /// Whether the alias recorded a folder target (reads only the alias).
    static func recordedTargetIsFolder(_ alias: URL) -> Bool? {
        guard let data = try? URL.bookmarkData(withContentsOf: alias),
              let values = URL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey], fromBookmarkData: data) else { return nil }
        guard let dir = values.isDirectory else { return nil }
        return dir && !(values.isPackage ?? false)
    }

    // MARK: Opening (hooks)

    /// Opening a folder shortcut navigates to the target folder, like Explorer.
    static func locationForOpening(_ item: FileItem) -> Location? {
        guard !item.isFolder, isAlias(item.url), case .target(let target, true)? = resolve(item.url) else { return nil }
        return .folder(target)
    }

    /// Opening a file shortcut opens its target, which Home ▸ Recent then lists (as Explorer does);
    /// a broken one shows "Problem with Shortcut".
    static func openFile(_ window: BrowserWindowController, _ item: FileItem) -> Bool {
        guard isAlias(item.url) else { return false }
        switch resolve(item.url) {
        case .target(let target, _)?:
            SystemOpen.open(target)
            NotificationCenter.default.post(name: LocationEvents.didOpenFiles, object: window, userInfo: ["urls": [target]])
            return true
        case .broken(let name)?:
            showProblem(alias: item, targetName: name, window: window)
            return true
        default:
            return false
        }
    }

    /// Explorer's "Problem with Shortcut", offering to delete it (to the Trash, undoable).
    static func showProblem(alias: FileItem, targetName: String?, window: BrowserWindowController) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Problem with Shortcut")
        let what = targetName.map { "The item “\($0)”" } ?? "The item"
        alert.informativeText = L10n.format("%@ that this shortcut refers to has been changed or moved, so this shortcut will no longer work properly.\n\nDo you want to delete this shortcut?", "\(what)")
        alert.addButton(withTitle: L10n.tr("Yes"))
        alert.addButton(withTitle: L10n.tr("No"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak window] response in
            guard response == .alertFirstButtonReturn, let window else { return }
            do {
                let trashed = try SystemTrash.trash(alias.url)
                OperationCenter.shared.registerUndoTrash([(alias.url, trashed)])
                window.statusBar.setMessage(L10n.tr("Shortcut moved to the Trash. Press ⌘Z to undo."))
                window.refreshSelecting([])
            } catch {
                NSAlert.show(L10n.format("Couldn't delete “%@”.", "\(alias.name)"), error.localizedDescription, in: window.window)
            }
        }
        AlertSheets.present(alert, in: window.window, completion: finish)
    }

    // MARK: Icon overlay

    /// Curved-arrow badge at the bottom-left of shortcut and symlink icons; original artwork (DEC-018).
    static func decorate(_ item: FileItem, _ icon: NSImage, size: CGFloat) -> NSImage? {
        let linkish = item.isSymbolicLink || (!item.isFolder && isAlias(item.url))
        guard linkish else { return nil }
        let base: NSImage
        if !item.isFolder, isAlias(item.url) {
            // Show the target's icon (folder art or type icon) rather than a blank page.
            if recordedTargetIsFolder(item.url) == true {
                base = IconProvider.shared.folderIcon(size: size)
            } else if let type = targetContentType(item.url) {
                let typed = NSWorkspace.shared.icon(for: type)
                typed.size = NSSize(width: size, height: size)
                base = typed
            } else {
                base = icon
            }
        } else {
            base = icon
        }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            // Half the icon at list sizes; a smaller corner badge on large icons, as in Explorer.
            let side = size <= 24 ? max(7, size * 0.5) : min(64, max(12, round(size * 0.3)))
            drawArrowBadge(in: NSRect(x: 0, y: 0, width: side, height: side))
            return true
        }
    }

    private static func targetContentType(_ alias: URL) -> UTType? {
        guard let data = try? URL.bookmarkData(withContentsOf: alias),
              let values = URL.resourceValues(forKeys: [.contentTypeKey, .pathKey], fromBookmarkData: data) else { return nil }
        if let type = values.contentType { return type }
        return values.path.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
    }

    static func drawArrowBadge(in r: NSRect) {
        let box = NSBezierPath(roundedRect: r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04), xRadius: r.width * 0.16, yRadius: r.width * 0.16)
        NSColor.white.setFill()
        box.fill()
        NSColor(white: 0.55, alpha: 1).setStroke()
        box.lineWidth = max(0.5, r.width / 16)
        box.stroke()
        // Arrow: a curve rising from the bottom-left to an arrowhead at the top-right.
        let u = r.width / 10
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: r.minX + 2.6 * u, y: r.minY + 2.2 * u))
        arrow.curve(to: NSPoint(x: r.minX + 6.2 * u, y: r.minY + 6.0 * u),
                    controlPoint1: NSPoint(x: r.minX + 2.6 * u, y: r.minY + 4.8 * u),
                    controlPoint2: NSPoint(x: r.minX + 4.2 * u, y: r.minY + 6.0 * u))
        arrow.lineWidth = max(1, 1.5 * u)
        arrow.lineCapStyle = .round
        let blue = NSColor(srgbRed: 0.10, green: 0.42, blue: 0.85, alpha: 1)
        blue.setStroke()
        arrow.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: r.minX + 7.8 * u, y: r.minY + 6.0 * u))
        head.line(to: NSPoint(x: r.minX + 5.4 * u, y: r.minY + 8.2 * u))
        head.line(to: NSPoint(x: r.minX + 5.4 * u, y: r.minY + 3.8 * u))
        head.close()
        blue.setFill()
        head.fill()
    }
}

