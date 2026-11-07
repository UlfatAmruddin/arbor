import Foundation

// MARK: - Focus regions (F6 / Shift+F6, Tab / Shift+Tab; FE-062, FE-199)

/// The parts of a browser window that keyboard focus cycles through, in Explorer's F6 order:
/// tabs → address bar → search box → command bar → navigation pane → items → side pane.
public enum FocusRegion: String, CaseIterable, Sendable {
    case tabs, address, search, commandBar, navigationPane, items, sidePane

    public var title: String {
        switch self {
        case .tabs: return "Tabs"
        case .address: return "Address bar"
        case .search: return "Search box"
        case .commandBar: return "Command bar"
        case .navigationPane: return "Navigation pane"
        case .items: return "Items"
        case .sidePane: return "Side pane"
        }
    }
}

public enum FocusCycle {
    /// The region after (or before) `current`, skipping regions that can't take focus now (hidden
    /// navigation pane, no side pane). From nowhere, forward starts at the items (where focus usually
    /// lives) and backward at the region before them.
    public static func next(from current: FocusRegion?, forward: Bool, available: Set<FocusRegion>) -> FocusRegion? {
        let order = FocusRegion.allCases
        guard !available.isEmpty else { return nil }
        guard let current, let start = order.firstIndex(of: current) else {
            if forward, available.contains(.items) { return .items }
            return next(from: .items, forward: forward, available: available)
        }
        for step in 1...order.count {
            let index = (start + (forward ? step : -step) + order.count * 2) % order.count
            if available.contains(order[index]) { return order[index] }
        }
        return nil
    }
}

// MARK: - Announcements (spec §16.2: announce location, selection count, job results; throttle)

/// Coalesces bursts (selection changes while holding Shift+Down): the first one is spoken at once,
/// later ones at most every `interval`, and only the latest text of a burst is spoken.
public struct AnnouncementThrottle: Sendable {
    public var interval: TimeInterval
    private(set) public var lastSpoken: TimeInterval?
    private(set) public var lastText: String?

    public init(interval: TimeInterval = 0.8) { self.interval = interval }

    public enum Decision: Equatable, Sendable {
        /// Speak now.
        case now
        /// Speak after this delay (the caller keeps only the newest pending text).
        case after(TimeInterval)
        /// Same as what was just spoken: say nothing.
        case skip
    }

    public mutating func submit(_ text: String, at time: TimeInterval) -> Decision {
        if text == lastText, let last = lastSpoken, time - last < interval * 4 { return .skip }
        guard let last = lastSpoken, time - last < interval else {
            lastSpoken = time
            lastText = text
            return .now
        }
        return .after(interval - (time - last))
    }

    /// Records a delayed announcement as spoken.
    public mutating func spoke(_ text: String, at time: TimeInterval) {
        lastSpoken = time
        lastText = text
    }
}

public enum AnnouncementText {
    /// "3 items selected". A single item is read by VoiceOver from the row itself, so it isn't repeated;
    /// clearing a multiple selection says so.
    public static func selection(count: Int, previous: Int) -> String? {
        if count >= 2 { return count == previous ? nil : L10n.format("%@ items selected", StatusText.number(count)) }
        if count == 0, previous >= 2 { return L10n.tr("Selection cleared") }
        return nil
    }

    /// "Documents, 12 items" when a folder opens.
    public static func location(_ title: String, itemCount: Int?) -> String {
        guard let itemCount else { return title }
        return "\(title), \(itemCount == 0 ? L10n.tr("empty") : StatusText.items(itemCount))"
    }

    /// Status bar messages worth speaking: not progress ("Loading…"), not empty.
    public static func shouldSpeakStatus(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return false }
        return !(text.hasSuffix("…") || text.hasSuffix("..."))
    }
}

extension StatusText {
    /// A count with grouping separators, in the user's locale.
    public static func number(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}

// MARK: - Text size (FE-050, FE-202)

/// "Text size" levels for the file list, Details rows, icon labels and the navigation pane.
public enum TextSizeLevel: Int, CaseIterable, Sendable {
    case standard = 100, larger = 115, large = 130, largest = 150

    public var scale: Double { Double(rawValue) / 100 }

    public var title: String {
        switch self {
        case .standard: return "Default (100%)"
        case .larger: return "Larger (115%)"
        case .large: return "Large (130%)"
        case .largest: return "Largest (150%)"
        }
    }

    public var bigger: TextSizeLevel? { Self.allCases.first { $0.rawValue > rawValue } }
    public var smaller: TextSizeLevel? { Self.allCases.last { $0.rawValue < rawValue } }

