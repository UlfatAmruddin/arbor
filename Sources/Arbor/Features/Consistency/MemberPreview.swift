import AppKit
import Quartz
import ArborCore

/// Quick Look (Space) and the Preview pane for files inside archives: the member is extracted on
/// demand to a read-only temporary copy (the same safe extraction as Open), at most `sizeLimit`
/// bytes and one member at a time, and kept in a small cache so arrowing back is instant.
enum MemberPreview {
    static let sizeLimit: Int64 = 64 * 1024 * 1024
    static let cacheLimit = 12

    enum State: Equatable {
        case notMember
        case ready(URL)
        case preparing
        case tooLarge
        case encrypted
        case failed(String)
    }

    private static var prepared: [String: URL] = [:]
    private static var order: [String] = []
    private static var failures: [String: State] = [:]
    private static var inFlight: String?
    private static var queued: (key: String, ref: ArchiveItemRef)?

    static func register() {
        PreviewHooks.localURL.register("consistency.archive-member-preview") { item in
            if case .ready(let url) = state(for: item) { return url }
            return nil
        }
        // Outside the cloud gate (cloud.preview-gate): a member is prepared before anything else looks at it.
        SidePaneRegistry.wrappers.add("consistency.archive-member-preview", order: .late) { pane, id in
            id == "preview" ? MemberAwarePreviewPane(wrapping: pane) : pane
        }
        NotificationCenter.default.addObserver(forName: PreviewHooks.ready, object: nil, queue: .main) { _ in
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible { panel.reloadData() }
        }
    }

    private static func key(_ ref: ArchiveItemRef) -> String {
        (ArchiveCatalog.stamp(of: ref.archive) ?? "?") + "|" + ref.archive.path + "|" + ref.innerPath
    }

    /// What can be previewed for `item`; starts preparing a copy when needed.
    static func state(for item: FileItem) -> State {
        guard !item.isFolder, let ref = ArchiveCatalog.ref(for: item.url) else { return .notMember }
        let key = key(ref)
        if let url = prepared[key] {
            if FileManager.default.fileExists(atPath: url.path) { return .ready(url) }
            prepared[key] = nil
        }
        if let failure = failures[key] { return failure }
        if let entry = ArchiveCatalog.shared.entry(for: item)?.node?.entry {
            if entry.isEncrypted { return .encrypted }
            if let size = entry.size, size > sizeLimit { return .tooLarge }
        }
        prepare(ref, key: key)
        return .preparing
    }

    private static func prepare(_ ref: ArchiveItemRef, key: String) {
        guard inFlight != key else { return }
        guard inFlight == nil else { queued = (key, ref); return }   // only the latest waits
        guard let folder = try? ArchiveJobs.freshSessionFolder() else { failures[key] = .failed("No temporary folder."); return }
        inFlight = key
        let request = ArchiveJobs.ExtractRequest(archive: ref.archive, roots: [ref.innerPath], base: ref.parentPath,
                                                 destination: folder, verb: "Preparing a preview of “\(ref.name)”")
        ArchiveJobs.extract(request, window: nil) { result in
            inFlight = nil
            switch result {
            case .success(let outcome):
                if let url = outcome.placed.first {
                    ArchiveFeature.makeReadOnly(url)
                    remember(url, key: key)
                } else {
                    failures[key] = .failed("Nothing could be extracted.")
                }
            case .failure(let error):
                failures[key] = (error as? ArchiveError) == .encrypted ? .encrypted : .failed(error.localizedDescription)
            }
            NotificationCenter.default.post(name: PreviewHooks.ready, object: nil)
            if let next = queued {
                queued = nil
                prepare(next.ref, key: next.key)
            }
        }
    }

    private static func remember(_ url: URL, key: String) {
        prepared[key] = url
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > cacheLimit {
            let old = order.removeFirst()
            if let gone = prepared.removeValue(forKey: old) { try? FileManager.default.removeItem(at: gone.deletingLastPathComponent()) }
        }
        if failures.count > 64 { failures.removeAll() }
    }

    static var debugLine: String {
        "member previews: prepared=\(prepared.count) inFlight=\(inFlight != nil) "
            + prepared.values.map(\.lastPathComponent).sorted().joined(separator: ",")
            + (failures.isEmpty ? "" : " failures=\(failures.values.map { "\($0)" }.joined(separator: "; "))")
    }
}

/// The registered Preview pane, given a temporary copy for archive members.
final class MemberAwarePreviewPane: NSView, SidePaneProvider {
    var view: NSView { self }
    private let inner: SidePaneProvider
    private let message = NSTextField(wrappingLabelWithString: "")
    private var selection: [FileItem] = []
    private var location: Location?
    private var observer: NSObjectProtocol?

    init(wrapping inner: SidePaneProvider) {
        self.inner = inner
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        inner.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner.view)
        message.alignment = .center
        message.textColor = Theme.secondaryText
        message.font = Theme.bodyFont
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        addSubview(message)
        NSLayoutConstraint.activate([
            inner.view.topAnchor.constraint(equalTo: topAnchor), inner.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            inner.view.leadingAnchor.constraint(equalTo: leadingAnchor), inner.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            message.centerXAnchor.constraint(equalTo: centerXAnchor), message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        observer = NotificationCenter.default.addObserver(forName: PreviewHooks.ready, object: nil, queue: .main) { [weak self] _ in
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
        self.selection = selection
        self.location = location
        reevaluate()
    }

    /// The text shown instead of a preview, for scripted checks.
    var messageText: String? { message.isHidden ? nil : message.stringValue }

    private func reevaluate() {
        guard selection.count == 1, let item = selection.first else { pass(selection); return }
        switch MemberPreview.state(for: item) {
        case .notMember: pass(selection)
        case .ready(let url):
            let copy = FileItem(url: url, name: item.name, isFolder: false, size: item.size, modified: item.modified,
                                typeDescription: item.typeDescription)
            pass([copy])
        case .preparing: show("Preparing a preview…")
        case .tooLarge: show("This file is too large to preview from inside the archive. Open it or extract it to see it.")
        case .encrypted: show("This file is password protected. Extract it to preview it.")
        case .failed(let why): show("No preview available.\n\(why)")
        }
    }

    private func pass(_ items: [FileItem]) {
        message.isHidden = true
        inner.view.isHidden = false
        inner.update(selection: items, location: location)
    }

    private func show(_ text: String) {
        inner.update(selection: [], location: location)
        inner.view.isHidden = true
        message.stringValue = text
        message.isHidden = false
    }

    func releaseResources() { inner.releaseResources() }
}
