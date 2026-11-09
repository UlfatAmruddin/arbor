import AppKit
import ArborCore

extension BrowserWindowController {
    // MARK: - File operations shared by commands

    /// Starts a copy/move job. When items land in the visible folder they are selected.
    func startTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL, preflighted: Bool = false,
                       then: ((TransferReport) -> Void)? = nil) {
        if !preflighted, let prompt = TransferPreflight.prompt(kind, urls, to: folder) {   // e.g. cloud hydration (FE-113)
            prompt.ask(in: window) { [weak self] go in if go { self?.startTransfer(kind, urls, to: folder, preflighted: true, then: then) } }
            return
        }
        OperationCenter.shared.start(kind, sources: urls, destination: folder, window: window) { [weak self] report in
            then?(report)
            guard let self else { return }
            let landedHere = report.committed.map(\.destination).filter {
                Location.folder($0.deletingLastPathComponent()) == self.location
            }
            if !landedHere.isEmpty {
                self.navigate(to: self.location, select: landedHere.map(\.lastPathComponent))
            }
            if report.wasCancelled {
                self.statusBar.setMessage(L10n.format("Transfer cancelled. Items already %@ were kept.", TransferWords.localized(report.kind.pastVerb)))
            } else if report.problems.isEmpty, !report.committed.isEmpty {
                self.statusBar.setMessage(L10n.format("%@ %@ to “%@”.", "\(StatusText.items(report.committed.count))", TransferWords.localized(report.kind.pastVerb), "\(displayName(of: report.destination))"))
            }
        }
    }

    /// Drops from the tree, item views and breadcrumb end here, so features see them (right-drag menu, shortcuts, overlapping sources).
    func transferDropped(_ kind: TransferKind, _ urls: [URL], to folder: URL) {
        if InteractionHooks.drop.handle((self, kind, urls, folder)) { return }
        startTransfer(kind, urls, to: folder)
    }

    /// Refreshes the active folder, selects `names` and optionally starts renaming one of them.
    func refreshSelecting(_ names: [String], rename: String? = nil) {
        activeTab.renameAfterLoad = rename.map(RenameTarget.name)
        navigate(to: location, select: names)
    }

    /// Reloads and selects exactly these items (names repeat in search results and libraries).
    func refreshSelecting(urls: [URL], rename: URL? = nil) {
        activeTab.renameAfterLoad = rename.map(RenameTarget.url)
        request(.visit(location, select: urls.map(\.lastPathComponent), selectURLs: urls), tab: activeTab)
    }

    /// Next remaining row after removing `items`, else the previous one (by identity).
    func neighborURL(after items: [FileItem]) -> URL? {
        let removed = Set(items.map(\.url))
        let rows = visibleItems
        guard let last = rows.lastIndex(where: { removed.contains($0.url) }) else { return nil }
        if let next = rows[(last + 1)...].first(where: { !removed.contains($0.url) }) { return next.url }
        return rows[..<last].last(where: { !removed.contains($0.url) })?.url
    }

    /// `neighborURL(after:)` by name.
    func neighbor(after items: [FileItem]) -> String? {
        let removed = Set(items.map(\.name))
        let rows = visibleItems
        guard let last = rows.lastIndex(where: { removed.contains($0.name) }) else { return nil }
        if let next = rows[(last + 1)...].first(where: { !removed.contains($0.name) }) { return next.name }
        return rows[..<last].last(where: { !removed.contains($0.name) })?.name
    }

    /// Opens items like Explorer: one folder navigates; several (or ⌘) open tabs; files open in their app.
    func open(_ items: [FileItem], inNewTab: Bool) {
        var locations: [Location] = []
        var files: [FileItem] = []
        for item in items {
            if let location = LocationRegistry.locationForOpening(item) { locations.append(location) } else { files.append(item) }
        }
        if locations.count == 1, files.isEmpty, !inNewTab {
            if WindowHooks.openFolder.handle((self, locations[0])) { return }
            navigate(to: locations[0])
            return
        }
        locations.forEach { openTab($0) }
        explainUnopenable(files.filter { !PathLimits.fits($0.url) })
        files.removeAll { !PathLimits.fits($0.url) || InteractionHooks.openFile.handle((self, $0)) }
        files.forEach { SystemOpen.open($0.url) }
        if !files.isEmpty { NotificationCenter.default.post(name: LocationEvents.didOpenFiles, object: self, userInfo: ["urls": files.map(\.url)]) }
    }

    /// The kernel refuses paths past the limit, so opening such a file would silently do nothing.
    private func explainUnopenable(_ files: [FileItem]) {
        guard let first = files.first else { return }
        let reasons = files.compactMap { PathResolutionError.pathTooLong($0.url.path).errorDescription }
        NSAlert.show(L10n.format("Can't open “%@”", first.name), reasons.joined(separator: "\n"), in: window)
    }
}
