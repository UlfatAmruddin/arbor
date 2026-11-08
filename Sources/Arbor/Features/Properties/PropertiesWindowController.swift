import AppKit
import ArborCore

/// One tab of a Properties window.
protocol PropertiesTab: AnyObject {
    var title: String { get }
    var view: NSView { get }
    /// The model changed (edit, apply, external change): refresh what's shown.
    func reload()
    /// The window is closing: cancel background work (size scans, signature checks).
    func close()
}

extension PropertiesTab {
    func close() {}
}

/// A non-modal Properties window for one selection, with Windows' tabs and OK / Cancel / Apply
/// (FE-099). Opening Properties again for the same items brings the existing window forward.
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: PropertiesWindowController] = [:]
    static var all: [PropertiesWindowController] { Array(open.values) }

    let model: PropertiesModel
    private(set) var tabs: [PropertiesTab] = []
    private let tabBar = SheetTabBar()
    private let panel = SheetPanel()
    private(set) var selectedTab = 0
    private let ok = SheetButton(L10n.tr("OK"), isDefault: true)
    private let cancel = SheetButton(L10n.tr("Cancel"))
    private let applyButton = SheetButton(L10n.tr("Apply"))
    private let key: String

    static func show(_ items: [FileItem], relativeTo parent: NSWindow?) {
        guard !items.isEmpty else { return }
        let key = items.map { Location.normalizedKey($0.url) }.sorted().joined(separator: "\n")
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PropertiesWindowController(items: items, key: key)
        open[key] = controller
        controller.place(relativeTo: parent)
        controller.showWindow(nil)
        if AppDelegate.isHeadless {
            controller.window?.alphaValue = 0
            controller.window?.ignoresMouseEvents = true
        }
    }

    /// The Properties window in front (for scripts): key window first, then the newest.
    static var front: PropertiesWindowController? {
        (NSApp.keyWindow?.windowController as? PropertiesWindowController) ?? lastShown
    }
    private static weak var lastShown: PropertiesWindowController?

    private init(items: [FileItem], key: String) {
        self.key = key
        model = PropertiesModel(items: items)
        let window = PropertiesWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = SheetColors.windowBackground
        super.init(window: window)
        window.delegate = self
        Self.lastShown = self
        tabs = PropertiesTabs.make(for: model, controller: self)
        buildLayout()
        updateTitle()
        model.observers.append { [weak self] in self?.modelChanged() }
        select(0)
        modelChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func place(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if let parent {
            let offset = CGFloat(Self.open.count - 1) * 22
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - window.frame.width / 2 + offset,
                                                y: parent.frame.maxY - 80 - offset))
        } else {
            window.center()
        }
    }

    private func buildLayout() {
        guard let window else { return }
        let content = ThemeBackgroundView(SheetColors.windowBackground)
        content.translatesAutoresizingMaskIntoConstraints = true
        tabBar.titles = tabs.map(\.title)
        tabBar.onSelect = { [weak self] i in self?.select(i) }
        ok.onClick = { [weak self] _ in self?.okPressed() }
        cancel.onClick = { [weak self] _ in self?.close() }
        applyButton.onClick = { [weak self] _ in self?.applyPressed() }
        let buttons = hstack([ok, cancel, applyButton], spacing: 8)
        for v in [tabBar, panel, buttons] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            tabBar.heightAnchor.constraint(equalToConstant: 24),
            panel.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            panel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        panel.subviews.forEach { $0.removeFromSuperview() }
        selectedTab = index
        tabBar.selectedIndex = index
        let v = tabs[index].view
        v.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: panel.topAnchor, constant: 1),
            v.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 1),
            v.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -1),
            v.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -1),
        ])
        tabs[index].reload()
    }

    func select(title: String) -> Bool {
        guard let i = tabs.firstIndex(where: { $0.title.lowercased() == title.lowercased() }) else { return false }
        select(i)
        return true
    }

    private func modelChanged() {
        applyButton.isEnabled = model.hasChanges
        updateTitle()
        tabs.forEach { $0.reload() }
    }

    private func updateTitle() {
        let name: String
        if let single = model.single {
            name = model.subject == .volume ? (VolumeInfo.read(single.url)?.name ?? single.item.name) : single.url.lastPathComponent
        } else {
            name = model.entries.first.map { $0.url.lastPathComponent + ", …" } ?? ""
        }
        window?.title = L10n.format("%@ Properties", "\(name)")
    }

    // MARK: Buttons

    func okPressed() {
        guard window?.attachedSheet == nil else { return }
        window?.makeFirstResponder(nil)   // commit an edit in progress
        guard model.hasChanges else { close(); return }
        model.apply(in: window) { [weak self] ok in if ok { self?.close() } }
    }

    func applyPressed() {
        guard window?.attachedSheet == nil else { return }
        window?.makeFirstResponder(nil)
        model.apply(in: window) { _ in }
    }

    override func close() {
        tabs.forEach { $0.close() }
        Self.open.removeValue(forKey: key)
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        tabs.forEach { $0.close() }
        Self.open.removeValue(forKey: key)
    }

    /// Another app may have changed the item while this window was in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshFromDisk()
    }

    // MARK: Keys (Return = OK, Escape = Cancel, ⌃Tab = next tab)

    override func cancelOperation(_ sender: Any?) { close() }

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, mods.contains(.control) {
            let step = mods.contains(.shift) ? -1 : 1
            select((selectedTab + step + tabs.count) % tabs.count)
            return true
        }
        if event.keyCode == 13, mods == .command { close(); return true }   // ⌘W
        return false
    }

    // MARK: Alerts

    /// Shows an alert as a sheet on `window` (or app-modal without one). Sheets keep scripted runs
    /// going (`propbutton:` answers them); headless runs keep them invisible.
    static func present(_ alert: NSAlert, window: NSWindow?, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        AlertSheets.present(alert, in: window, completion: completion)
    }

    static func present(message: String, info: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        present(alert, window: window)
    }

    // MARK: Scripting

    var debugText: String {
        var lines = ["properties: \(window?.title ?? "")", "tabs: \(tabs.map(\.title).joined(separator: " | "))  selected: \(tabs[selectedTab].title)",
                     "apply enabled: \(applyButton.isEnabled)"]
        if let tab = tabs[selectedTab] as? PropertiesTabDebug { lines.append(tab.debugText) }
        return lines.joined(separator: "\n")
    }

    func snapshot(to path: String) {
        guard let frameView = window?.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Tabs that report their visible values for `proplog:`.
protocol PropertiesTabDebug {
    var debugText: String { get }
}

/// Return = OK, Escape = Cancel, ⌃Tab / ⌃⇧Tab = next / previous tab, like a Windows property sheet.
final class PropertiesWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let controller = windowController as? PropertiesWindowController else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (event.keyCode == 36 || event.keyCode == 76), mods.isEmpty, !(firstResponder is NSTextView && (firstResponder as? NSTextView)?.isFieldEditor == false) {
            controller.okPressed()
            return true
        }
        if event.keyCode == 53, mods.isEmpty {
            controller.close()
            return true
        }
        if controller.handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.control),
           (windowController as? PropertiesWindowController)?.handleKey(event) == true { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { (windowController as? PropertiesWindowController)?.close() }
}
