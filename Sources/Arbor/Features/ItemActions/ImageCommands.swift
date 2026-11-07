import AppKit
import ArborCore

/// Image actions (FE-097): Set as desktop background, Rotate right, Rotate left — in the contextual
/// command bar and the item context menu, only when every selected item supports them.
/// Print is omitted: macOS has no public "print this file with its default app" API, and a button
/// that only opens the file would be a fake feature (DEC-019).
enum ImageCommands {
    static func register() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "image.setBackground", title: "Set as background", symbol: "photo.on.rectangle",
                placements: [.commandBarContextual(5), .itemContextMenu(.imageActions, 10)],
                showsTitle: true,
                dynamicTitle: { $0.surface == .commandBar ? "Set as background" : "Set as desktop background" },
                isAvailable: { ctx in ctx.single.map { !$0.isFolder && ImageRotator.isImage($0.url) } ?? false },
                perform: setBackground),
            ExplorerCommand(
                id: "image.rotateLeft", title: "Rotate left", symbol: "rotate.left",
                placements: [.commandBarContextual(10), .itemContextMenu(.imageActions, 30)],
                showsTitle: true,
                isAvailable: rotatable,
                isEnabled: { $0.allowsEditing },
                perform: { rotate($0, clockwise: false) }),
            ExplorerCommand(
                id: "image.rotateRight", title: "Rotate right", symbol: "rotate.right",
                placements: [.commandBarContextual(20), .itemContextMenu(.imageActions, 20)],
                showsTitle: true,
                isAvailable: rotatable,
                isEnabled: { $0.allowsEditing },
                perform: { rotate($0, clockwise: true) }),
        ])
    }

    static func rotatable(_ ctx: CommandContext) -> Bool {
        ctx.hasSelection && ctx.selection.allSatisfy { !$0.isFolder && ImageRotator.canRotate($0.url) }
    }

    static func rotate(_ ctx: CommandContext, clockwise: Bool) {
        let urls = ctx.selection.map(\.url)
        guard !urls.isEmpty, let window = ctx.window else { return }
        let names = ctx.selection.map(\.name)
        window.statusBar.setMessage("Rotating \(StatusText.items(urls.count))…")
        DispatchQueue.global(qos: .userInitiated).async {
            var done: [URL] = []
            var problems: [String] = []
            for url in urls {
                do { try ImageRotator.rotate(url, clockwise: clockwise); done.append(url) } catch {
                    problems.append("• \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [weak window] in
                if !done.isEmpty { registerUndo(done, clockwise: clockwise) }
                IconProvider.shared.purgeFileIcons()
                guard let window else { return }
                window.refreshSelecting(names)
                window.statusBar.setMessage(done.isEmpty ? nil : "Rotated \(StatusText.items(done.count)) \(clockwise ? "right" : "left"). Press ⌘Z to undo.")
                if !problems.isEmpty {
                    NSAlert.show(problems.count == 1 ? "1 image couldn't be rotated." : "\(problems.count) images couldn't be rotated.",
                                 problems.joined(separator: "\n"), in: window.window)
                }
            }
        }
    }

    /// Undo turns the images back the other way (exact for both lossless methods).
    static func registerUndo(_ urls: [URL], clockwise: Bool) {
        let center = OperationCenter.shared
        center.undoManager.registerUndo(withTarget: center) { _ in
            var back: [URL] = []
            for url in urls where FileOps.exists(url) {
                if (try? ImageRotator.rotate(url, clockwise: !clockwise)) != nil { back.append(url) }
            }
            IconProvider.shared.purgeFileIcons()
            if !back.isEmpty { registerUndo(back, clockwise: !clockwise) }
            if back.count != urls.count {
                NSAlert.show("Some images couldn't be turned back.", "They were moved, changed or removed.", in: NSApp.keyWindow)
            }
        }
        center.undoManager.setActionName(clockwise ? "Rotate Right" : "Rotate Left")
    }

    /// Sets the picture for every screen's current desktop (Explorer sets it for all monitors).
    /// Headless test runs never change the real wallpaper; they report what would happen.
    static func setBackground(_ ctx: CommandContext) {
        guard let item = ctx.single, let window = ctx.window else { return }
        if AppDelegate.isHeadless {
            window.statusBar.setMessage("Desktop background: “\(item.name)” (not applied in test runs).")
            return
        }
        var failure: Error?
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(item.url, for: screen, options: [:]) } catch { failure = error }
        }
        if let failure {
            NSAlert.show("Couldn't set “\(item.name)” as the desktop background.", failure.localizedDescription, in: window.window)
        } else {
            window.statusBar.setMessage("“\(item.name)” is now the desktop background.")
        }
    }
}
