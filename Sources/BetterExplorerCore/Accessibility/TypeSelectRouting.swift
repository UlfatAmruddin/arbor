import Foundation

/// Which file-list keys go to the input method for type-to-select (FE-068), so CJK names can be typed.
public enum TypeSelectRouting {
    /// True for printable keys without ⌘/⌃. Space only continues a name being typed (else Quick Look, check boxes).
    /// While `composing`, every key goes to the input method, including arrows, Return and Escape.
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
