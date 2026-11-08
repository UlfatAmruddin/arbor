import AppKit
import ArborCore

/// Image actions (FE-097), shown only when every selected item supports them. No Print: macOS has
/// no public print-with-default-app API, and a button that only opens the file would be fake (DEC-019).
enum ImageCommands {
    static func register() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "image.setBackground", title: "Set as background", symbol: "photo.on.rectangle",
                placements: [.commandBarContextual(5), .itemContextMenu(.imageActions, 10)],
                showsTitle: true,
                dynamicTitle: { $0.surface == .commandBar ? L10n.tr("Set as background") : L10n.tr("Set as desktop background") },
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
        window.statusBar.setMessage(L10n.format("Rotating %@…", "\(StatusText.items(urls.count))"))
        DispatchQueue.global(qos: .userInitiated).async {
            var done: [URL] = []
            var problems: [String] = []
            for url in urls {
                do { try ImageRotator.rotate(url, clockwise: clockwise); done.append(url) } catch {
                    problems.append("• \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [weak window] in
                if !done.isEmpty { registerUndo(done, clockwise: clockwise, actionName: clockwise ? L10n.tr("Rotate Right") : L10n.tr("Rotate Left")) }
                IconProvider.shared.purgeFileIcons()
                guard let window else { return }
                window.refreshSelecting(urls: urls)
                window.statusBar.setMessage(done.isEmpty ? nil : "Rotated \(StatusText.items(done.count)) \(clockwise ? "right" : "left"). Press ⌘Z to undo.")
                if !problems.isEmpty {
                    NSAlert.show(problems.count == 1 ? "1 image couldn't be rotated." : "\(problems.count) images couldn't be rotated.",
                                 problems.joined(separator: "\n"), in: window.window)
                }
            }
        }
    }

    /// Undo turns the images back (exact for both lossless methods); redo turns them again.
    /// `clockwise` is the turn this step undoes; `actionName` is the original action's name.
    static func registerUndo(_ urls: [URL], clockwise: Bool, actionName: String) {
        let center = OperationCenter.shared
        center.undoManager.registerUndo(withTarget: center) { _ in
            var back: [URL] = []
            for url in urls where FileOps.exists(url) {
                if (try? ImageRotator.rotate(url, clockwise: !clockwise)) != nil { back.append(url) }
            }
            IconProvider.shared.purgeFileIcons()
            if !back.isEmpty { registerUndo(back, clockwise: !clockwise, actionName: actionName) }
            if back.count != urls.count {
                NSAlert.show(L10n.tr("Some images couldn't be turned back."), L10n.tr("They were moved, changed or removed."), in: NSApp.keyWindow)
            }
        }
        center.undoManager.setActionName(actionName)
    }

    /// Sets the picture on every screen's desktop; headless runs only report it.
    static func setBackground(_ ctx: CommandContext) {
        guard let item = ctx.single, let window = ctx.window else { return }
        if AppDelegate.isHeadless {
            window.statusBar.setMessage(L10n.format("Desktop background: “%@” (not applied in test runs).", "\(item.name)"))
            return
        }
        var failure: Error?
        for screen in NSScreen.screens {
            do { try SystemOpen.setDesktopImage(item.url, for: screen) } catch { failure = error }
        }
        if let failure {
            NSAlert.show(L10n.format("Couldn't set “%@” as the desktop background.", "\(item.name)"), failure.localizedDescription, in: window.window)
        } else {
            window.statusBar.setMessage(L10n.format("“%@” is now the desktop background.", "\(item.name)"))
        }
    }
}
