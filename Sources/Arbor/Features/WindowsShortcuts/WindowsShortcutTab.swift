import AppKit
import ArborCore

/// Properties ▸ Shortcut: what a Windows shortcut records and what Arbor would do with it. Read-only.
final class WindowsShortcutTab: PropertiesTab, PropertiesTabDebug {
    let title = L10n.tr("Shortcut")
    let view: NSView
    private let model: PropertiesModel
    private let page = SheetPage()
    private let form = SheetForm(labelWidth: 100)
    private let status = SheetLabel.wrapping(L10n.tr("Reading the shortcut…"), secondary: true)
    private var rows: [ShortcutDetailRow] = []
    private var token: UUID?

    /// Aliases and links named x.lnk are Mac items, and archive members aren't files yet.
    static func applies(to model: PropertiesModel) -> Bool {
        guard let entry = model.single, entry.item.windowsShortcutKind != nil else { return false }
        return !entry.item.isSymbolicLink && !Shortcuts.isAlias(entry.url) && ArchiveCatalog.ref(for: entry.url) == nil
    }

    init(model: PropertiesModel) {
        self.model = model
        view = page
        form.add(status)
        page.embed(form.stack)
        load()
    }

    private func load() {
        guard let url = model.single?.url else { return }
        token = WindowsShortcutReader.inspect(url) { [weak self] in self?.show($0) }
    }

    private func show(_ outcome: WindowsShortcutReader.Outcome) {
        switch outcome {
        case .timedOut:
            status.stringValue = WindowsShortcutReader.timeoutMessage
        case .finished(.failure(let error)):
            status.stringValue = error.localizedDescription
        case .finished(.success(let inspection)):
            status.isHidden = true
            rows = inspection.detailRows
            for row in rows { form.row(row.label, Self.valueLabel(row.value), alignTop: true) }
            form.separator()
            form.add(SheetLabel.wrapping(L10n.tr("Arbor reads this Windows shortcut. It doesn't convert it to a Mac shortcut."), small: true))
        }
    }

    /// Fits any Windows path whole, while a hostile value can't push the window's buttons off the screen.
    private static let maxShownCharacters = 280

    private static func valueLabel(_ text: String) -> NSTextField {
        let label = SheetLabel.wrapping(UntrustedText.eliding(text, limit: maxShownCharacters), secondary: false)
        label.isSelectable = true
        label.toolTip = text
        return label
    }

    func reload() {}

    func close() {
        if let token { WindowsShortcutReader.cancel(token) }
    }

    var debugText: String {
        rows.isEmpty ? "shortcut: \(status.stringValue)" : rows.map { "\($0.label) \($0.value)" }.joined(separator: "\n")
    }
}
