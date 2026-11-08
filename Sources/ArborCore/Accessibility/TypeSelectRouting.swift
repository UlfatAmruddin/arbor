import Foundation

/// Which keys pressed in the file list go to the input method for type-to-select (FE-068). Explorer passes
/// typed text through the IME, so Japanese, Chinese or Korean names can be found by typing them; Arbor does
/// the same through an input context of its own.
public enum TypeSelectRouting {
    /// True when the key types text: printable characters without ⌘ or ⌃. Space only continues a name that
    /// is already being typed (otherwise it belongs to the list: Quick Look, check boxes). While the input
    /// method is composing (`composing`), every key belongs to it, including arrows, Return and Escape.
    public static func goesToInputMethod(characters: String?, command: Bool, control: Bool,
                                         typeSelectActive: Bool, composing: Bool) -> Bool {
        if composing { return true }
        guard !command, !control, let characters, !characters.isEmpty else { return false }
        let printable = characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
        guard printable else { return false }
        if characters == " " { return typeSelectActive }
        return true
    }
}
