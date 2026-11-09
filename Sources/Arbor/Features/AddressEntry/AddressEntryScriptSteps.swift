import AppKit
import ArborCore

/// Script steps for the address-entry checks; TESTING.md describes each one.
enum AddressEntryScriptSteps {
    private static let readyTimeout: TimeInterval = 15

    static func register() {
        DebugScript.registerStep("addresstype") { text, c in
            guard let c else { return 0.05 }
            if !c.addressBar.isEditingPath { c.focusAddressBar() }
            guard let editor = c.addressBar.activeEditor else { return 0.05 }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            return 0.05
        }
        DebugScript.registerWaitStep("addresscompletionready") { _, c, elapsed in
            session(c)?.isSettled != false || elapsed > readyTimeout
        }
        DebugScript.registerStep("addresscompletions") { path, c in
            DebugScript.append((session(c)?.debugText ?? "completions: no session") + "\n", to: path)
            return 0.05
        }
        DebugScript.registerStep("addresslistsnap") { path, c in
            guard let dropdown = session(c)?.dropdown else { return 0.05 }
            _ = dropdown.writeSnapshot(to: path + ".png")
            DebugScript.append(AXDump.dump(dropdown.window), to: path + ".txt")
            return 0.05
        }
        DebugScript.registerStep("addressclickaway") { _, c in
            pressStatusBar(of: c)
            return 0.2
        }
    }

    private static func session(_ c: BrowserWindowController?) -> AddressCompletionController? {
        c?.addressBar.editingSession as? AddressCompletionController
    }

    /// The status bar takes neither focus nor the click, so only the list's own watch can react.
    private static func pressStatusBar(of c: BrowserWindowController?) {
        guard let c, let window = c.window else { return }
        let point = c.statusBar.convert(NSPoint(x: c.statusBar.bounds.midX, y: c.statusBar.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
