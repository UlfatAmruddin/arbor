import AppKit
import ArborCore

/// Stops the Preview pane from downloading online-only files until "Download to preview" is clicked (FE-162).
final class CloudAwarePreviewPane: NSView, SidePaneProvider {
    var view: NSView { self }
    private let inner: SidePaneProvider
    private let gate = CloudPreviewGateView()
    private var selection: [FileItem] = []
    private var location: Location?
    private var observer: NSObjectProtocol?

    init(wrapping inner: SidePaneProvider) {
        self.inner = inner
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for v in [inner.view, gate] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        gate.isHidden = true
        gate.onReady = { [weak self] in self?.reevaluate() }
        observer = NotificationCenter.default.addObserver(forName: CloudStatusStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reevaluate()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.fill()
    }

    func update(selection: [FileItem], location: Location?) {
        let changed = selection.map(\.url) != self.selection.map(\.url)
        self.selection = selection
        self.location = location
        if changed { gate.reset() }
        reevaluate()
    }

    private func reevaluate() {
        if let item = selection.first, selection.count == 1, !item.isFolder, let root = CloudEnvironment.root(containing: item.url) {
            let status = CloudStatusStore.shared.status(for: item.url)
            if gate.isDownloading(item.url) || status == nil || status == .onlineOnly || status == .downloading {
                gate.show(item: item, root: root, status: status)
                gate.isHidden = false
                inner.view.isHidden = true
                inner.update(selection: [], location: location)   // release the previous preview
                return
            }
        }
        gate.isHidden = true
        inner.view.isHidden = false
        inner.update(selection: selection, location: location)
    }

    func releaseResources() {
        gate.reset()
        inner.releaseResources()
    }
}

/// "“Report.pdf” is available when online · Download to preview".
final class CloudPreviewGateView: ThemeBackgroundView {
    var onReady: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: L10n.tr("Download to preview"), target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var item: FileItem?
    private var root: CloudRoot?
    private var downloadingURL: URL?
    private var poll: Timer?
    private var started = Date()

    init() {
        super.init(Theme.contentBackground)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = Theme.primaryText
        title.alignment = .center
        detail.font = Theme.bodyFont
        detail.textColor = Theme.secondaryText
        detail.alignment = .center
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(download)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = NSStackView(views: [icon, title, detail, button, spinner])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 40),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        setAccessibilityLabel(L10n.tr("Preview"))
    }

    required init?(coder: NSCoder) { fatalError() }

    func isDownloading(_ url: URL) -> Bool { downloadingURL == url }

    func reset() {
        poll?.invalidate()
        poll = nil
        downloadingURL = nil
        spinner.stopAnimation(nil)
    }

    func show(item: FileItem, root: CloudRoot, status: CloudStatus?) {
        self.item = item
        self.root = root
        if downloadingURL == item.url { return }
        icon.image = CloudGlyph.image(status ?? .unknown, size: 40)
        switch status {
        case nil:
            title.stringValue = L10n.format("Checking “%@”…", "\(item.name)")
            detail.stringValue = L10n.tr("Arbor checks whether the file is on this Mac before previewing it.")
            button.isHidden = true
        case .downloading?:
            title.stringValue = L10n.format("“%@” is downloading", "\(item.name)")
            detail.stringValue = L10n.format("The preview appears when %@ finishes downloading it.", "\(root.provider)")
            button.isHidden = true
        default:
            title.stringValue = L10n.format("“%@” is available when online", "\(item.name)")
            detail.stringValue = L10n.format("Previewing it downloads the file from %@ to this Mac.", "\(root.displayName)")
            button.isHidden = false
        }
    }

    @objc private func download() {
        guard let item, let root else { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: item.url)
        } catch {
            icon.image = CloudGlyph.image(.error(""), size: 40)
            title.stringValue = L10n.format("“%@” couldn't be downloaded", "\(item.name)")
            detail.stringValue = L10n.format("%@ reported: %@", "\(root.displayName)", "\(error.localizedDescription)")
            button.isHidden = true
            return
        }
        downloadingURL = item.url
        started = Date()
        icon.image = CloudGlyph.image(.downloading, size: 40)
        title.stringValue = L10n.format("Downloading “%@”…", "\(item.name)")
        detail.stringValue = L10n.tr("Selecting another item stops waiting here; macOS may still finish the download.")
        button.isHidden = true
        spinner.startAnimation(nil)
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        guard let url = downloadingURL else { return }
        CloudStatusStore.shared.read([url]) { [weak self] statuses in
            guard let self, self.downloadingURL == url, let status = statuses.first else { return }
            switch status {
            case .availableOnDevice, .uploading, .syncPending:
                self.reset()
                CloudStatusStore.shared.invalidate([url])
                self.onReady?()
            case .error(let message):
                self.reset()
                self.title.stringValue = L10n.format("“%@” couldn't be downloaded", "\(url.lastPathComponent)")
                self.detail.stringValue = message
                self.icon.image = CloudGlyph.image(status, size: 40)
            default:
                if Date().timeIntervalSince(self.started) > 300 {
                    self.reset()
                    self.title.stringValue = L10n.format("Still downloading “%@”", "\(url.lastPathComponent)")
                    self.detail.stringValue = L10n.tr("Select the file again later to preview it.")
                }
            }
        }
    }
}
