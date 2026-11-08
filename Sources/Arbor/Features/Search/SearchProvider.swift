import AppKit
import ArborCore

/// Supplies `.search` locations: results stream into the standard item views, so sorting, selection,
/// rename, clipboard, drag and drop and every file command work on them (FE-131, FE-137).
final class SearchProvider: LocationProvider {
    func handles(_ location: Location) -> Bool {
        if case .search = location { return true }
        return false
    }

    static func session(for location: Location, showHidden: Bool = Prefs.showHidden) -> SearchSession? {
        guard case .search(let request) = location else { return nil }
        return SearchSessions.existing(request, showHidden: showHidden)
    }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        guard case .search(let request) = location else { return nil }
        let session = SearchSessions.session(for: request, showHidden: context.showHidden)
        let handle = LoadHandle()
        func deliver() {
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                completion(.success(.items(session.items)))
            }
        }
        if session.snapshotRequested || session.isRunning || session.finishedAt == nil {
            session.snapshotRequested = false
            deliver()
        } else {
            // A finished search shown again (after a delete or rename, or a tab switch): drop vanished files first.
            session.revalidate { deliver() }
        }
        return handle
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        guard let session = Self.session(for: location) else { return nil }
        return session.observe {
            // Look the session up again: Refresh may have replaced it (observers move to the new run).
            Self.session(for: location)?.snapshotRequested = true
            onChange()
        }
    }

    func title(for location: Location) -> String { location.displayName }
    func targetFolder(for location: Location) -> URL? { nil }          // New and Paste need a real folder
    func allowsItemEditing(in location: Location) -> Bool { true }     // results are real files

    func emptyText(for location: Location) -> String {
        guard let session = Self.session(for: location) else { return L10n.tr("Searching…") }
        let coverage = session.coverage
        switch coverage.phase {
        case .searching: return L10n.tr("Searching…")
        case .failed(let message): return L10n.format("Search couldn't run: %@", "\(message)")
        case .stopped: return L10n.tr("The search was stopped. Press Refresh to search again.")
        case .finished:
            if let scope = coverage.scopeUnavailable { return L10n.format("“%@” isn't available. It may have been moved, deleted or disconnected.", "\(scope)") }
            return coverage.isComplete ? "No items match your search."
                : "No items match your search. Some places couldn't be searched; see Search options ▸ Why might results be missing?"
        }
    }

    func statusDetail(for location: Location) -> String? {
        guard let session = Self.session(for: location) else { return L10n.tr("Searching…") }
        return session.superseded ? "Searching…" : session.coverage.statusLine
    }
}

/// Extra Details-view columns for search results: Folder (the containing path, like Explorer) and
/// Match (why the item matched, FE-137).
enum SearchColumns {
    /// Uses main's `DetailsColumns` layouts: Name · Date modified · Type · Size · Folder · Match.
    /// The layout id carries the location key so each search binds its own session.
    static func register() {
        DetailsColumns.register { location in
            guard case .search = location else { return nil }
            return DetailsLayout(
                id: "search:" + location.key,
                order: ["name", "dateModified", "type", "size", "search.folder", "search.match"],
                widths: ["name": 260],
                extras: [
                    DetailsColumnSpec(id: "search.folder", title: "Folder", width: 280, minWidth: 80) { table, item in
                        let cell = DetailsTextCell.make(table, id: "search.folder", truncation: .byTruncatingMiddle)
                        let text = folderText(item, location)
                        cell.label.stringValue = text
                        cell.label.toolTip = text
                        return cell
                    },
                    DetailsColumnSpec(id: "search.match", title: "Match", width: 110, minWidth: 60) { table, item in
                        let cell = DetailsTextCell.make(table, id: "search.match")
                        let text = reasonText(item, location)
                        cell.label.stringValue = text
                        cell.label.toolTip = text.isEmpty ? nil : L10n.format("Matched on: %@", text)
                        return cell
                    },
                ])
        }
    }

    private static var realScopes: [String: String] = [:]

    /// The containing folder, spelled like the search scope (`/tmp/…`, not the resolved `/private/tmp/…`).
    static func folderText(_ item: FileItem, _ location: Location?) -> String {
        let folder = item.url.deletingLastPathComponent().path
        guard case .search(let r)? = location, let scope = r.scope?.path else { return folder }
        let real: String
        if let cached = realScopes[scope] {
            real = cached
        } else {
            var resolved = scope
            if let p = realpath(scope, nil) { resolved = String(cString: p); free(p) }
            if realScopes.count > 32 { realScopes.removeAll() }
            realScopes[scope] = resolved
            real = resolved
        }
        guard real != scope, folder == real || folder.hasPrefix(real + "/") else { return folder }
        return scope + folder.dropFirst(real.count)
    }

    static func reasonText(_ item: FileItem, _ location: Location?) -> String {
        guard let location, let reasons = SearchProvider.session(for: location)?.reasons(forPath: item.url.path) else { return "" }
        return reasons.sorted().map(\.label).joined(separator: ", ")
    }
}
