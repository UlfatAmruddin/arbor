import ArborCore

/// The one conversion between a live tab and its saved form (session restore, workspaces).
extension TabState {
    /// Nil if the saved location can't be read.
    convenience init?(session entry: SessionTab) {
        guard let history = entry.history() else { return nil }
        self.init(session: entry, location: history.current.location)
        self.history = history
    }

    /// No Back/Forward: for a location already parsed off the main thread.
    convenience init(session entry: SessionTab, location: Location) {
        self.init(location: location, viewMode: ViewMode(rawValue: entry.viewMode) ?? .details, sortOrder: entry.sortOrder)
    }

    var sessionTab: SessionTab { SessionTab(history: history, viewMode: viewMode.rawValue, sort: sortOrder) }
}
