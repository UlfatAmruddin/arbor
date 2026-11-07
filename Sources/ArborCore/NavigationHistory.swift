import Foundation

/// A committed location plus the context needed to restore it (FE-001).
public struct NavigationEntry: Equatable, Sendable {
    public var location: Location
    public var selectedNames: [String]
    public var topVisibleName: String?

    /// The folder, for folder locations.
    public var url: URL? { location.folderURL }

    public init(location: Location, selectedNames: [String] = [], topVisibleName: String? = nil) {
        self.location = location
        self.selectedNames = selectedNames
        self.topVisibleName = topVisibleName
    }

    public init(url: URL, selectedNames: [String] = [], topVisibleName: String? = nil) {
        self.init(location: .folder(url.standardizedFileURL), selectedNames: selectedNames, topVisibleName: topVisibleName)
    }
}

/// Per-tab Back/Forward history. Up is a separate parent transition, not a history move.
/// Callers should only commit a transition after the destination loaded successfully,
/// so a failed navigation leaves history untouched.
public struct NavigationHistory: Sendable {
    public private(set) var backStack: [NavigationEntry] = []
    public private(set) var forwardStack: [NavigationEntry] = []
    public private(set) var current: NavigationEntry
    public let limit: Int

    public init(start: Location, limit: Int = 100) {
        current = NavigationEntry(location: start)
        self.limit = max(1, limit)
    }

    public init(start: URL, limit: Int = 100) {
        self.init(start: .folder(start.standardizedFileURL), limit: limit)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public func peekBack() -> NavigationEntry? { backStack.last }
    public func peekForward() -> NavigationEntry? { forwardStack.last }

    /// Branch navigation. Visiting the current location is not a new entry.
    public mutating func visit(_ location: Location, selectedNames: [String] = []) {
        guard location != current.location else {
            if !selectedNames.isEmpty { current.selectedNames = selectedNames }
            return
        }
        backStack.append(current)
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        forwardStack.removeAll()
        current = NavigationEntry(location: location, selectedNames: selectedNames)
    }

    public mutating func visit(_ url: URL, selectedNames: [String] = []) {
        visit(.folder(url.standardizedFileURL), selectedNames: selectedNames)
    }

    /// Replaces the current entry's location without a new Back step (refining a search query).
    public mutating func replaceCurrent(with location: Location) {
        current = NavigationEntry(location: location)
    }

    @discardableResult
    public mutating func goBack() -> NavigationEntry? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> NavigationEntry? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }

    /// Records selection and scroll anchor for the current entry before leaving it.
    public mutating func saveState(selectedNames: [String], topVisibleName: String?) {
        current.selectedNames = selectedNames
        current.topVisibleName = topVisibleName
    }

    /// Plain parent folder, for walking up to a folder that still exists. Use `Location.parent` for Up.
    public static func parent(of url: URL) -> URL? {
        let url = url.standardizedFileURL
        guard url.path != "/" else { return nil }
        return url.deletingLastPathComponent().standardizedFileURL
    }
}
