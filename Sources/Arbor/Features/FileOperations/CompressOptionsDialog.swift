import AppKit
import ArborCore

/// Compress to ▸ Additional options (Windows 11 24H2 "Create archive", FE-168): destination, name,
/// archive format, compression method and level, and whether hidden items inside folders go in.
/// Written with the system bsdtar into a staging folder on the destination's volume, then moved in
/// under a free name (never over an existing file), like the other Compress to items.
final class CompressOptionsDialog: FileOpsDialog {
    private let sources: [URL]
    private weak var browser: BrowserWindowController?
    private var options: ArchiveCreateOptions
    private let destinationField = NSTextField()
    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let methodPopup = NSPopUpButton()
    private let levelPopup = NSPopUpButton()
    private let hidden = NSButton(checkboxWithTitle: "Include hidden files and folders (names starting with “.”)", target: nil, action: nil)
    private let note = FileOpsStyle.label("", font: FileOpsStyle.captionFont, color: Theme.secondaryText, wraps: true)
    private let problem = FileOpsStyle.label("", font: FileOpsStyle.captionFont, color: SheetColors.failure, wraps: true)
    private lazy var create = WinButton("Create", accent: true) { [weak self] in self?.createArchive() }
    private let formats: [ArchiveOutputFormat]
    /// The name last proposed; while the user hasn't typed their own, changing the format proposes anew.
    private var suggestedName = ""

    static var current: CompressOptionsDialog? { open.last as? CompressOptionsDialog }

    static func register() {
        let r = CommandRegistry.shared
        r.register(ExplorerCommand(id: "archive.compress.options", title: "Additional options",
                                   isAvailable: ArchiveFeature.canCompress, isEnabled: ArchiveFeature.canCompress,
                                   perform: { ctx in show(ctx.selection.map(\.url), browser: ctx.window) }))
        // Compress to ▸ ZIP File · 7z File · TAR File · Additional options (Windows order).
        if let compressTo = r.command("archive.compressTo"), let original = compressTo.submenu {
            compressTo.submenu = { ctx in
                var items = original(ctx)
                guard !items.isEmpty else { return items }
                items.append(.separator())
                let urls = ctx.selection.map(\.url)
                weak let browser = ctx.window
                items.append(ClosureMenuItem("Additional options") { show(urls, browser: browser) })
                return items
            }
        }
        /// compressset:format=tarGzip,method=store,level=maximum,hidden=off,name=x.tar.gz,dest=/path
        DebugScript.registerStep("compressset") { argument, _ in
            current?.scriptSet(argument)
            return 0.3
        }
    }

    static func show(_ urls: [URL], browser: BrowserWindowController?) {
        guard !urls.isEmpty else { return }
        CompressOptionsDialog(urls, browser: browser).present(over: browser?.window)
    }

