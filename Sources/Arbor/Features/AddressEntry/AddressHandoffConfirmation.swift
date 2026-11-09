import AppKit
import ArborCore

/// The one visible question before a typed address opens another app (SPEC §5.2).
enum AddressHandoffConfirmation {
    private static let recordLimit = 40
    private static let escape = "\u{1b}"

    /// What headless runs asked and how each was answered, for `log:`.
    private(set) static var headlessRecord: [String] = []

    static func ask(_ prompt: AddressHandoffPrompt, in window: NSWindow?, answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        // No button takes Return: it just sent the address, and a held key mustn't answer unread text.
        alert.addButton(withTitle: L10n.tr("Cancel")).keyEquivalent = escape
        alert.addButton(withTitle: prompt.confirmTitle)
        record("asked \(prompt.title) \(prompt.message)")
        AlertSheets.present(alert, in: window) { response in
            let accepted = response == .alertSecondButtonReturn
            record(accepted ? "accepted" : "declined")
            answer(accepted)
        }
    }

    private static func record(_ entry: String) {
        guard AppDelegate.isHeadless else { return }
        headlessRecord.append(entry)
        if headlessRecord.count > recordLimit { headlessRecord.removeFirst(headlessRecord.count - recordLimit) }
    }
}
