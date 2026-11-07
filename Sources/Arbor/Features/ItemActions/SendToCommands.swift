import AppKit
import ArborCore

/// Send to ▸ (FE-096), translated to Mac destinations:
/// Compressed (zipped) folder (the archives feature's command, when installed) · Desktop (create
/// shortcut) · Documents (copy) · Mail recipient (Mail's compose sheet via the system share service)
/// · removable and external drives (copy). Bluetooth and Fax have no Mac counterpart and are omitted.
enum SendToCommands {
    static let zipCommandID = "archive.compress.zip"

    static func register() {
        CommandRegistry.shared.register(ExplorerCommand(
            id: "file.sendTo", title: "Send to", symbol: "paperplane",
            placements: [.itemContextMenu(.sendTo, 10)],
            isAvailable: { $0.hasSelection && $0.selection.allSatisfy { !Location.isVolumeRoot($0.url) } },
            submenu: { ctx in items(ctx) }))
    }

    /// Desktop and Documents. Headless test runs use `ARBOR_TEST_SENDTO_ROOT` instead and never touch
    /// the real folders (without it these destinations are hidden in headless runs).
    static func specialFolder(_ name: String, _ directory: FileManager.SearchPathDirectory) -> URL? {
        if AppDelegate.isHeadless {
            guard let root = ProcessInfo.processInfo.environment["ARBOR_TEST_SENDTO_ROOT"] else { return nil }
            return URL(fileURLWithPath: root).appendingPathComponent(name)
        }
        return FileManager.default.urls(for: directory, in: .userDomainMask).first
    }

    /// External, removable and ejectable volumes (not the startup disk or network shares).
    static func drives() -> [(name: String, url: URL)] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
        if AppDelegate.isHeadless, let fake = ProcessInfo.processInfo.environment["ARBOR_TEST_SENDTO_DRIVE"] {
            let url = URL(fileURLWithPath: fake)
            return [(url.lastPathComponent, url)]
        }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard url.path != "/", let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal != false, v.volumeIsReadOnly != true,
                  v.volumeIsRemovable == true || v.volumeIsEjectable == true || v.volumeIsInternal == false else { return nil }
            return (v.volumeLocalizedName ?? displayName(of: url), url)
        }
    }

    static func items(_ ctx: CommandContext) -> [NSMenuItem] {
        let urls = ctx.selection.map(\.url)
        let window = ctx.window
        var menu: [NSMenuItem] = []
        func icon(_ image: NSImage) -> NSImage {
            image.size = NSSize(width: 16, height: 16)
            return image
        }

        if let zip = CommandRegistry.shared.command(zipCommandID), zip.isAvailable(ctx) {
            let item = ClosureMenuItem("Compressed (zipped) folder", image: icon(IconProvider.shared.icon(for: .archive(URL(fileURLWithPath: "/"), innerPath: ""), size: 16))) {
                CommandRegistry.shared.perform(zipCommandID, context: ctx)
            }
            item.isEnabled = zip.isEnabled(ctx)
            menu.append(item)
        }
        if let desktop = specialFolder("Desktop", .desktopDirectory) {
            menu.append(ClosureMenuItem("Desktop (create shortcut)", image: icon(IconProvider.shared.folderIcon(.desktop, size: 16))) {
                let created = Shortcuts.createShortcuts(to: urls, in: desktop, window: window)
                if !created.isEmpty {
                    window?.statusBar.setMessage(created.count == 1 ? "Created “\(created[0].lastPathComponent)” on the Desktop."
                                                                   : "Created \(created.count) shortcuts on the Desktop.")
                }
            })
        }
        if let documents = specialFolder("Documents", .documentDirectory) {
            menu.append(ClosureMenuItem("Documents", image: icon(IconProvider.shared.folderIcon(.documents, size: 16))) {
                window?.startTransfer(.copy, DragSources.deduplicated(urls), to: documents)
            })
        }
        if !ctx.selection.contains(where: \.isFolder), let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: urls) {
            menu.append(ClosureMenuItem("Mail recipient", image: icon(mail.image)) {
                if AppDelegate.isHeadless {
                    window?.statusBar.setMessage("Mail recipient: \(urls.count) attachment(s) (not sent in test runs).")
                } else {
                    mail.perform(withItems: urls)
                }
            })
        }
        let drives = drives()
        if !drives.isEmpty { menu.append(.separator()) }
        for drive in drives {
            menu.append(ClosureMenuItem(drive.name, image: icon(IconProvider.shared.driveIcon(for: drive.url, size: 16))) {
                window?.startTransfer(.copy, DragSources.deduplicated(urls), to: drive.url)
            })
        }
        if menu.isEmpty {
            let none = NSMenuItem(title: "No destinations available", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.append(none)
        }
        return menu
    }
}
