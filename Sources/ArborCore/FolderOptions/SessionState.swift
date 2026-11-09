import CoreGraphics
import Foundation

// MARK: - Session restore (FE-024, FE-251)

/// One tab for "Restore previous folder windows": keys and view settings, never listings (FE-251).
public struct SessionTab: Codable, Hashable, Sendable {
    public var location: String
    /// Oldest first; bounded by `SessionState.historyLimit`.
    public var back: [String]
    /// Nearest entry first.
    public var forward: [String]
    public var viewMode: String
    public var sortKey: String
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(location: String, back: [String] = [], forward: [String] = [], viewMode: String = "details",
                sortKey: String = "name", ascending: Bool = true, foldersFirst: Bool = true) {
        self.location = location
        self.back = back
        self.forward = forward
        self.viewMode = viewMode
        self.sortKey = sortKey
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    /// Only `location` is required: a missing or mistyped setting takes its default instead of losing the tab.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        location = try values.decode(String.self, forKey: .location)
        back = (try? values.decode([String].self, forKey: .back)) ?? []
        forward = (try? values.decode([String].self, forKey: .forward)) ?? []
        viewMode = (try? values.decode(String.self, forKey: .viewMode)) ?? "details"
        sortKey = (try? values.decode(String.self, forKey: .sortKey)) ?? "name"
        ascending = (try? values.decode(Bool.self, forKey: .ascending)) ?? true
        foldersFirst = (try? values.decode(Bool.self, forKey: .foldersFirst)) ?? true
    }

    public init(history: NavigationHistory, viewMode: String, sort: FileSortOrder) {
        let limit = SessionState.historyLimit
        self.init(location: history.current.location.key,
                  back: history.backStack.suffix(limit).map(\.location.key),
                  forward: history.forwardStack.reversed().prefix(limit).map(\.location.key),
                  viewMode: viewMode, sortKey: sort.primaryColumn.rawValue, ascending: sort.ascending, foldersFirst: sort.foldersFirst)
    }

    public var sortOrder: FileSortOrder {
        FolderViewSettings(sortKey: sortKey, ascending: ascending, foldersFirst: foldersFirst).sortOrder
    }

    /// Rebuilds Back/Forward. Unreadable keys are dropped; nil if the current location is unreadable.
    public func history() -> NavigationHistory? {
        guard let current = Location(key: location) else { return nil }
        let back = back.compactMap(Location.init(key:))
        let forward = forward.compactMap(Location.init(key:))
        return NavigationHistory.rebuilt(back: back, current: current, forward: forward)
    }
}

public struct SessionWindow: Codable, Equatable, Sendable {
    /// x, y, width, height in screen coordinates (bottom-left origin).
    public var frame: [Double]
    public var tabs: [SessionTab]
    public var activeTab: Int

    public init(frame: CGRect, tabs: [SessionTab], activeTab: Int) {
        self.frame = [frame.origin.x, frame.origin.y, frame.width, frame.height].map(Double.init)
        self.tabs = tabs
        self.activeTab = activeTab
    }

    public var rect: CGRect? {
        guard frame.count == 4, frame[2] > 0, frame[3] > 0 else { return nil }
        return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
    }
}

public struct SessionState: Codable, Equatable, Sendable {
    public static let historyLimit = 20
    public static let windowLimit = 20
    public static let tabLimit = 40

    public var version = 1
    public var windows: [SessionWindow]

    public init(windows: [SessionWindow]) {
        self.windows = Array(windows.prefix(Self.windowLimit)).map { window in
            var w = window
            w.tabs = Array(w.tabs.prefix(Self.tabLimit))
            w.activeTab = min(max(0, w.activeTab), max(0, w.tabs.count - 1))
            return w
        }.filter { !$0.tabs.isEmpty }
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    public static func decode(_ data: Data) -> SessionState? {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return nil }
        return SessionState(windows: state.windows)   // re-apply bounds to files written elsewhere
    }
}

extension NavigationHistory {
    /// Rebuilds a history (forward: nearest first) using only public moves.
    public static func rebuilt(back: [Location], current: Location, forward: [Location], limit: Int = 100) -> NavigationHistory {
        let path = back + [current]
        var history = NavigationHistory(start: path[0], limit: limit)
        for location in path.dropFirst() { history.visit(location) }
        var pushed = 0
        for location in forward where location != history.current.location {
            history.visit(location)
            pushed += 1
        }
        for _ in 0..<pushed { history.goBack() }
        return history
    }
}

// MARK: - Window placement (FE-026)

/// Keeps windows reachable: a saved frame whose title bar isn't on any current screen moves to one.
public enum WindowPlacement {
    /// Height of the strip that must be visible to drag the window (the tab row).
    public static let titleStrip: CGFloat = 40

    /// True if enough of the title strip is on one screen to grab it.
    public static func isReachable(_ frame: CGRect, screens: [CGRect]) -> Bool {
        let strip = CGRect(x: frame.minX, y: frame.maxY - titleStrip, width: frame.width, height: titleStrip)
        return screens.contains { screen in
            let overlap = strip.intersection(screen)
            return !overlap.isNull && overlap.width >= min(120, frame.width / 3) && overlap.height >= titleStrip / 2
        }
    }

    /// Unchanged if reachable; else fitted onto the screen it overlaps most (or the first one).
    public static func recover(_ frame: CGRect, screens: [CGRect], minSize: CGSize = CGSize(width: 480, height: 320)) -> CGRect {
        guard !screens.isEmpty else { return frame }
        if isReachable(frame, screens: screens), screens.contains(where: { $0.contains(frame) }) || fitsSomeScreen(frame, screens) {
            return frame
        }
        let target = screens.max { area(frame.intersection($0)) < area(frame.intersection($1)) }
            .flatMap { area(frame.intersection($0)) > 0 ? $0 : nil } ?? screens[0]
        var result = frame
        result.size.width = min(max(frame.width, min(minSize.width, target.width)), target.width)
        result.size.height = min(max(frame.height, min(minSize.height, target.height)), target.height)
        result.origin.x = min(max(frame.minX, target.minX), target.maxX - result.width)
        result.origin.y = min(max(frame.minY, target.minY), target.maxY - result.height)
        return result
    }

    /// A frame dragged partly off-screen is the user's choice; keep it unless it's larger than every screen.
    private static func fitsSomeScreen(_ frame: CGRect, _ screens: [CGRect]) -> Bool {
        screens.contains { frame.width <= $0.width + 1 && frame.height <= $0.height + 1 && frame.maxY <= $0.maxY + 1 }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
