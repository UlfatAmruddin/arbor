import AppKit
import ArborCore

/// "Not available yet" page for unbuilt features (DEC-019: honest boundary, no fake page).
final class PlaceholderProvider: LocationProvider {
    private let accepts: (Location) -> Bool
    init(locations: @escaping (Location) -> Bool) { accepts = locations }

    func handles(_ location: Location) -> Bool { accepts(location) }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        completion(.success(.custom(PlaceholderPageController(location: location))))
        return nil
    }

    func allowsItemEditing(in location: Location) -> Bool { false }
    func targetFolder(for location: Location) -> URL? { nil }
    func limitation(of action: LocationAction, in location: Location) -> String? { action.notAFolderLimitation() }
}

final class PlaceholderPageController: NSViewController, LocationPageStatus {
    let location: Location
    init(location: Location) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var statusSummary: String { "" }

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        let icon = NSImageView(image: IconProvider.shared.icon(for: location, size: 48))
        let title = NSTextField(labelWithString: L10n.format("%@ isn't available yet", "\(location.displayName)"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.primaryText
        let detail = NSTextField(wrappingLabelWithString: L10n.tr("This part of Arbor hasn't been built yet. It's tracked in docs/FEATURE-STATUS.md."))
        detail.font = Theme.bodyFont
        detail.textColor = Theme.secondaryText
        detail.alignment = .center
        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -30),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        root.setAccessibilityLabel(L10n.format("%@ isn't available yet", "\(location.displayName)"))
        view = root
    }
}

// MARK: - Home (placeholder)

/// Basic Home: Quick access tiles. The Home feature replaces it.
final class HomeProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .home }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        completion(.success(.custom(HomePageController(host: context.host))))
        return nil
    }

    func allowsItemEditing(in location: Location) -> Bool { false }
    func limitation(of action: LocationAction, in location: Location) -> String? { action.notAFolderLimitation() }
}

final class HomePageController: NSViewController, LocationPageStatus {
    weak var host: LocationHost?
    private var observer: NSObjectProtocol?
    private let grid = NSStackView()

    init(host: LocationHost?) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var statusSummary: String { StatusText.items(QuickAccess.urls.count) + "  |" }

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false

        let header = sectionHeader(L10n.tr("Quick access"))
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        let recent = sectionHeader(L10n.tr("Recent"))
        let recentNote = NSTextField(labelWithString: L10n.tr("Recent files appear here."))
        recentNote.font = Theme.bodyFont
        recentNote.textColor = Theme.secondaryText

        let stack = NSStackView(views: [header, grid, recent, recentNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(24, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = root
        rebuildTiles()
        observer = NotificationCenter.default.addObserver(forName: QuickAccess.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildTiles()
        }
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = Theme.primaryText
        return label
    }

    private func rebuildTiles() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = QuickAccess.urls
        let perRow = 4
        for start in stride(from: 0, to: urls.count, by: perRow) {
            let row = NSStackView(views: urls[start..<min(start + perRow, urls.count)].map(tile))
            row.orientation = .horizontal
            row.spacing = 4
            grid.addArrangedSubview(row)
        }
    }

    private func tile(_ url: URL) -> NSView {
        let tile = TileButton(icon: IconProvider.shared.folderIcon(IconProvider.shared.folderKind(for: url), size: 40),
                              title: displayName(of: url), subtitle: QuickAccess.isPinned(url) ? L10n.tr("Pinned") : "")
        tile.toolTip = url.path
        tile.onClick = { [weak self] in self?.host?.navigate(to: .folder(url), select: []) }
        tile.onMiddleClick = { [weak self] in self?.host?.openInNewTab(.folder(url)) }
        return tile
    }
}

/// Home tile: large icon, name, caption; Explorer-style hover and press.
final class TileButton: NSView {
    var onClick: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(icon: NSImage, title: String, subtitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView(image: icon)
        image.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: title)
        name.font = Theme.bodyFont
        name.textColor = Theme.primaryText
        name.lineBreakMode = .byTruncatingTail
        let caption = NSTextField(labelWithString: subtitle)
        caption.font = Theme.statusFont
        caption.textColor = Theme.secondaryText
        let text = NSStackView(views: [name, caption])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [image, text])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 220),
            heightAnchor.constraint(equalToConstant: 60),
            image.widthAnchor.constraint(equalToConstant: 40),
            image.heightAnchor.constraint(equalToConstant: 40),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovered { fillRounded(bounds, radius: 6, Theme.hover) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onMiddleClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - This Mac (placeholder)

/// Mounted volumes as plain items for the standard views; the This Mac feature replaces it.
final class ThisMacProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .thisMac }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.volumes()
            DispatchQueue.main.async { completion(.success(.items(items))) }
        }
        return nil
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        VolumeWatcher(onChange: onChange)
    }

    func allowsItemEditing(in location: Location) -> Bool { false }
    func limitation(of action: LocationAction, in location: Location) -> String? { action.notAFolderLimitation() }
    func emptyText(for location: Location) -> String { L10n.tr("No drives are connected.") }

    static func volumes() -> [FileItem] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let kind: String
            if v?.volumeIsLocal == false { kind = L10n.tr("Network drive") }
            else if v?.volumeIsInternal == false || v?.volumeIsRemovable == true { kind = L10n.tr("External disk") }
            else { kind = L10n.tr("Local disk") }
            let type = v?.volumeAvailableCapacity.map { L10n.format("%@ · %@ free", kind, StatusText.bytes(Int64($0))) } ?? kind
            return FileItem(url: url.standardizedFileURL, name: v?.volumeLocalizedName ?? displayName(of: url), isFolder: true,
                            size: v?.volumeTotalCapacity.map(Int64.init), typeDescription: type)
        }
    }
}

/// Calls back when a volume mounts, unmounts or is renamed.
final class VolumeWatcher {
    private var observers: [NSObjectProtocol] = []
    init(onChange: @escaping () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in onChange() })
        }
    }
    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