    /// A font size at this level, rounded to half points.
    public func fontSize(_ base: Double) -> Double { (base * scale * 2).rounded() / 2 }

    /// A row height that keeps the same breathing room around the larger text: the base height grows
    /// by the extra line height, never less than the text needs (no clipped glyphs).
    public func rowHeight(_ base: Double, fontSize baseFont: Double) -> Double {
        let extra = (fontSize(baseFont) - baseFont) * 1.3
        return (base + max(0, extra)).rounded(.up)
    }
}

// MARK: - Trackpad swipe navigation (FE-016)

public enum SwipeNavigation {
    public enum Direction: Equatable, Sendable { case back, forward }

    /// Whether a two-finger horizontal scroll that is just beginning should become a Back/Forward swipe.
    /// It must be clearly horizontal, and the content under the pointer must already be at its edge in
    /// that direction, so horizontal scrolling (List view, wide Details columns) keeps working.
    /// `deltaX` > 0 means the content moves right (fingers move right): Back, like Safari.
    public static func decision(deltaX: Double, deltaY: Double, canScrollLeft: Bool, canScrollRight: Bool) -> Direction? {
        guard abs(deltaX) > 0.5, abs(deltaX) > abs(deltaY) * 2 else { return nil }
        if deltaX > 0 { return canScrollLeft ? nil : .back }
        return canScrollRight ? nil : .forward
    }

    /// Three-finger swipe events report deltaX +1 for a swipe that should go back.
    public static func direction(swipeDeltaX: Double) -> Direction? {
        if swipeDeltaX > 0 { return .back }
        if swipeDeltaX < 0 { return .forward }
        return nil
    }
}

// MARK: - Tree "expand all" (FE-061: Num * expands every folder under the node)

public enum TreeExpansion {
    /// Explorer's `*` expands the whole subtree. Reading every subfolder of a big tree is the kind of
    /// recursive scan the spec rules out (§15.3), so expansion stops after this many folders and this depth.
    public static let maxNodes = 400
    public static let maxDepth = 6

    /// Breadth-first order of nodes to expand under `root`, bounded by `maxNodes` / `maxDepth`.
    /// `children` returns a node's subfolders (read on demand).
    public static func plan<Node>(root: Node, children: (Node) -> [Node], maxNodes: Int = maxNodes,
                                  maxDepth: Int = maxDepth) -> (nodes: [Node], truncated: Bool) {
        var result: [Node] = []
        var queue: [(Node, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count {
            let (node, depth) = queue[head]
            head += 1
            if result.count >= maxNodes { return (result, true) }
            result.append(node)
            guard depth < maxDepth else { continue }
            for child in children(node) { queue.append((child, depth + 1)) }
        }
        return (result, false)
    }
}

// MARK: - Key names (DebugScript `key:` steps and the keyboard reference)

public enum KeyNames {
    /// macOS virtual key code and modifier names for "shift+F10", "F6", "option+space", "cmd+opt+left", "menu".
    public static func parse(_ text: String) -> (code: UInt16, modifiers: Set<String>, characters: String)? {
        let parts = text.lowercased().split(separator: "+").map { String($0) }
        guard let key = parts.last else { return nil }
        var mods = Set<String>()
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": mods.insert("command")
            case "opt", "option", "alt": mods.insert("option")
            case "ctrl", "control": mods.insert("control")
            case "shift": mods.insert("shift")
            default: return nil
            }
        }
        let table: [String: (UInt16, String)] = [
            "f1": (122, "\u{F704}"), "f2": (120, "\u{F705}"), "f3": (99, "\u{F706}"), "f4": (118, "\u{F707}"),
            "f5": (96, "\u{F708}"), "f6": (97, "\u{F709}"), "f7": (98, "\u{F70A}"), "f8": (100, "\u{F70B}"),
            "f10": (109, "\u{F70D}"), "f11": (103, "\u{F70E}"), "f12": (111, "\u{F70F}"),
            "tab": (48, "\t"), "space": (49, " "), "return": (36, "\r"), "enter": (76, "\u{3}"), "escape": (53, "\u{1B}"),
            "esc": (53, "\u{1B}"), "delete": (51, "\u{7F}"), "forwarddelete": (117, "\u{F728}"),
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
            "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
            "menu": (110, "\u{10}"), "numstar": (67, "*"), "numplus": (69, "+"), "numminus": (78, "-"),
            "*": (28, "*"), "+": (24, "+"), "-": (27, "-"),
        ]
        if let (code, chars) = table[key] { return (code, mods, chars) }
        let letters: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
            "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        if let code = letters[key] { return (code, mods, key) }
        return nil
    }
}