    init(_ sources: [URL], browser: BrowserWindowController?) {
        self.sources = sources
        self.browser = browser
        let folder = sources[0].deletingLastPathComponent()
        let isFolder = FileOps.isPlainFolder(sources[0])
        let single = sources.count == 1 && !isFolder
        formats = ArchiveOutputFormat.available(forSingleFile: single)
        let base = Self.suggestedName(for: .zip, sources: sources)
        options = ArchiveCreateOptions(name: base, destinationFolder: folder)
        super.init(title: "Create archive", width: 520)

        let heading = FileOpsStyle.label("Choose how to compress \(sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : StatusText.items(sources.count))",
                                         font: FileOpsStyle.instructionFont, wraps: true)
        heading.preferredMaxLayoutWidth = 480
        destinationField.stringValue = folder.path
        destinationField.font = FileOpsStyle.bodyFont
        destinationField.lineBreakMode = .byTruncatingMiddle
        destinationField.target = self
        destinationField.action = #selector(fieldsChanged)
        nameField.stringValue = base
        suggestedName = base
        nameField.font = FileOpsStyle.bodyFont
        nameField.target = self
        nameField.action = #selector(fieldsChanged)
        let browse = WinButton("Browse…") { [weak self] in self?.browse() }
        for popup in [formatPopup, methodPopup, levelPopup] {
            popup.font = FileOpsStyle.bodyFont
            popup.target = self
        }
        formatPopup.addItems(withTitles: formats.map(\.title))
        formatPopup.action = #selector(formatChanged)
        methodPopup.action = #selector(choicesChanged)
        levelPopup.action = #selector(choicesChanged)
        hidden.font = FileOpsStyle.bodyFont
        hidden.state = .on
        hidden.target = self
        hidden.action = #selector(choicesChanged)
        note.preferredMaxLayoutWidth = 480
        problem.preferredMaxLayoutWidth = 480

        func caption(_ text: String) -> NSTextField { FileOpsStyle.label(text, color: Theme.secondaryText) }
        let destinationRow = NSStackView(views: [destinationField, browse])
        destinationRow.spacing = 8
        let grid = NSGridView(views: [
            [caption("Destination:"), destinationRow],
            [caption("Archive name:"), nameField],
            [caption("Archive format:"), formatPopup],
            [caption("Compression method:"), methodPopup],
            [caption("Compression level:"), levelPopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            destinationField.widthAnchor.constraint(equalToConstant: 250),
            nameField.widthAnchor.constraint(equalToConstant: 354),
            formatPopup.widthAnchor.constraint(equalToConstant: 240),
            methodPopup.widthAnchor.constraint(equalToConstant: 240),
            levelPopup.widthAnchor.constraint(equalToConstant: 240),
        ])
        let body = setBody([heading, grid, hidden, note, problem], spacing: 12)
        body.setCustomSpacing(16, after: heading)
        setButtons([create, WinButton("Cancel") { [weak self] in self?.dismiss() }])
        syncPopups()
    }

    // MARK: Choices

    private var format: ArchiveOutputFormat { formats.indices.contains(formatPopup.indexOfSelectedItem) ? formats[formatPopup.indexOfSelectedItem] : .zip }

    @objc private func formatChanged() {
        options.format = format
        options.method = format.methods[0]
        // A proposed name follows the format ("Photos.zip" → "Photos.tar.gz", "notes.txt" → "notes.txt.gz");
        // a name the user typed keeps its stem and gets the new extension.
        let proposal = Self.suggestedName(for: format, sources: sources)
        nameField.stringValue = nameField.stringValue == suggestedName ? proposal
            : ArchiveCreateOptions.name(nameField.stringValue, withExtensionFor: format)
        suggestedName = proposal
        syncPopups()
    }

    /// "Photos.zip" for a folder or several items; gzip/BZip2/xz keep the file's own name: "notes.txt.gz".
    static func suggestedName(for format: ArchiveOutputFormat, sources: [URL]) -> String {
        let first = sources[0]
        if format.isSingleFile { return "\(first.lastPathComponent).\(format.fileExtension)" }
        let zip = ArchiveNaming.archiveName(for: first.lastPathComponent, isFolder: FileOps.isPlainFolder(first), format: .zip) { _ in false }
        return ArchiveCreateOptions.name(zip, withExtensionFor: format)
    }

    @objc private func choicesChanged() {
        let methods = format.methods
        if methods.indices.contains(methodPopup.indexOfSelectedItem) { options.method = methods[methodPopup.indexOfSelectedItem] }
        let levels = format.levels
        if levels.indices.contains(levelPopup.indexOfSelectedItem) { options.level = levels[levelPopup.indexOfSelectedItem] }
        options.includeHiddenItems = hidden.state == .on
        syncPopups()
    }

    @objc private func fieldsChanged() { validate() }

    private func syncPopups() {
        let methods = format.methods
        methodPopup.removeAllItems()
        methodPopup.addItems(withTitles: methods.map(\.title))
        methodPopup.selectItem(at: methods.firstIndex(of: options.method) ?? 0)
        methodPopup.isEnabled = methods.count > 1
        let levels = format.levels
        levelPopup.removeAllItems()
        if levels.isEmpty || options.method == .store {
            levelPopup.addItem(withTitle: levels.isEmpty ? "None (TAR doesn't compress)" : "None")
            levelPopup.isEnabled = false
        } else {
            levelPopup.addItems(withTitles: levels.map(\.title))
            levelPopup.selectItem(at: levels.firstIndex(of: options.level) ?? 1)
            levelPopup.isEnabled = true
        }
        hidden.isEnabled = !format.isSingleFile
        var text: String
        switch format {
        case .zip: text = "ZIP opens everywhere, including Windows. Mac-only properties (Finder tags, resource forks) aren't stored; Compress to ▸ ZIP File keeps them for a single item."
        case .sevenZip: text = "7z usually makes the smallest archives. Windows 11 opens it."
        case .tar, .tarGzip, .tarBzip2, .tarXz: text = "TAR keeps Unix permissions and links. Windows 11 opens .tar, .tar.gz, .tar.bz2 and .tar.xz."
        case .gzip, .bzip2, .xz: text = "Compresses this one file on its own, without an archive around it."
        }
        text += " Items you selected are always included."
        note.stringValue = text
        validate()
    }

    @discardableResult
    private func validate() -> Bool {
        options.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        options.destinationFolder = URL(fileURLWithPath: (destinationField.stringValue as NSString).expandingTildeInPath)
        var message = options.problem(for: sources)
        if message == nil, !FileOps.isPlainFolder(options.destinationFolder) { message = "The destination folder doesn't exist." }
        problem.stringValue = message ?? ""
        problem.isHidden = message == nil
        create.isEnabled = message == nil
        refit()
        return message == nil
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = options.destinationFolder
        panel.prompt = "Select Folder"
        panel.beginSheetModal(for: self.panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.destinationField.stringValue = url.path
            self?.validate()
        }
    }

    override func cancelled() { dismiss() }

    // MARK: Creating

    private func createArchive() {
        guard validate() else { return }
        let options = self.options
        let sources = self.sources
        weak let browser = self.browser
        dismiss()
        let process = ToolProcess()
        let activity = OperationCenter.Activity(text: "Compressing \(sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : StatusText.items(sources.count))") {
            process.cancel()
        }
        OperationCenter.shared.begin(activity)
        let folder = options.destinationFolder.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome: Result<URL, Error> = .failure(ArchiveError.toolFailed("The archive couldn't be saved in the folder."))
            do {
                let total = Double(max(Self.countEntries(sources, limit: 200_000), 1))
                var done = 0.0
                let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let output = staging.appendingPathComponent(options.name)
                try ArchiveTool.create(options, sources: sources, output: output, process: process) {
                    done += 1
                    let fraction = min(done / total, 1) * 0.98
                    DispatchQueue.main.async { OperationCenter.shared.update(activity, fraction: fraction) }
                }
                // Never overwrite: take the next free "name (2).ext" if the name is taken.
                for _ in 0..<1000 {
                    let name = ArchiveNaming.uniqueName(options.name) { FileOps.exists(folder.appendingPathComponent($0)) }
                    do {
                        let target = folder.appendingPathComponent(name)
                        try FileManager.default.moveItem(at: output, to: target)
                        outcome = .success(target)
                        break
                    } catch CocoaError.fileWriteFileExists {
                        continue
                    }
                }
            } catch {
                outcome = .failure(process.isCancelled ? ArchiveError.cancelled : error)
            }
            DispatchQueue.main.async {
                OperationCenter.shared.end(activity)
                CompressOptionsDialog.lastResult = outcome.map(\.path)
                switch outcome {
                case .success(let url):
                    ArchiveJobs.registerUndoCreate(url, action: "Compress")
                    guard let browser else { return }
                    if Location.folder(folder) == browser.location {
                        browser.refreshSelecting([url.lastPathComponent])
                    }
                    browser.statusBar.setMessage("Created “\(url.lastPathComponent)” in “\(displayName(of: folder))”.")
                case .failure(let error):
                    ArchiveJobs.show(error, title: "Couldn't create “\(options.name)”.", window: browser?.window)
                }
            }
        }
    }

