import AppKit
import ArborCore

/// Asks for a library name in a sheet: the reason shows while typing and the confirm button follows it.
final class LibraryNameSheet: NSObject, NSTextFieldDelegate {
    private let field: NSTextField
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let confirmButton: NSButton
    private let problem: (String) -> String?
    private var announcedReason: String?

    /// `problem` returns why a name can't be used, or nil. `commit` runs on OK and must re-check, since the list can change meanwhile.
    static func present(title: String, message: String, initial: String, confirm: String, in window: NSWindow?,
                        problem: @escaping (String) -> String?, commit: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: L10n.tr("Cancel"))
        let sheet = LibraryNameSheet(initial: initial, confirmButton: confirmButton, problem: problem)
        alert.accessoryView = sheet.accessory
        alert.window.initialFirstResponder = sheet.field
        sheet.validate()
        AlertSheets.present(alert, in: window) { response in
            // `sheet` stays alive through this capture for as long as the field needs its delegate.
            guard response == .alertFirstButtonReturn else { return }
            let text = sheet.field.stringValue
            DispatchQueue.main.async { commit(text) }
        }
        DispatchQueue.main.async { sheet.field.currentEditor()?.selectAll(nil) }
    }

    private init(initial: String, confirmButton: NSButton, problem: @escaping (String) -> String?) {
        field = NSTextField(string: initial)
        self.confirmButton = confirmButton
        self.problem = problem
        super.init()
        field.delegate = self
        field.setAccessibilityLabel(L10n.tr("Library name"))
        reason.font = Theme.statusFont
        reason.textColor = .systemRed
    }

    private lazy var accessory: NSView = {
        let width: CGFloat = 320, reasonHeight: CGFloat = 48, fieldHeight: CGFloat = 24   // three lines: the longest reason quotes a shortened name
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: fieldHeight + reasonHeight + 4))
        field.frame = NSRect(x: 0, y: reasonHeight + 4, width: width, height: fieldHeight)
        reason.frame = NSRect(x: 0, y: 0, width: width, height: reasonHeight)
        container.addSubview(field)
        container.addSubview(reason)
        return container
    }()

    private func validate() {
        let why = problem(field.stringValue)
        reason.stringValue = why ?? ""
        confirmButton.isEnabled = why == nil
        if let why, why != announcedReason { Announcer.announce(why, in: field.window, priority: .high) }
        announcedReason = why
    }

    func controlTextDidChange(_ obj: Notification) { validate() }
}
