import AppKit
import ArborCore

/// Script steps and log lines for scripts/acceptance.sh (docs/ACCEPTANCE.md):
/// - `menukey:<keys>` (e.g. `cmd+x`) delivers that shortcut's menu command like its menu item
///   (responder chain first); `key:` goes to the window only.
/// - `log:` adds a `clipboard:` line: pasteboard names, copy or move, and which items are drawn as cut.
enum AcceptanceScriptSteps: ExplorerFeature {
    static let id = "acceptance-steps"
    static func register() {
        DebugScript.registerStep("menukey") { spec, window in
            // Headless windows are never key, so AppKit can't match key equivalents: deliver it like its menu item.
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
