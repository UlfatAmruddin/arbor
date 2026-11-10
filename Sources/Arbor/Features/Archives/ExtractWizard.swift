import AppKit
import ArborCore

/// Explorer's "Extract Compressed (Zipped) Folders" wizard (FE-163), as a one-page sheet.
final class ExtractWizard: NSWindowController, NSTextFieldDelegate {
    private static var open: [ExtractWizard] = []

    let archive: URL
    private weak var browser: BrowserWindowController?
    let pathField = NSTextField()
    let showFiles = NSButton(checkboxWithTitle: L10n.tr("Show extracted files when complete"), target: nil, action: nil)
    private let extractButton = NSButton(title: L10n.tr("Extract"), target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")

    static func show(for archive: URL, in browser: BrowserWindowController) {
        let wizard = ExtractWizard(archive: archive, browser: browser)
        open.append(wizard)
        guard let host = browser.window, let sheet = wizard.window else { return }
        if AppDelegate.isHeadless { sheet.alphaValue = 0 }
        host.beginSheet(sheet) { _ in open.removeAll { $0 === wizard } }
        sheet.makeFirstResponder(wizard.pathField)
    }

    /// The wizard on screen for a window (scripts).
    static func current(in window: NSWindow?) -> ExtractWizard? { open.first { $0.window?.sheetParent === window } }

    init(archive: URL, browser: BrowserWindowController) {
        self.archive = archive
        self.browser = browser
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        build(panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(_ panel: NSWindow) {
        let root = ThemeBackgroundView(Theme.contentBackground)
        panel.contentView = root
        panel.title = L10n.tr("Extract Compressed (Zipped) Folders")

        let caption = NSTextField(labelWithString: L10n.tr("Extract Compressed (Zipped) Folders"))
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = Theme.secondaryText
        let captionIcon = NSImageView(image: IconProvider.shared.symbolIcon("doc.zipper", color: 0x8A6D1F, size: 16))
        captionIcon.hideFromAccessibility()

        let heading = NSTextField(labelWithString: L10n.tr("Select a Destination and Extract Files"))
        heading.font = .systemFont(ofSize: 17, weight: .regular)
        heading.textColor = Theme.wizardHeading

        let prompt = NSTextField(labelWithString: L10n.tr("Files will be extracted to this folder:"))
        prompt.font = Theme.bodyFont
        prompt.textColor = Theme.primaryText

        pathField.stringValue = ArchiveNaming.extractionFolder(for: archive).path
        RightToLeft.holdLeftToRight(pathField)
        pathField.font = Theme.bodyFont
        pathField.lineBreakMode = .byTruncatingHead
        pathField.cell?.usesSingleLineMode = true
        pathField.delegate = self
        pathField.setAccessibleName(L10n.tr("Files will be extracted to this folder"))

        let browse = NSButton(title: L10n.tr("Browse…"), target: self, action: #selector(browse(_:)))
        browse.bezelStyle = .rounded

        showFiles.state = .on
        showFiles.font = Theme.bodyFont

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isHidden = true

        let footer = ThemeBackgroundView(Theme.navPaneBackground)
        let rule = ThemeBackgroundView(Theme.separator)
        extractButton.target = self
        extractButton.action = #selector(extract(_:))
        extractButton.keyEquivalent = "\r"
        extractButton.bezelStyle = .rounded
        let cancel = NSButton(title: L10n.tr("Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        for b in [extractButton, cancel] { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true }

        let views: [NSView] = [captionIcon, caption, heading, prompt, pathField, browse, showFiles, errorLabel, footer, rule, extractButton, cancel]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            captionIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            captionIcon.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            captionIcon.widthAnchor.constraint(equalToConstant: 16),
            captionIcon.heightAnchor.constraint(equalToConstant: 16),
            caption.leadingAnchor.constraint(equalTo: captionIcon.trailingAnchor, constant: 8),
            caption.centerYAnchor.constraint(equalTo: captionIcon.centerYAnchor),

            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 44),
            heading.topAnchor.constraint(equalTo: captionIcon.bottomAnchor, constant: 22),
            prompt.leadingAnchor.constraint(equalTo: heading.leadingAnchor, constant: 0),
            prompt.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 26),
            pathField.leadingAnchor.constraint(equalTo: prompt.leadingAnchor),
            pathField.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: browse.leadingAnchor, constant: -10),
            pathField.heightAnchor.constraint(equalToConstant: 24),
            browse.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -44),
            browse.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            showFiles.leadingAnchor.constraint(equalTo: prompt.leadingAnchor),
            showFiles.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 16),
            errorLabel.leadingAnchor.constraint(equalTo: prompt.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: browse.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: showFiles.bottomAnchor, constant: 10),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 60),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: footer.topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            cancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            cancel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            extractButton.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -10),
            extractButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        root.setAccessibilityLabel(L10n.tr("Select a Destination and Extract Files"))
    }

    func controlTextDidChange(_ obj: Notification) {
        errorLabel.isHidden = true
        extractButton.isEnabled = !pathField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func browse(_ sender: Any?) {
        guard let sheet = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("Select Folder")
        panel.message = L10n.tr("Select a destination")
        panel.directoryURL = archive.deletingLastPathComponent()
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = url.path
            self?.errorLabel.isHidden = true
        }
    }

    /// The destination typed or chosen, or an explanation of what's wrong with it.
    func destination() -> Result<URL, ArchiveJobs.Failure> {
        let text = (pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard text.hasPrefix("/") else { return .failure(.message(L10n.tr("Type a full path, such as ~/Documents/Photos."))) }
        let url = URL(fileURLWithPath: text).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return .failure(.message(L10n.format("“%@” is a file. Choose a folder.", url.lastPathComponent)))
        }
        return .success(url)
    }

    @objc func extract(_ sender: Any?) {
        let destination: URL
        switch self.destination() {
        case .success(let url): destination = url
        case .failure(let failure):
            errorLabel.stringValue = failure.localizedDescription
            errorLabel.isHidden = false
            return
        }
        let reveal = showFiles.state == .on
        let archive = self.archive
        let browser = self.browser
        close(sheet: true)
        let request = ArchiveJobs.ExtractRequest(archive: archive, roots: [""], base: "", destination: destination,
                                                 verb: L10n.format("Extracting “%@”", archive.lastPathComponent))
        ArchiveJobs.extract(request, window: browser?.window) { result in
            switch result {
            case .success(let outcome):
                ArchiveFeature.lastExtraction = destination
                ArchiveJobs.reportSkipped(outcome, window: browser?.window)
                guard let browser else { return }
                if reveal {
                    // Explorer opens the destination when done; Arbor opens it in a new tab.
                    browser.openTab(.folder(destination), select: outcome.placed.map(\.lastPathComponent))
                } else {
                    browser.statusBar.setMessage(L10n.format("Extracted “%@” to “%@”.", "\(archive.lastPathComponent)", "\(displayName(of: destination))"))
                }
            case .failure(let error):
                ArchiveJobs.show(error, title: L10n.format("“%@” couldn't be extracted.", "\(archive.lastPathComponent)"), window: browser?.window)
            }
        }
    }

    @objc private func cancel(_ sender: Any?) { close(sheet: false) }

    private func close(sheet ok: Bool) {
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet, returnCode: ok ? .OK : .cancel)
    }
}

extension Theme {
    /// Explorer's heading blue: deep in light mode, light in dark mode.
    static let wizardHeading = dynamic(light: 0x1E3287, dark: 0x99C2FF)
}
