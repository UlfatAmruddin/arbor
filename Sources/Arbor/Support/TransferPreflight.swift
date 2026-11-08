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
    static let checks = Handlers<(TransferKind, [URL], URL), Prompt>(
        "TransferPreflight.checks", "A question before a copy or move starts (download online-only files first).",
        signature: "(kind, sources, destination) -> Prompt?")

    static func register(_ id: String, order: ExtensionOrder = .normal, _ check: @escaping Check) {
        checks.register(id, order: order) { kind, sources, destination in check(kind, sources, destination) }
    }

    static func prompt(_ kind: TransferKind, _ sources: [URL], to destination: URL) -> Prompt? {
        checks.first((kind, sources, destination))
    }
}
