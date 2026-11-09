import AppKit
import ArborCore

/// Runs the chosen preset's commands (FE-066); a key that can't run here goes on to the focused view (DEC-accessibility-13).
enum FileListKeys {
    /// Returns true when the event was consumed.
    static func handle(_ event: NSEvent, in c: BrowserWindowController) -> Bool {
        guard let action = Prefs.fileListKeyPreset.command(keyCode: event.keyCode, modifiers: modifierNames(of: event)) else { return false }
        if c.isEditingText {
            // Text fields keep every key, but a held Return must not commit the rename it has just opened.
            return c.itemView?.isEditingName == true && event.isARepeat && !action.repeatsWhileHeld
        }
        let focused = FocusRegions.focusedView(in: c.window)
        guard FocusRegions.region(of: focused, in: c) == .items, !(focused is NSButton) else { return false }
        // The monitor runs before the grid's keyDown, which cancels a pending slow-click rename for any key.
        ItemSurface(c)?.prepareToOpen()
        if event.isARepeat && !action.repeatsWhileHeld { return true }

        guard let command = CommandRegistry.shared.command(action.rawValue) else { return false }
        let context = c.context(surface: .keyboard, sender: nil)
        guard command.isAvailable(context) else { return false }
        guard command.isEnabled(context) else {
            // On a selected list item the view would open it: a rename key must never launch a read-only item.
            guard context.hasSelection, focused === c.itemView?.focusView else { return false }
            NSSound.beep()
            return true
        }
        command.perform(context)
        return true
    }

    private static func modifierNames(of event: NSEvent) -> Set<String> {
        let names: [(NSEvent.ModifierFlags, String)] = [(.command, "command"), (.option, "option"), (.shift, "shift"), (.control, "control")]
        return Set(names.filter { event.modifierFlags.contains($0.0) }.map(\.1))
    }
}
