import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ArborCore

/// Windows 11's Details pane (FE-148): large thumbnail, name and type, then a property list that
/// follows the selection. Metadata and thumbnails load off the main thread; a newer selection cancels
/// older work, and late results are dropped. Finder tags and comments can be edited and saved here.
final class DetailsSidePane: NSView, SidePaneProvider {
    var view: NSView { self }

    private let scroll = NSScrollView()
    private let content = SheetPage()
    private let thumbnail = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let propertiesHeader = NSTextField(labelWithString: L10n.tr("Properties"))
    private let grid = NSStackView()
    private let editHeader = NSTextField(labelWithString: L10n.tr("Finder tags and comments"))
    private let tagsField = SheetTextField(placeholder: L10n.tr("Add a tag"))
    private let commentField = SheetTextField(placeholder: L10n.tr("Add comments"))
    private lazy var saveButton = SheetButton(L10n.tr("Save"), isDefault: true) { [weak self] _ in self?.saveEdits() }
    private lazy var cancelButton = SheetButton(L10n.tr("Cancel")) { [weak self] _ in self?.cancelEdits() }
    private let editButtons = NSStackView()
    private let editBox = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")

    private var generation = 0
    private var pending: DispatchWorkItem?
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var shownItems: [FileItem] = []
    private var editURL: URL?
    private var editOriginal: EditableState?
    private(set) var rows: [(String, String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(L10n.tr("Details pane"))
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.intersection(dirtyRect).fill(using: .sourceOver)
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        addSubview(scroll)

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.setAccessibleName(L10n.tr("Thumbnail"))
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = Theme.primaryText
        nameLabel.alignment = .left
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byCharWrapping
        typeLabel.font = Theme.bodyFont
        typeLabel.textColor = Theme.secondaryText
        propertiesHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        propertiesHeader.textColor = Theme.primaryText
        editHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        editHeader.textColor = Theme.primaryText
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8
        message.font = Theme.bodyFont
        message.textColor = Theme.secondaryText

        tagsField.onChange = { [weak self] _ in self?.editsChanged() }
        commentField.onChange = { [weak self] _ in self?.editsChanged() }
        editButtons.orientation = .horizontal
        editButtons.spacing = 8
        editButtons.addArrangedSubview(saveButton)
        editButtons.addArrangedSubview(cancelButton)
        editBox.orientation = .vertical
        editBox.alignment = .leading
        editBox.spacing = 6
        for (label, field) in [(L10n.tr("Tags"), tagsField), (L10n.tr("Comments"), commentField)] {
            // Property names wrap onto a second line rather than being cut off (longer translations).
            let l = NSTextField(wrappingLabelWithString: label)
            l.maximumNumberOfLines = 2
            l.preferredMaxLayoutWidth = 100
            l.font = Theme.bodyFont
            l.textColor = Theme.secondaryText
            editBox.addArrangedSubview(l)
            editBox.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: editBox.widthAnchor).isActive = true
        }
        editBox.addArrangedSubview(editButtons)

        let stack = NSStackView(views: [thumbnail, nameLabel, typeLabel, propertiesHeader, grid, editHeader, editBox, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: thumbnail)
        stack.setCustomSpacing(18, after: typeLabel)
        stack.setCustomSpacing(10, after: propertiesHeader)
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(10, after: editHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            thumbnail.heightAnchor.constraint(equalToConstant: 150),
            thumbnail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: SidePaneProvider

    func update(selection: [FileItem], location: Location?) {
        pending?.cancel()
        // Coalesce fast arrowing; the header updates at once so the pane never shows the wrong name.
        let work = DispatchWorkItem { [weak self] in self?.show(selection, location: location) }
        pending = work
        showHeaderImmediately(selection, location: location)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func releaseResources() {
        pending?.cancel()
        cancelThumbnail()
        generation += 1
        thumbnail.image = nil
    }

    private func cancelThumbnail() {
        if let request = thumbnailRequest { QLThumbnailGenerator.shared.cancel(request) }
        thumbnailRequest = nil
    }

    private func showHeaderImmediately(_ items: [FileItem], location: Location?) {
        if items.count == 1 { nameLabel.stringValue = items[0].name; typeLabel.stringValue = items[0].typeDescription }
        else if items.count > 1 { nameLabel.stringValue = SelectionSummary(items: items).selectedText }
    }

    private func show(_ items: [FileItem], location: Location?) {
        generation += 1
        let token = generation
        cancelThumbnail()
        shownItems = items
        message.isHidden = true
        if items.count == 1 {
            let item = items[0]
            nameLabel.stringValue = item.name
            typeLabel.stringValue = item.typeDescription
            thumbnail.image = item.isFolder ? IconProvider.shared.icon(for: item, size: 128) : IconProvider.shared.fileIcon(item.url, size: 128)
            requestThumbnail(item, token: token)
            setRows([("Size", item.size.map(PropertyFormat.adaptiveSize) ?? (item.isFolder ? "" : "Unknown")),
                     ("Date modified", item.modified.map { PropertyFormat.shortDate($0) } ?? "")].filter { !$0.1.isEmpty })
            prepareEditing(item)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let rows = Self.singleRows(item)
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.setRows(rows)
                }
            }
        } else if items.count > 1 {
            let summary = SelectionSummary(items: items)
            nameLabel.stringValue = summary.selectedText
            typeLabel.stringValue = summary.typeText
            thumbnail.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 64, weight: .light))
            thumbnail.contentTintColor = Theme.iconTint
            var rows: [(String, String)] = []
            if summary.files > 0 {
                rows.append((summary.folders > 0 ? L10n.tr("Size (files)") : L10n.tr("Total size"), PropertyFormat.adaptiveSize(summary.knownFileSize)))
            }
            rows.append((L10n.tr("Items"), summary.countText))
            if let range = PropertyFormat.dateRange(summary.modifiedDates) { rows.append((L10n.tr("Date modified"), range)) }
            if !summary.locationText.isEmpty { rows.append((L10n.tr("Location"), summary.locationValue)) }
            setRows(rows)
            prepareEditing(nil)
        } else {
            thumbnail.contentTintColor = nil
            if let location {
                nameLabel.stringValue = LocationRegistry.provider(for: location).title(for: location)
                typeLabel.stringValue = location.folderURL == nil ? "" : "Folder"
                thumbnail.image = IconProvider.shared.icon(for: location, size: 128)
                setRows([])
                message.stringValue = L10n.tr("Select a file to see its details.")
                message.isHidden = false
                if let folder = location.folderURL {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let count = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count
                        let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                        DispatchQueue.main.async {
                            guard let self, token == self.generation else { return }
                            var rows: [(String, String)] = []
                            if let count { rows.append((L10n.tr("Items"), StatusText.items(count))) }
                            if let created { rows.append((L10n.tr("Date created"), PropertyFormat.shortDate(created))) }
                            rows.append((L10n.tr("Location"), folder.deletingLastPathComponent().path))
                            self.setRows(rows)
                        }
                    }
                }
            } else {
                nameLabel.stringValue = ""
                typeLabel.stringValue = ""
                thumbnail.image = nil
                setRows([])
            }
            prepareEditing(nil)
        }
        if items.count != 1 { thumbnail.contentTintColor = items.count > 1 ? Theme.iconTint : nil }
    }

    /// What the preview area shows now (scripted checks): "icon", "thumbnail" or "page", with the image size.
    private(set) var previewKind = "icon"

    private func requestThumbnail(_ item: FileItem, token: Int) {
        previewKind = "icon"
        let kind = ThumbnailPolicy.panePreview(item, iconsOnly: Prefs.alwaysShowIcons)
        guard kind != .icon else { return }   // text, source code, CSV…: the type icon (Explorer does the same)
        let scale = window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 220, height: 150), scale: scale,
                                                   representationTypes: .thumbnail)
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let cgImage = rep?.cgImage else { return }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                // Size the image from its pixels: the representation's own NSImage can report a zero size.
                let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
                self.thumbnail.image = kind == .page ? Self.framedPage(cgImage, size: size) : NSImage(cgImage: cgImage, size: size)
                self.previewKind = kind == .page ? "page" : "thumbnail"
            }
        }
    }

    /// A document page with a hairline border, so a white page stays visible on the pane's white background.
    private static func framedPage(_ page: CGImage, size: NSSize) -> NSImage {
        NSImage(size: NSSize(width: size.width + 2, height: size.height + 2), flipped: false) { rect in
            NSGraphicsContext.current?.cgContext.draw(page, in: rect.insetBy(dx: 1, dy: 1))
            Theme.separator.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            return true
        }
    }

    /// Everything the pane shows for one item, read off the main thread.
    static func singleRows(_ item: FileItem) -> [(String, String)] {
        let url = item.url
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .contentTypeKey,
                                                  .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsSharedKey,
                                                  .volumeIsLocalKey])
        var rows: [(String, String)] = []
        if !item.isFolder {
            let sizes = SizeScanner.entrySizes(url)
            if !item.isPackage { rows.append((L10n.tr("Size"), PropertyFormat.adaptiveSize(sizes.size))) }
        }
        if let d = v?.contentModificationDate { rows.append((L10n.tr("Date modified"), PropertyFormat.shortDate(d))) }
        if let d = v?.creationDate { rows.append((L10n.tr("Date created"), PropertyFormat.shortDate(d))) }
        let meta = SpotlightMetadata.rows(for: url, isImage: v?.contentType?.conforms(to: .image) ?? false)
        let wanted: Set<String> = ["Dimensions", "Length", "Authors", "Title", "Camera model", "Album", "Bit rate", "Pages", "Rating"]
        for row in meta where wanted.contains(row.label) { rows.append((row.label, row.value)) }
        if item.isPackage, let bundle = BundleInfo.read(url) {
            if let version = bundle.version { rows.append((L10n.tr("Version"), version)) }
        }
        let tags = FinderMetadata.tags(of: url)
        if !tags.isEmpty { rows.append((L10n.tr("Tags"), FinderMetadata.tagText(tags))) }
        // Availability and sharing, where macOS knows them (iCloud Drive, network volumes).
        if v?.isUbiquitousItem == true {
            let local = v?.ubiquitousItemDownloadingStatus == .current
            rows.append((L10n.tr("Availability"), local ? L10n.tr("Available on this device") : L10n.tr("Available when online (stored in iCloud)")))
            if v?.ubiquitousItemIsShared == true { rows.append((L10n.tr("Sharing"), L10n.tr("Shared"))) }
        } else if v?.volumeIsLocal == false {
            rows.append((L10n.tr("Availability"), L10n.tr("On a network drive")))
        } else {
            rows.append((L10n.tr("Availability"), L10n.tr("Available on this device")))
        }
        if let flags = try? FileFlags.read(url), flags.isLocked { rows.append((L10n.tr("Attributes"), L10n.tr("Read-only (Locked)"))) }
        rows.append((L10n.tr("Location"), url.deletingLastPathComponent().path))
        return rows
    }

    private func setRows(_ rows: [(String, String)]) {
        self.rows = rows
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        propertiesHeader.isHidden = rows.isEmpty
        for (label, value) in rows {
            // Property names wrap onto a second line rather than being cut off (longer translations).
            let l = NSTextField(wrappingLabelWithString: label)
            l.maximumNumberOfLines = 2
            l.preferredMaxLayoutWidth = 100
            l.isSelectable = false
            l.setContentCompressionResistancePriority(.required, for: .vertical)
            l.font = Theme.bodyFont
            l.textColor = Theme.secondaryText
            l.translatesAutoresizingMaskIntoConstraints = false
            let v = NSTextField(wrappingLabelWithString: value)
            v.font = Theme.bodyFont
            v.textColor = Theme.primaryText
            v.isSelectable = true
            v.maximumNumberOfLines = 3
            v.lineBreakMode = .byTruncatingMiddle
            v.translatesAutoresizingMaskIntoConstraints = false
            v.toolTip = value
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(l)
            row.addSubview(v)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                l.topAnchor.constraint(equalTo: row.topAnchor),
                l.widthAnchor.constraint(equalToConstant: 100),
                v.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 104),
                v.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                v.topAnchor.constraint(equalTo: row.topAnchor),
                row.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: l.bottomAnchor),
            ])
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
    }

    // MARK: Editing Finder tags and comments (FE-161)

    private func prepareEditing(_ item: FileItem?) {
        let editable = item.map { !Location.isVolumeRoot($0.url) } ?? false
        editHeader.isHidden = !editable
        editBox.isHidden = !editable
        guard let item, editable else { editURL = nil; editOriginal = nil; return }
        editURL = item.url
        let url = item.url
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = try? EditableState.read(url)
            DispatchQueue.main.async {
                guard let self, token == self.generation, let state else { return }
                self.editOriginal = state
                self.tagsField.stringValue = FinderMetadata.tagText(state.tags)
                self.commentField.stringValue = state.comment
                self.editsChanged()
            }
        }
    }

    private var editedState: EditableState? {
        guard var state = editOriginal else { return nil }
        state.tags = FinderMetadata.parseTags(tagsField.stringValue)
        state.comment = commentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return state
    }

    private func editsChanged() {
        let dirty = editedState.map { $0 != editOriginal } ?? false
        editButtons.isHidden = !dirty
    }

    private func saveEdits() {
        guard let url = editURL, let original = editOriginal, let edited = editedState else { return }
        window?.makeFirstResponder(nil)
        guard let current = try? EditableState.read(url) else {
            NSAlert.show(L10n.format("“%@” can't be found.", "\(url.lastPathComponent)"), L10n.tr("It may have been moved or deleted."), in: window)
            return
        }
        let plan = PropertyChangePlan(url: url, original: original, edited: edited)
        if !plan.conflicts(with: current).isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.format("“%@” was changed by another app.", "\(url.lastPathComponent)")
            alert.informativeText = L10n.tr("Save your tags and comments anyway?")
            alert.addButton(withTitle: L10n.tr("Save"))
            alert.addButton(withTitle: L10n.tr("Cancel"))
            PropertiesWindowController.present(alert, window: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.write(edited, over: current, at: url) }
            }
            return
        }
        write(edited, over: current, at: url)
    }

    /// Writes only tags and comments, on top of the item's current state.
    private func write(_ edited: EditableState, over current: EditableState, at url: URL) {
        var target = current
        target.tags = edited.tags
        target.comment = edited.comment
        do {
            _ = try PropertyChangePlan(url: url, original: current, edited: target).apply()
            editOriginal = try EditableState.read(url)
            editsChanged()
            BrowserWindowController.active?.statusBar.setMessage(L10n.format("Saved tags and comments for “%@”.", "\(url.lastPathComponent)"))
            if let item = FileItem(url: url), shownItems.count == 1 { show([item], location: nil) }
        } catch {
            NSAlert.show(L10n.tr("Tags and comments couldn't be saved."), error.localizedDescription, in: window)
        }
    }

    private func cancelEdits() {
        guard let original = editOriginal else { return }
        tagsField.stringValue = FinderMetadata.tagText(original.tags)
        commentField.stringValue = original.comment
        editsChanged()
    }

    // MARK: Scripting

    var debugText: String {
        var lines = ["details pane: \(nameLabel.stringValue) | \(typeLabel.stringValue)"]
        if shownItems.count == 1 {
            let size = thumbnail.image?.size ?? .zero
            lines.append("  preview: \(previewKind) \(Int(size.width))x\(Int(size.height))")
        }
        lines += rows.map { "  \($0.0): \($0.1)" }
        if !editBox.isHidden { lines.append("  edit tags: \(tagsField.stringValue)  comments: \(commentField.stringValue)  save shown: \(!editButtons.isHidden)") }
        if !message.isHidden { lines.append("  message: \(message.stringValue)") }
        return lines.joined(separator: "\n")
    }

    func scriptEdit(tags: String?, comment: String?, save: Bool) {
        if let tags { tagsField.stringValue = tags }
        if let comment { commentField.stringValue = comment }
        editsChanged()
        if save { saveEdits() }
    }
}
