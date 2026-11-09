import Foundation

public struct ShortcutDetailRow: Equatable, Sendable {
    public let label: String
    public let value: String

    /// Everything shown comes from the file, so it is cleaned here, in one place.
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = UntrustedText.display(value)
    }
}

public extension WindowsShortcutInspection {
    /// The rows of the Properties ▸ Shortcut tab.
    var detailRows: [ShortcutDetailRow] {
        switch self {
        case .internet(let shortcut): return Self.rows(for: shortcut)
        case .link(let link, let destination): return Self.rows(for: link, destination)
        }
    }

    private static func rows(for shortcut: InternetShortcut) -> [ShortcutDetailRow] {
        var rows = [ShortcutDetailRow(L10n.tr("Type:"), WindowsShortcutKind.internet.typeName)]
        switch shortcut.address {
        case .success(let url):
            rows.append(ShortcutDetailRow(L10n.tr("Address:"), url.absoluteString))
            rows.append(ShortcutDetailRow(L10n.tr("Will open:"), L10n.tr("Yes, after you confirm")))
        case .failure(let refusal):
            if let raw = shortcut.rawAddress { rows.append(ShortcutDetailRow(L10n.tr("Address:"), raw)) }
            rows.append(ShortcutDetailRow(L10n.tr("Will open:"), refusal.explanation))
        }
        return rows
    }

    private static func rows(for link: ShellLink, _ destination: LinkDestination) -> [ShortcutDetailRow] {
        var rows = [ShortcutDetailRow(L10n.tr("Type:"), WindowsShortcutKind.link.typeName)]
        func add(_ label: String, _ value: String?) {
            if let value { rows.append(ShortcutDetailRow(label, value)) }
        }
        add(L10n.tr("Target:"), link.localPath ?? link.networkPath ?? link.environmentTarget ?? link.relativePath)
        add(L10n.tr("Arguments:"), link.arguments)
        add(L10n.tr("Start in:"), link.workingDirectory)
        add(L10n.tr("Comment:"), link.comment)
        add(L10n.tr("Target size:"), link.targetSize > 0 ? PropertyFormat.propertiesSize(link.targetSize) : nil)
        add(L10n.tr("Target modified:"), link.targetModified.map { PropertyFormat.longDate($0) })
        add(L10n.tr("On this Mac:"), onThisMac(destination))
        return rows
    }

    private static func onThisMac(_ destination: LinkDestination) -> String {
        switch destination {
        case .folder(let url), .document(let url): return url.path
        case .revealOnly(let url): return L10n.format("%@ (Arbor only shows this kind of item in its folder)", "\(url.path)")
        case .blocked(let block): return block.explanation
        }
    }
}
