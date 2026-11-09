import AppKit
import ArborCore

/// The tag list behind the navigation pane: system labels at once, custom tags after a Spotlight run. Main thread only.
final class FinderTagStore {
    static let shared = FinderTagStore()

    /// Past SpotlightSearch's own 20 s, for reading colours; a read stuck on a dead disk must not block refreshes forever.
    private static let discoveryDeadline: TimeInterval = 30

    private(set) lazy var catalog = TagCatalog(systemLabels: NSWorkspace.shared.fileLabels)
    /// Called when `catalog` or a label colour changed.
    var onChange: (() -> Void)?

    private var discovery: FinderTagDiscovery?
    private var deadline: DispatchWorkItem?
    private var lastRunUptime: TimeInterval?
    /// Discoveries started; scripted runs prove it stays 0 headless.
    private(set) var runCount = 0
    /// Counted before the headless guard, so scripted runs can prove expanding the row still asks for a refresh.
    private(set) var refreshRequests = 0
    /// Times `onChange` fired, for scripted checks.
    private(set) var changeCount = 0

    /// Converted here so every row's icon lookup is cheap; replaced when the labels change.
    private lazy var labelColors = Self.systemLabelColors

    /// Headless runs never read the real index, so results don't depend on this Mac's tags.
    func refreshIfStale() {
        refreshRequests += 1
        guard !AppDelegate.isHeadless else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard TagRefreshPolicy.mayStart(isRunning: discovery != nil, lastStart: lastRunUptime, now: now) else { return }
        let started = FinderTagDiscovery(seed: catalog.systemOnly) { [weak self] job, result, isComplete in
            self?.finish(job, result, isComplete: isComplete)
        }
        guard let started else { return }
        lastRunUptime = now
        runCount += 1
        discovery = started
        let timeout = DispatchWorkItem { [weak self] in self?.cancelDiscovery() }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.discoveryDeadline, execute: timeout)
        started.start()
    }

    /// SpotlightSearch doesn't report after a cancel, so the slot is cleared here.
    func cancelDiscovery() {
        discovery?.cancel()
        discovery = nil
        deadline?.cancel()
        deadline = nil
    }

    func labelsChanged() {
        cancelDiscovery()
        lastRunUptime = nil
        updateLabels(names: NSWorkspace.shared.fileLabels, colors: Self.systemLabelColors)
    }

    func updateLabels(names: [String], colors: [UInt32?]) {
        apply(catalog.rebased(onSystemLabels: names), colors: colors)
    }

    /// Replaces the list without a discovery (script steps).
    func setCatalog(_ newCatalog: TagCatalog) { apply(newCatalog) }

    func colorHex(of tag: FinderTag) -> UInt32? {
        guard tag.colorIndex > 0, labelColors.indices.contains(tag.colorIndex) else { return nil }
        return labelColors[tag.colorIndex]
    }

    private func finish(_ job: FinderTagDiscovery, _ result: TagCatalog, isComplete: Bool) {
        guard discovery === job else { return }
        discovery = nil
        deadline?.cancel()
        deadline = nil
        apply(isComplete ? result : catalog.merging(result))   // a failed run must not shrink the list
    }

    /// A colour-only change leaves the catalog equal, so the colours are compared too.
    private func apply(_ newCatalog: TagCatalog, colors: [UInt32?]? = nil) {
        let newColors = colors ?? labelColors
        guard newCatalog != catalog || newColors != labelColors else { return }
        catalog = newCatalog
        labelColors = newColors
        changeCount += 1
        onChange?()
    }

    private static var systemLabelColors: [UInt32?] { NSWorkspace.shared.fileLabelColors.map(hex) }

    private static func hex(_ color: NSColor) -> UInt32? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, Int(checked: Double(value) * 255 + 0.5) ?? 0))) }
        return byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
    }
}