    /// Headless checks read where the last archive went.
    static var lastResult: Result<String, Error>?

    /// Bounded, job-scoped count for the progress fraction.
    private static func countEntries(_ urls: [URL], limit: Int) -> Int {
        var count = 0
        for url in urls {
            count += 1
            guard FileOps.isPlainFolder(url), let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            while walker.nextObject() != nil {
                count += 1
                if count >= limit { return count }
            }
        }
        return count
    }

    // MARK: Scripting

    func scriptSet(_ argument: String) {
        for part in argument.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "format":
                if let f = ArchiveOutputFormat(rawValue: kv[1]), let i = formats.firstIndex(of: f) {
                    formatPopup.selectItem(at: i)
                    formatChanged()
                }
            case "method":
                if let m = CompressionMethod(rawValue: kv[1]), let i = format.methods.firstIndex(of: m) {
                    methodPopup.selectItem(at: i)
                    choicesChanged()
                }
            case "level":
                if let i = format.levels.firstIndex(where: { "\($0)" == kv[1] }) {
                    levelPopup.selectItem(at: i)
                    choicesChanged()
                }
            case "hidden":
                hidden.state = kv[1] == "on" ? .on : .off
                choicesChanged()
            case "name":
                nameField.stringValue = kv[1]
                validate()
            case "dest":
                destinationField.stringValue = kv[1]
                validate()
            default: break
            }
        }
    }

    var debugText: String {
        "compress options: format=\(options.format.rawValue) method=\(options.method.rawValue) level=\(levelPopup.isEnabled ? "\(options.level)" : "none") hidden=\(options.includeHiddenItems) name=\(nameField.stringValue) create=\(create.isEnabled)\(problem.isHidden ? "" : " problem=\(problem.stringValue)")"
    }
}
