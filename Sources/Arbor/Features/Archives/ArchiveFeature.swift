import AppKit
import ArborCore
import UniformTypeIdentifiers

/// Archives and disk images (FE-163–FE-173): browse archives like folders, Extract All, Compress to,
/// Send to ▸ Compressed (zipped) folder, New ▸ Compressed (zipped) Folder, Mount. See docs/features/archives.md.
enum ArchiveFeature {
    /// For scripted checks: the last alert text, extraction folder and mounted volume.
    static var lastAlert: String?
    static var lastExtraction: URL?
    static var lastMount: URL?

    /// Alerts from archive jobs. Headless test runs record them instead (a sheet would appear on screen).
    static func alert(_ message: String, _ info: String = "", in window: NSWindow?) {
        lastAlert = message + (info.isEmpty ? "" : " " + info)
        guard !AppDelegate.isHeadless else { return }
        NSAlert.show(message, info, in: window)
    }

    static func register() {
        LocationRegistry.register(ArchiveProvider())
        registerOpening()
        registerCommands()
        adaptCoreCommands()
        registerColumns()
        registerBreadcrumbs()
        ItemHooks.registerDragWriter { item in
            guard let ref = ArchiveCatalog.ref(for: item.url) else { return nil }
            return ArchiveMemberPromise(ref: ref, isFolder: item.isFolder)
        }
        PromiseDrop.register()
        registerDebugSteps()
    }

    // MARK: - Context helpers

    static func inArchive(_ ctx: CommandContext) -> Bool { ctx.location?.archiveFile != nil }

    /// A browsable archive selected in a real folder.
    static func selectedArchive(_ ctx: CommandContext) -> URL? {
        guard ctx.location?.folderURL != nil, let item = ctx.single, !item.isFolder,
              ArchiveFormat.detect(item.url) != nil else { return nil }
        return item.url
    }

    /// What Extract All acts on: the selected archive, or the archive being browsed.
    static func extractTarget(_ ctx: CommandContext) -> URL? {
        if let file = selectedArchive(ctx) { return file }
        guard ctx.surface != .itemContextMenu else { return nil }
        return ctx.location?.archiveFile
    }

    static func canCompress(_ ctx: CommandContext) -> Bool {
        ctx.hasSelection && ctx.location?.folderURL != nil && ctx.allowsEditing
            && !ctx.selection.contains { Location.isVolumeRoot($0.url) }
    }

    // MARK: - Opening (folders inside archives, archives, members, ISO images)

    private static func registerOpening() {
        LocationRegistry.registerOpenHandler { item in
            if let ref = ArchiveCatalog.ref(for: item.url) {
                return item.isFolder ? .archive(ref.archive, innerPath: ref.innerPath) : nil
            }
            guard !item.isFolder, let format = ArchiveFormat.detect(item.url), format != .iso else { return nil }
            return .archive(item.url, innerPath: "")
        }
        // InteractionHooks.openFile is a single slot that a later feature (shortcuts) also sets, so the
        // archive handler chains in front of whatever is installed once registration has finished.
        DispatchQueue.main.async {
            let next = InteractionHooks.openFile
            InteractionHooks.openFile = { window, file in openFile(file, in: window) || next?(window, file) == true }
            if let sendTo = CommandRegistry.shared.command("file.sendTo") {
                let available = sendTo.isAvailable
                sendTo.isAvailable = { !inArchive($0) && available($0) }   // members aren't files on disk
            }
        }
    }

    /// Members open from a temporary copy; an ISO mounts on double-click like Explorer (browsed if it can't be).
    static func openFile(_ file: FileItem, in window: BrowserWindowController) -> Bool {
        if let ref = ArchiveCatalog.ref(for: file.url) {
            openMember(ref, in: window)
            return true
        }
        if file.url.pathExtension.lowercased() == "iso" {
            ArchiveJobs.mount(file.url, window: window, fallbackToBrowse: true)
            return true
        }
        return false
    }

