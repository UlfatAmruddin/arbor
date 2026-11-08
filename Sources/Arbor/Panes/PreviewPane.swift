import AppKit
import Quartz
import ArborCore

// MARK: - Preview pane

/// Read-only preview of the single selected file (FE-147); never launches an editor.
/// The Quick Look view is torn down when hidden to free memory.
final class PreviewPane: NSView, SidePaneProvider {
    var view: NSView { self }

    func update(selection: [FileItem], location: Location?) { show(selection) }

    private var quickLook: QLPreviewView?
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private var shownURL: URL?
    private var pending: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(L10n.tr("Preview pane"))
        placeholder.alignment = .center
        placeholder.textColor = Theme.secondaryText
        placeholder.font = Theme.bodyFont
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        placeholder.stringValue = L10n.tr("Select a file to preview.")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.intersection(dirtyRect).fill(using: .sourceOver)
    }

    /// Debounced so arrowing quickly through a folder doesn't decode every file.
    func show(_ items: [FileItem]) {
        pending?.cancel()
        guard !isHidden else { return }
        let work = DispatchWorkItem { [weak self] in self?.apply(items) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func apply(_ items: [FileItem]) {
        guard items.count == 1, let item = items.first, !item.isFolder else {
            showPlaceholder(items.isEmpty ? "Select a file to preview."
                            : items.count == 1 ? "No preview for folders."
                            : "\(items.count) items selected")
            return
        }
        guard PreviewPolicy.showsPreviewHandlers.value() else {
            showPlaceholder(L10n.tr("No preview available.\nPreviews are turned off in Folder Options (Show preview handlers in preview pane)."))
            return
        }
        if let values = try? item.url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            showPlaceholder(L10n.tr("This file is stored in iCloud and isn't downloaded. Open it to download it."))
            return
        }
        guard shownURL != item.url else { return }
        if quickLook == nil, let view = QLPreviewView(frame: bounds, style: .normal) {
            view.autostarts = false
            view.shouldCloseWithWindow = true
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            quickLook = view
        }
        quickLook?.isHidden = false
        quickLook?.previewItem = item.url as NSURL
        placeholder.isHidden = true
        shownURL = item.url
    }

    private func showPlaceholder(_ text: String) {
        quickLook?.previewItem = nil
        quickLook?.isHidden = true
        shownURL = nil
        placeholder.stringValue = text
        placeholder.isHidden = false
    }

    func releaseResources() {
        pending?.cancel()
        quickLook?.close()
        quickLook?.removeFromSuperview()
        quickLook = nil
        shownURL = nil
        placeholder.isHidden = false
    }
}
