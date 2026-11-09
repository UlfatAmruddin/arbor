import AppKit
import Quartz
import UniformTypeIdentifiers

/// The only path for asking the system to open, reveal, share or change anything outside Arbor's windows.
/// Headless runs (`ARBOR_HEADLESS`) just record requests (`log:`); `SystemOpenAuditTests` enforces this file's use.
enum SystemOpen {
    static var isSuppressed: Bool { AppDelegate.isHeadless }

    private static let lock = NSLock()
    private static var log: [String] = []

    /// The requests a headless run made, oldest first (bounded).
    static var requests: [String] { lock.withLock { log } }

    /// Records a request; returns true when it must not be performed.
    private static func suppressed(_ request: @autoclosure () -> String) -> Bool {
        guard isSuppressed else { return false }
        let text = request()
        lock.withLock {
            log.append(text)
            if log.count > 200 { log.removeFirst(log.count - 200) }
        }
        return true
    }

    // MARK: Files, folders, web and settings addresses

    /// Opens a file, a folder in Finder, or an address (web, `x-apple.systempreferences:`, `smb:`).
    @discardableResult
    static func open(_ url: URL) -> Bool {
        if suppressed("open \(url.isFileURL ? url.path : url.absoluteString)") { return true }
        return NSWorkspace.shared.open(url)
    }

    /// Opens a file in its default app and reports that app (nil in headless runs or on failure).
    static func open(_ url: URL, completion: @escaping (NSRunningApplication?, Error?) -> Void) {
        if suppressed("open \(url.path)") {
            completion(nil, nil)
            return
        }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: completion)
    }

    /// Opens files with a chosen app ("Open with").
    static func open(_ urls: [URL], withApplicationAt app: URL,
                     configuration: NSWorkspace.OpenConfiguration = NSWorkspace.OpenConfiguration(),
                     completion: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        if suppressed("open \(urls.map(\.path).joined(separator: ", ")) with \(app.deletingPathExtension().lastPathComponent)") {
            completion?(nil, nil)
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration, completionHandler: completion)
    }

    /// Launches an app (Disk Utility, Time Machine).
    static func openApplication(at app: URL, configuration: NSWorkspace.OpenConfiguration = NSWorkspace.OpenConfiguration(),
                                completion: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        if suppressed("launch \(app.deletingPathExtension().lastPathComponent)") {
            completion?(nil, nil)
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: completion)
    }

    /// Launches a Mac tool by its identifier. Returns false if it isn't installed.
    static func openApplication(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        openApplication(at: app)
        return true
    }

    /// A Finder window with these items selected (Show in Finder).
    static func reveal(_ urls: [URL]) {
        if suppressed("reveal \(urls.map(\.path).joined(separator: ", "))") { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Terminal in `folder` (Open in Terminal). Returns false if Terminal isn't installed.
    @discardableResult
    static func openTerminal(at folder: URL) -> Bool {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
        if suppressed("Terminal at \(folder.path)") { return true }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    // MARK: Sharing

    /// The system share picker next to `view`.
    static func showSharePicker(_ items: [Any], relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        if suppressed("share \(describe(items))") { return }
        NSSharingServicePicker(items: items).show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    /// A sharing service such as Mail's compose window.
    static func perform(_ service: NSSharingService, items: [Any]) {
        if suppressed("\(service.title): \(describe(items))") { return }
        service.perform(withItems: items)
    }

    // MARK: System settings Arbor can change

    /// The desktop picture of `screen`.
    static func setDesktopImage(_ url: URL, for screen: NSScreen) throws {
        if suppressed("desktop picture \(url.path)") { return }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
    }

    /// The default app for a type ("Change…" in Properties, "Always use this app").
    static func setDefaultApplication(at app: URL, toOpen type: UTType, completion: @escaping (Error?) -> Void) {
        if suppressed("default app for \(type.identifier): \(app.deletingPathExtension().lastPathComponent)") { completion(nil); return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type, completion: completion)
    }

    /// The default app for one file.
    static func setDefaultApplication(at app: URL, toOpenFileAt url: URL, completion: @escaping (Error?) -> Void) {
        if suppressed("default app for \(url.path): \(app.deletingPathExtension().lastPathComponent)") { completion(nil); return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: url, completion: completion)
    }

    /// Whether system services may show their own dialogs (network sign-in). Never headless.
    static var allowsSystemDialogs: Bool { !suppressed("system dialogs refused") }

    // MARK: Disks

    /// Eject (and unmount) a volume.
    static func eject(_ url: URL) throws {
        if suppressed("eject \(url.path)") { return }
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }

    /// Headless runs attach without a Finder window or sidebar entry.
    static func attachArguments(for image: URL) -> [String] {
        suppressed("attach \(image.path) (no Finder window)") ? ["-nobrowse", "-noautoopen"] : []
    }

    // MARK: Quick Look

    /// Shows Quick Look (headless runs log what it would preview).
    static func showQuickLook(_ panel: QLPreviewPanel, previewing urls: [URL]) {
        if suppressed("Quick Look \(urls.map(\.path).joined(separator: ", "))") { return }
        panel.makeKeyAndOrderFront(nil)
    }

    private static func describe(_ items: [Any]) -> String {
        items.map { item -> String in
            if let url = item as? URL { return url.isFileURL ? url.path : url.absoluteString }
            return String(describing: item)
        }.joined(separator: ", ")
    }
}
