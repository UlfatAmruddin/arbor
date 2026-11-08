import AppKit
import ArborCore

/// A right-hand pane (B6): Preview, Details, or a feature's own. At most one is shown (Explorer's
/// Preview and Details panes are mutually exclusive). The pane is created when shown and
/// released when hidden, so a hidden pane holds no previews in memory.
protocol SidePaneProvider: AnyObject {
    var view: NSView { get }
    /// Called when the selection or location changes while the pane is visible.
    func update(selection: [FileItem], location: Location?)
    /// Free decoded previews etc. Called before the pane is removed.
    func releaseResources()
}

struct SidePaneDescriptor {
    let id: String
    let title: String
    let make: () -> SidePaneProvider
}

/// Register panes by id; `Prefs.sidePane` holds the visible one ("" = none).
///
///     SidePaneRegistry.register(SidePaneDescriptor(id: "details", title: "Details pane") { PropertiesPane() })
enum SidePaneRegistry {
    private static var descriptors: [String: SidePaneDescriptor] = [:]
    /// Registering an id that exists replaces that pane (a feature upgrades the core Details pane).
    static func register(_ descriptor: SidePaneDescriptor) { descriptors[descriptor.id] = descriptor }
    static func descriptor(_ id: String) -> SidePaneDescriptor? { descriptors[id] }
    static var ids: [String] { descriptors.keys.sorted() }

    /// Wraps a pane when it is created (the cloud download gate and archive member previews wrap "preview").
    static let wrappers = Pipeline<SidePaneProvider, String>(
        "SidePaneRegistry.wrappers", "Wraps a side pane when it is created (by pane id).", signature: "(pane, id) -> pane")

    static func make(_ descriptor: SidePaneDescriptor) -> SidePaneProvider {
        wrappers.apply(descriptor.make(), descriptor.id)
    }
}

/// Hosts the visible side pane inside the window's split view.
final class SidePaneContainer: NSView {
    private(set) var currentID = ""
    private(set) var provider: SidePaneProvider?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.intersection(dirtyRect).fill(using: .sourceOver)
    }

    /// Shows the pane with `id` ("" hides). Returns whether anything is visible.
    @discardableResult
    func show(_ id: String, selection: [FileItem], location: Location?) -> Bool {
        if id == currentID, provider != nil || id.isEmpty {
            provider?.update(selection: selection, location: location)
            return provider != nil
        }
        provider?.releaseResources()
        provider?.view.removeFromSuperview()
        provider = nil
        currentID = ""
        guard !id.isEmpty, let descriptor = SidePaneRegistry.descriptor(id) else { return false }
        let pane = SidePaneRegistry.make(descriptor)
        let v = pane.view
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        provider = pane
        currentID = id
        setAccessibilityLabel(descriptor.title)
        pane.update(selection: selection, location: location)
        return true
    }

    func update(selection: [FileItem], location: Location?) {
        provider?.update(selection: selection, location: location)
    }

    func releaseAll() { show("", selection: [], location: nil) }
}

/// Basic Details pane: icon, name, type, size and dates of the selection.
/// The Properties feature replaces it by registering its own "details" pane.
final class DetailsPane: NSView, SidePaneProvider {
    var view: NSView { self }
    private let icon = NSImageView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel(L10n.tr("Details pane"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = Theme.primaryText
        info.font = Theme.bodyFont
        info.textColor = Theme.secondaryText
        let stack = NSStackView(views: [icon, name, info])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            info.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.intersection(dirtyRect).fill(using: .sourceOver)
    }

    func update(selection: [FileItem], location: Location?) {
        if selection.count == 1, let item = selection.first {
            icon.image = item.isFolder ? IconProvider.shared.icon(for: item, size: 64) : IconProvider.shared.fileIcon(item.url, size: 64)
            name.stringValue = item.name
            var lines = [L10n.format("Type: %@", "\(item.typeDescription)")]
            if let size = item.size { lines.append(L10n.format("Size: %@", "\(StatusText.bytes(size))")) }
            if let modified = item.modified { lines.append(L10n.format("Date modified: %@", "\(dates.string(from: modified))")) }
            if let created = try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate {
                lines.append(L10n.format("Date created: %@", "\(dates.string(from: created))"))
            }
            lines.append(L10n.format("Location: %@", "\(item.url.deletingLastPathComponent().path)"))
            info.stringValue = lines.joined(separator: "\n")
        } else if selection.count > 1 {
            icon.image = IconProvider.shared.folderIcon(size: 64)
            name.stringValue = L10n.format("%@ items selected", "\(selection.count)")
            let sizes = selection.compactMap(\.size)
            info.stringValue = sizes.count == selection.count ? L10n.format("Total size: %@", "\(StatusText.bytes(sizes.reduce(0, +)))") : ""
        } else if let location {
            icon.image = IconProvider.shared.icon(for: location, size: 64)
            name.stringValue = LocationRegistry.provider(for: location).title(for: location)
            info.stringValue = L10n.tr("Select a single file to see more details.")
        } else {
            icon.image = nil
            name.stringValue = ""
            info.stringValue = ""
        }
    }

    func releaseResources() {}
}
