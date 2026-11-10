import AppKit
import ArborCore
import UniformTypeIdentifiers

/// Export and import: panels, background file work and messages. Preferences change only after the preview's Import. Main thread only.
enum SettingsTransferFlow {
    /// How long a chosen location gets to answer, so a hung share ends in a message rather than silence.
    private static let timeout: TimeInterval = 15
    private static let reads = SlowWorkQueue<Result<PortableSettingsFile, Error>>(label: "arbor.settings.read")
    private static let writes = SlowWorkQueue<Error?>(label: "arbor.settings.write")

    /// The window an import is running on; weak, so closing it can't leave Import disabled (DEC-settings-8).
    private(set) static weak var importHost: NSWindow?

    static var isImporting: Bool { importHost.map { $0.isVisible || $0.isMiniaturized } ?? false }

    static var canExport: Bool { BrowserWindowController.active?.window.map { $0.attachedSheet == nil } ?? false }

    /// One import at a time app-wide: a second preview would queue with a stale "Now" column.
    static var canImport: Bool { canExport && !isImporting }

    static func beginImport(on host: NSWindow) { importHost = host }

    /// Every way out of an import ends here; a closed window's late reply must not end a newer import elsewhere.
    static func endImport(on host: NSWindow?) {
        if importHost === host { importHost = nil }
    }

    // MARK: Export

    static func chooseExportDestination(from browser: BrowserWindowController) {
        guard let host = browser.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.tr("Arbor Settings") + ".json"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.message = L10n.tr("Folders, pins, network drives and passwords aren't included.")
        panel.beginSheetModal(for: host) { [weak browser] response in
            guard response == .OK, let url = panel.url, let browser else { return }
            exportSettings(to: url, from: browser)
        }
    }

    static func exportSettings(to url: URL, from browser: BrowserWindowController) {
        let data: Data
        do {
            data = try PortableSettingsFile.encoded(reading: SettingsTransferStore.current)
        } catch {
            showExportFailure(error.localizedDescription, in: browser.window)
            return
        }
        // Keyed by content too: a retry of the same bytes shares a hung write, but changed settings must not.
        writes.run(key: url.path + "\n" + String(decoding: data, as: UTF8.self), timeout: timeout, work: {
            do {
                try data.write(to: url, options: .atomic)
                return nil
            } catch {
                return error
            }
        }, completion: { [weak browser] outcome in
            switch outcome {
            case .timedOut:
                showExportFailure(L10n.tr("The location didn't respond in time, so the file may not have been saved."), in: browser?.window)
            case .finished(let failure?):
                showExportFailure(failure.localizedDescription, in: browser?.window)
            case .finished(nil):
                browser?.statusBar.setMessage(L10n.format("Settings exported to “%@”.", "\(url.lastPathComponent)"))
            }
        })
    }

    private static func showExportFailure(_ reason: String, in window: NSWindow?) {
        NSAlert.show(L10n.tr("Couldn't export the settings."), reason, in: window)
    }

    // MARK: Import

    static func chooseImportFile(from browser: BrowserWindowController) {
        guard let host = browser.window else { return }
        beginImport(on: host)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = L10n.tr("Choose an Arbor settings file. You'll see what would change before anything does.")
        panel.beginSheetModal(for: host) { [weak browser, weak host] response in
            guard response == .OK, let url = panel.url, let browser else { endImport(on: host); return }
            importSettings(from: url, into: browser)
        }
    }

    static func importSettings(from url: URL, into browser: BrowserWindowController) {
        guard let host = browser.window else { return }
        beginImport(on: host)
        reads.run(key: url.path, timeout: timeout, work: {
            Result { try PortableSettingsFile.read(from: url) }
        }, completion: { [weak browser, weak host] outcome in
            guard let browser, let host, host.isVisible || host.isMiniaturized else { endImport(on: host); return }
            switch outcome {
            case .timedOut: showImportFailure(PortableSettingsError.unreadable, in: host)
            case .finished(.failure(let error)): showImportFailure(error, in: host)
            case .finished(.success(let file)): offer(file, browser: browser, host: host)
            }
        })
    }

    private static func showImportFailure(_ error: Error, in host: NSWindow) {
        endImport(on: host)
        NSAlert.show(L10n.tr("Couldn't import the settings."), error.localizedDescription, in: host)
    }

    private static func offer(_ file: PortableSettingsFile, browser: BrowserWindowController, host: NSWindow) {
        let plan = PortableImportPlan.make(file: file, current: SettingsTransferStore.current,
                                           unavailable: FolderOptionsPrefs.runtimeDisabledKeys)
        guard !plan.changes.isEmpty else {
            endImport(on: host)
            let message = plan.alreadyMatches ? L10n.tr("Your settings already match this file.") : L10n.tr("Nothing to import from this file.")
            NSAlert.show(message, plan.note, style: .informational, in: host)
            return
        }
        AlertSheets.present(SettingsImportPreview.alert(for: plan), in: host) { [weak browser, weak host] response in
            endImport(on: host)
            guard response == .alertFirstButtonReturn else { return }
            SettingsTransferStore.apply(plan)
            let count = plan.changes.count
            browser?.statusBar.setMessage(L10n.plural(one: "Imported %lld setting.", other: "Imported %lld settings.", count))
        }
    }
}
