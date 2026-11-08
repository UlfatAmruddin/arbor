import AppKit
import ArborCore

/// New ▸ Shortcut: Explorer's two-page Create Shortcut wizard as a sheet (FE-092). Files and folders
/// become macOS aliases; web and server addresses become .webloc files.
final class CreateShortcutWizard: NSObject, NSTextFieldDelegate {
    private enum Target {
        case item(URL, isFolder: Bool)
        case address(URL)
    }

    private let folder: URL
    private weak var browser: BrowserWindowController?
    private let sheet: NSWindow
    private let heading = NSTextField(labelWithString: "")
    private let intro = NSTextField(wrappingLabelWithString: "")
    private let fieldLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let browse = NSButton(title: L10n.tr("Browse…"), target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")
    private let footnote = NSTextField(labelWithString: "")
    private let back = NSButton(title: L10n.tr("Back"), target: nil, action: nil)
    private let next = NSButton(title: L10n.tr("Next"), target: nil, action: nil)
    private let cancel = NSButton(title: L10n.tr("Cancel"), target: nil, action: nil)
    private var page = 1
    private var location = ""
    private var target: Target?
    /// Keeps the wizard alive while its sheet is up.
    private static var open: [CreateShortcutWizard] = []

    static func run(in folder: URL, window: BrowserWindowController) {
        guard let host = window.window else { return }
        let wizard = CreateShortcutWizard(folder: folder, browser: window)
        open.append(wizard)
        host.beginSheet(wizard.sheet) { _ in open.removeAll { $0 === wizard } }
        wizard.sheet.makeFirstResponder(wizard.field)
    }

    private init(folder: URL, browser: BrowserWindowController) {
        self.folder = folder
        self.browser = browser
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.title = L10n.tr("Create Shortcut")
        build()
        showPage(1)
    }

    private func build() {
        let content = ThemeBackgroundView(Theme.contentBackground)
        sheet.contentView = content

        let title = NSTextField(labelWithString: L10n.tr("Create Shortcut"))
        title.font = .systemFont(ofSize: 12)
        title.textColor = Theme.secondaryText
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = Theme.primaryText
        intro.font = Theme.bodyFont
        intro.textColor = Theme.primaryText
        fieldLabel.font = Theme.bodyFont
        fieldLabel.textColor = Theme.primaryText
        field.font = Theme.bodyFont
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel(L10n.tr("Location or name"))
        error.font = .systemFont(ofSize: 12)
        error.textColor = .systemRed
        error.isHidden = true
        footnote.font = Theme.bodyFont
        footnote.textColor = Theme.primaryText

        browse.target = self
        browse.action = #selector(browseClicked)
        back.target = self
        back.action = #selector(backClicked)
        next.target = self
        next.action = #selector(nextClicked)
        next.keyEquivalent = "\r"
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.keyEquivalent = "\u{1b}"
        for b in [browse, back, next, cancel] { b.bezelStyle = .rounded; b.controlSize = .regular }

        let fieldRow = NSStackView(views: [field, browse])
        fieldRow.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [NSView(), back, next, cancel])
        buttons.spacing = 8
        for b in [back, next, cancel] { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true }

        let footer = ThemeBackgroundView(Theme.navPaneBackground)
        footer.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(buttons)

        let stack = NSStackView(views: [title, heading, intro, fieldLabel, fieldRow, error, footnote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(14, after: heading)
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(6, after: fieldLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            fieldRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            error.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 56),
            buttons.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -12),
        ])
    }

    private func showPage(_ n: Int) {
        page = n
        error.isHidden = true
        if n == 1 {
            heading.stringValue = L10n.tr("What item would you like to create a shortcut for?")
            intro.stringValue = L10n.tr("This wizard helps you to create shortcuts to files, folders, disks, servers or internet addresses.")
            intro.isHidden = false
            fieldLabel.stringValue = L10n.tr("Type the location of the item:")
            field.stringValue = location
            field.placeholderString = L10n.tr("/Users/you/Documents/Report.pdf")
            browse.isHidden = false
            footnote.stringValue = L10n.tr("Click Next to continue.")
            back.isHidden = true
            next.title = L10n.tr("Next")
        } else {
            heading.stringValue = L10n.tr("What would you like to name the shortcut?")
            intro.isHidden = true
            fieldLabel.stringValue = L10n.tr("Type a name for this shortcut:")
            field.stringValue = defaultName()
            field.placeholderString = nil
            browse.isHidden = true
            footnote.stringValue = L10n.tr("Click Finish to create the shortcut.")
            back.isHidden = false
            next.title = L10n.tr("Finish")
        }
        updateNextEnabled()
        sheet.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func defaultName() -> String {
        switch target {
        case .item(let url, let isFolder)?: return ShortcutNaming.wizardDefaultName(for: url, isFolder: isFolder)
        case .address(let url)?: return ShortcutNaming.wizardDefaultName(for: url, isFolder: false)
        case nil: return ""
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        error.isHidden = true
        updateNextEnabled()
    }

    private func updateNextEnabled() {
        next.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func showError(_ text: String) {
        error.stringValue = text
        error.isHidden = false
    }

    // MARK: Actions

    @objc private func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.directoryURL = folder
        panel.prompt = "OK"
        panel.message = L10n.tr("Choose the item you want the shortcut to point to.")
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.field.stringValue = url.path
            self.updateNextEnabled()
        }
    }

    @objc private func backClicked() { showPage(1) }

    @objc private func cancelClicked() { close() }

    @objc private func nextClicked() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if page == 1 {
            location = text
            if let web = WebLocation.parseWebAddress(text) {
                target = .address(web)
                showPage(2)
                return
            }
            switch PathResolver().resolve(text, relativeTo: folder) {
            case .success(.folder(let url)): target = .item(url, isFolder: true); showPage(2)
            case .success(.file(let url)): target = .item(url, isFolder: false); showPage(2)
            case .success(.network(let url)): target = .address(url); showPage(2)
            case .failure:
                showError("Arbor can't find “\(text)”. Make sure you typed the name correctly, and then try again.")
            }
            return
        }
        finish(name: text)
    }

    private func finish(name: String) {
        if let problem = NameRules.validate(name) { showError(problem.errorDescription ?? "That name isn't valid."); return }
        guard let target else { showPage(1); return }
        do {
            let created: URL
            switch target {
            case .item(let url, _): created = try Shortcuts.createAlias(to: url, in: folder, name: name)
            case .address(let url): created = try Shortcuts.createWebLocation(url, in: folder, name: name)
            }
            Shortcuts.registerUndoCreate([created], name: "New Shortcut")
            let browser = self.browser
            close()
            if let browser, Location.folder(folder) == browser.location {
                browser.refreshSelecting([created.lastPathComponent])
            }
            browser?.statusBar.setMessage(L10n.format("Created “%@”.", "\(created.lastPathComponent)"))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
    }
}