    /// Opens a member from a read-only temporary copy, like Explorer. A nested archive opens as a folder.
    static func openMember(_ ref: ArchiveItemRef, in window: BrowserWindowController?, with app: URL? = nil) {
        guard let folder = try? ArchiveJobs.freshSessionFolder() else { return }
        let request = ArchiveJobs.ExtractRequest(archive: ref.archive, roots: [ref.innerPath], base: ref.parentPath,
                                                 destination: folder, verb: "Opening “\(ref.name)”")
        weak let weakWindow = window
        ArchiveJobs.extract(request, window: window?.window) { result in
            switch result {
            case .success(let outcome):
                guard let url = outcome.placed.first else { return }
                if app == nil, ArchiveFormat.detect(url) != nil {
                    weakWindow?.navigate(to: .archive(url, innerPath: ""))
                    return
                }
                makeReadOnly(url)
                if let app {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else if !AppDelegate.isHeadless {
                    NSWorkspace.shared.open(url)
                }
                lastExtraction = url
                weakWindow?.statusBar.setMessage("Opened a read-only copy of “\(ref.name)”. Changes won't be saved back to “\(ref.archive.lastPathComponent)”.")
            case .failure(let error):
                ArchiveJobs.show(error, title: "“\(ref.name)” couldn't be opened.", window: weakWindow?.window)
            }
        }
    }

    private static func makeReadOnly(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        chmod(url.path, info.st_mode & 0o555)
    }

    /// Copy inside an archive: extract the selection to a temporary folder and put those files on the
    /// clipboard, so Paste anywhere works (with the normal conflict rules).
    static func copyOut(_ ctx: CommandContext) {
        guard case .archive(let file, let inner)? = ctx.location, !ctx.selection.isEmpty,
              let folder = try? ArchiveJobs.freshSessionFolder() else { NSSound.beep(); return }
        let roots = ctx.selection.compactMap { ArchiveCatalog.ref(for: $0.url)?.innerPath }
        let request = ArchiveJobs.ExtractRequest(archive: file, roots: roots, base: inner, destination: folder,
                                                 verb: "Copying from “\(file.lastPathComponent)”")
        weak let window = ctx.window
        ArchiveJobs.extract(request, window: window?.window) { result in
            switch result {
            case .success(let outcome):
                FileClipboard.shared.write(outcome.placed, kind: .copy)
                window?.statusBar.setMessage("\(StatusText.items(outcome.placed.count)) copied.")
                ArchiveJobs.reportSkipped(outcome, window: window?.window)
            case .failure(let error):
                ArchiveJobs.show(error, title: "The items couldn't be copied.", window: window?.window)
            }
        }
    }

    // MARK: - Commands

    private static func registerCommands() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                // The static title is what the command bar shows first; menus get "Extract All…".
                id: "archive.extractAll", title: "Extract all", symbol: "archivebox", tooltip: "Extract all",
                placements: [.commandBarContextual(10), .itemContextMenu(.open, 45), .backgroundContextMenu(.open, 10),
                             .mainMenu("File", .archive, 10)],
                showsTitle: true,
                dynamicTitle: { $0.surface == .commandBar ? "Extract all" : "Extract All…" },
                isAvailable: { $0.surface == .menuBar || extractTarget($0) != nil },
                isEnabled: { extractTarget($0) != nil },
                perform: { ctx in
                    guard let file = extractTarget(ctx), let window = ctx.window else { return }
                    ExtractWizard.show(for: file, in: window)
                }),
            ExplorerCommand(
                id: "archive.compressTo", title: "Compress to", symbol: "doc.zipper",
                placements: [.itemContextMenu(.archive, 10), .mainMenu("File", .archive, 20)],
                isAvailable: { $0.surface == .menuBar || canCompress($0) },
                isEnabled: canCompress,
                submenu: { ctx in
                    guard canCompress(ctx) else { return [] }
                    return ArchiveCreateFormat.allCases.map { format in
                        ClosureMenuItem(format.menuTitle) { ArchiveJobs.compress(ctx.selection, format: format, window: ctx.window) }
                    }
                }),
            ExplorerCommand(
                id: "archive.newZip", title: "Compressed (zipped) Folder", symbol: "doc.zipper",
                placements: [.newMenu(.newFileTypes, 20), .mainMenu("File", .new, 40)],
                dynamicTitle: { $0.surface == .menuBar ? "New Compressed (zipped) Folder" : "Compressed (zipped) Folder" },
                isEnabled: { $0.targetFolder != nil && $0.allowsEditing },
                perform: { ctx in
                    guard let folder = ctx.targetFolder, let window = ctx.window else { return }
                    ArchiveJobs.newZip(in: folder, window: window)
                }),
            ExplorerCommand(
                id: "archive.mount", title: "Mount", symbol: "opticaldiscdrive",
                placements: [.itemContextMenu(.open, 46), .mainMenu("File", .archive, 30)],
                isAvailable: { ctx in ctx.surface == .menuBar || isMountable(ctx) },
                isEnabled: isMountable,
                perform: { ctx in
                    guard let url = ctx.single?.url else { return }
                    ArchiveJobs.mount(url, window: ctx.window, fallbackToBrowse: false)
                }),
        ])
        for format in ArchiveCreateFormat.allCases {
            // Script and keyboard entry points for each Compress to ▸ item.
            // archive.compress.zip is also what Send to ▸ Compressed (zipped) folder runs (ItemActions).
            r.register(ExplorerCommand(id: "archive.compress.\(format.fileExtension)", title: format.menuTitle,
                                       isAvailable: canCompress, isEnabled: canCompress,
                                       perform: { ArchiveJobs.compress($0.selection, format: format, window: $0.window) }))
        }
    }

    static func isMountable(_ ctx: CommandContext) -> Bool {
        guard ctx.location?.folderURL != nil, let item = ctx.single else { return false }
        return DiskImage.isDiskImage(item.url)
    }

    /// Core commands that must behave differently on archive members (whose URLs aren't on disk).
    private static func adaptCoreCommands() {
        let r = CommandRegistry.shared
        if let copy = r.command("edit.copy") {
            let enabled = copy.isEnabled, perform = copy.perform
            copy.isEnabled = { inArchive($0) ? $0.hasSelection : enabled($0) }
            copy.perform = { inArchive($0) ? copyOut($0) : perform($0) }
        }
        // No meaningful target inside an archive: hidden or disabled rather than acting on a path that doesn't exist.
        for id in ["file.share", "file.openInTerminal"] {
            guard let command = r.command(id) else { continue }
            let enabled = command.isEnabled
            command.isEnabled = { !inArchive($0) && enabled($0) }
        }
        for id in ["file.pin", "home.favorite"] {
            guard let command = r.command(id) else { continue }
            let available = command.isAvailable
            command.isAvailable = { !inArchive($0) && available($0) }
        }
        if let reveal = r.command("file.showInFinder") {
            let perform = reveal.perform
            reveal.perform = { ctx in
                if let file = ctx.location?.archiveFile { NSWorkspace.shared.activateFileViewerSelecting([file]) } else { perform(ctx) }
            }
        }
        if let openWith = r.command("file.openWith"), let submenu = openWith.submenu {
            openWith.submenu = { ctx in
                guard inArchive(ctx), let item = ctx.single, let ref = ArchiveCatalog.ref(for: item.url) else { return submenu(ctx) }
                let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
                return NSWorkspace.shared.urlsForApplications(toOpen: type).prefix(12).map { app in
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    return ClosureMenuItem(displayName(of: app).replacingOccurrences(of: ".app", with: ""), image: icon) {
                        openMember(ref, in: ctx.window, with: app)
                    }
                }
            }
        }
    }

    // MARK: - Details columns (Explorer's ZIP folder view)

    private static func registerColumns() {
        func entry(_ item: FileItem) -> ArchiveEntry? {
            guard !item.isFolder, let found = ArchiveCatalog.shared.entry(for: item) else { return nil }
            return found.node?.entry
        }
        func text(_ id: String, _ alignment: NSTextAlignment, _ value: @escaping (FileItem) -> String) -> (NSTableView, FileItem) -> NSView {
            { table, item in
                let cell = DetailsTextCell.make(table, id: id, alignment: alignment)
                cell.label.stringValue = value(item)
                return cell
            }
        }
        // Explorer's ZIP folder columns: Name, Type, Compressed size, Password protected, Size, Ratio, Date modified.
        let layout = DetailsLayout(
            id: "archive.zip",
            order: ["name", "type", "archive.compressedSize", "archive.passwordProtected", "size", "archive.ratio", "dateModified"],
            widths: ["name": 280, "type": 150],
            extras: [
                DetailsColumnSpec(id: "archive.compressedSize", title: "Compressed size", width: 120, alignment: .right,
                                  cell: text("archive.compressedSize", .right) { entry($0)?.compressedSize.map(StatusText.bytes) ?? "" }),
                DetailsColumnSpec(id: "archive.passwordProtected", title: "Password protected", width: 130,
                                  cell: text("archive.passwordProtected", .left) { entry($0).map { $0.isEncrypted ? "Yes" : "No" } ?? "" }),
                DetailsColumnSpec(id: "archive.ratio", title: "Ratio", width: 70, alignment: .right,
                                  cell: text("archive.ratio", .right) { item in
                                      guard let e = entry(item), let size = e.size, let packed = e.compressedSize else { return "" }
                                      guard size > 0 else { return "0%" }
                                      return "\(max(0, Int((100 - Double(packed) * 100 / Double(size)).rounded())))%"
                                  }),
            ])
        DetailsColumns.register { location in
            guard let file = location.archiveFile, ArchiveFormat.detect(file) == .zip else { return nil }
            return layout
        }
    }

    // MARK: - Breadcrumbs: "Downloads > Archive.zip > folder", chevrons list folders inside the archive

    private static func registerBreadcrumbs() {
        Breadcrumbs.register { location in
            guard case .archive(let file, let inner) = location else { return nil }
            var crumbs = Breadcrumbs.folderCrumbs(file.deletingLastPathComponent())
            func children(_ path: String) -> () -> [CrumbChild] {
                {
                    let nodes = ArchiveCatalog.shared.peek(file)?.index.children(of: path) ?? []
                    return nodes.filter(\.isDirectory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
                        CrumbChild(title: $0.name, location: .archive(file, innerPath: path.isEmpty ? $0.name : path + "/" + $0.name),
                                   icon: IconProvider.shared.folderIcon(size: 16))
                    }
                }
            }
            crumbs.append(Crumb(title: file.lastPathComponent, location: .archive(file, innerPath: ""), children: children("")))
            var path = ""
            for part in inner.split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                crumbs.append(Crumb(title: String(part), location: .archive(file, innerPath: path), children: children(path)))
            }
            return crumbs
        }
    }

    // MARK: - Script steps (TESTING.md)

    private static func registerDebugSteps() {
        // archivesheet:/out.png — render the Extract All sheet.
        DebugScript.registerStep("archivesheet") { path, window in
            guard let sheet = window?.window?.attachedSheet, let view = sheet.contentView else { return 0.5 }
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            return 0.5
        }
        // sheetpath:/dest — type a destination into the Extract All sheet.
        DebugScript.registerStep("sheetpath") { path, window in
            ExtractWizard.current(in: window?.window)?.pathField.stringValue = path
            return 0.3
        }
        // sheetshow:on|off — the "Show extracted files when complete" check box.
        DebugScript.registerStep("sheetshow") { value, window in
            ExtractWizard.current(in: window?.window)?.showFiles.state = value == "off" ? .off : .on
            return 0.3
        }
        // promise:<name>:/folder — what a drag of that member to a folder does (writes the promised file).
        DebugScript.registerStep("promise") { arg, window in
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let item = window?.visibleItems.first(where: { $0.name == parts[0] }),
                  let promise = ItemHooks.dragWriter(for: item) as? ArchiveMemberPromise else { return 0.5 }
            let target = URL(fileURLWithPath: parts[1]).appendingPathComponent(item.name)
            DispatchQueue.global().async {
                promise.filePromiseProvider(promise, writePromiseTo: target) { error in
                    DispatchQueue.main.async { lastAlert = error.map { "promise failed: \($0.localizedDescription)" } ?? lastAlert }
                }
            }
            return 1.5
        }
        // pastefrom:/folder — paste the clipboard into a folder (outside the current archive tab).
        DebugScript.registerStep("pasteinto") { path, window in
            let urls = FileClipboard.shared.readURLs()
            if !urls.isEmpty { window?.startTransfer(.copy, urls, to: URL(fileURLWithPath: path)) }
            return 1.0
        }
        DebugScript.registerLogger { window in
            var parts: [String] = []
            if let details = window.itemView as? DetailsViewController {
                let table = details.table
                parts.append("columns=" + table.tableColumns.filter { !$0.isHidden }.map(\.title).joined(separator: ","))
                if let first = window.visibleItems.first(where: { !$0.isFolder }) {
                    let values = ["archive.compressedSize", "archive.passwordProtected", "archive.ratio"].compactMap { id in
                        (DetailsColumns.cell(for: table, columnID: id, item: first) as? DetailsTextCell).map { "\(id.dropFirst(8))=\($0.label.stringValue)" }
                    }
                    if !values.isEmpty { parts.append("\(first.name): " + values.joined(separator: " ")) }
                }
            }
            parts.append("activities=\(OperationCenter.shared.activities.count)")
            if let lastAlert { parts.append("alert=\(lastAlert.replacingOccurrences(of: "\n", with: " / "))") }
            if let lastExtraction { parts.append("extracted=\(lastExtraction.path)") }
            if let lastMount { parts.append("mounted=\(lastMount.path)") }
            parts.append("clipboard=" + FileClipboard.shared.readURLs().map(\.lastPathComponent).joined(separator: ","))
            return "archive: " + parts.joined(separator: "  ")
        }
    }
}
