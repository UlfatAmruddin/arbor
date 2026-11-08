import AppKit
import ArborCore

/// Script steps and log lines used by scripts/acceptance.sh (docs/ACCEPTANCE.md).
///
/// - `menukey:<keys>` presses a menu shortcut such as `cmd+x`: the menu command with that shortcut is delivered
///   the way its menu item delivers it (responder chain first). The `key:` step delivers keys to the window only.
/// - `log:` gains a `clipboard:` line: what the pasteboard names, whether a paste would copy or move, and which
///   listed items are drawn as cut.
enum AcceptanceScriptSteps: ExplorerFeature {
    static let id = "acceptance-steps"
    static func register() {
        DebugScript.registerStep("menukey") { spec, window in
            // Headless windows are never key, so AppKit's own key-equivalent matching can't be used: find the menu
            // command with this shortcut and deliver it the way its menu item does.
            guard let window, let key = KeyNames.parse(spec) else { NSLog("DebugScript: bad key \(spec)"); return 0.5 }
            var flags: NSEvent.ModifierFlags = []
            if key.modifiers.contains("command") { flags.insert(.command) }
            if key.modifiers.contains("option") { flags.insert(.option) }
            if key.modifiers.contains("shift") { flags.insert(.shift) }
            if key.modifiers.contains("control") { flags.insert(.control) }
            let relevant: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
            guard let command = CommandRegistry.shared.all.first(where: { command in
                guard let shortcut = command.shortcut else { return false }
                return shortcut.key == key.characters && shortcut.modifiers.intersection(relevant) == flags
            }) else { NSLog("DebugScript: no menu command for \(spec)"); return 0.5 }
            if let action = command.menuAction {
                let start: NSResponder? = window.window?.firstResponder ?? window.window
                if start?.tryToPerform(action, with: nil) != true { _ = NSApp.sendAction(action, to: nil, from: nil) }
            } else if !window.perform(command.id, surface: .script) {
                NSLog("DebugScript: \(command.id) unavailable or disabled")
            }
            return 0.6
        }
        DebugScript.registerLogger("acceptance-steps.log") { window in
            let clipboard = FileClipboard.shared
            let urls = clipboard.readURLs()
            let kind = urls.isEmpty ? "none" : clipboard.pasteKind(for: urls).rawValue
            let marked = window.visibleItems.filter { clipboard.isCut($0.url) }.map(\.name)
            return "clipboard: names=[\(urls.map(\.lastPathComponent).joined(separator: ","))] paste=\(kind) cut marks=[\(marked.joined(separator: ","))]"
        }
    }
}
