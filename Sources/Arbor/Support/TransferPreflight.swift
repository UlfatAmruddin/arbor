import AppKit
import ArborCore

/// Checks before a copy or move starts. A check returns a prompt when the user should decide first
/// (e.g. copying out of a cloud folder downloads online-only files, FE-113); nil lets it run.
enum TransferPreflight {
    struct Prompt {
        let message: String
        let info: String
        let confirmTitle: String

        func ask(in window: NSWindow?, completion: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = message
            alert.informativeText = info
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: "Cancel")
            AlertSheets.present(alert, in: window) { completion($0 == .alertFirstButtonReturn) }
        }
    }

    typealias Check = (_ kind: TransferKind, _ sources: [URL], _ destination: URL) -> Prompt?
    private static var checks: [Check] = []

    static func register(_ check: @escaping Check) { checks.append(check) }

    static func prompt(_ kind: TransferKind, _ sources: [URL], to destination: URL) -> Prompt? {
        for check in checks { if let prompt = check(kind, sources, destination) { return prompt } }
        return nil
    }
}
