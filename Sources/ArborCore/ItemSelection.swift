import Foundation

/// Selection state for a grid or list of items (spec §7.1): the selected items, the focused item
/// (keyboard caret) and the range anchor are tracked separately. Indexes refer to the current display
/// order; views translate to names when the listing changes.
public struct ItemSelection: Equatable, Sendable {
    public var selected = IndexSet()
    /// The keyboard caret. It can sit on an unselected item (⌃-arrow moves focus only).
    public var focus: Int?
    /// Start of Shift ranges.
    public var anchor: Int?

    public enum Modifier: Sendable {
        /// Plain click: select only this item.
        case none
        /// ⌘-click (Ctrl+click): toggle this item.
        case toggle
        /// Shift-click: select the range from the anchor, replacing the selection.
        case extend
        /// ⌘⇧-click: add the range from the anchor to the selection.
        case extendAdding
    }

    public init(selected: IndexSet = IndexSet(), focus: Int? = nil, anchor: Int? = nil) {
        self.selected = selected
        self.focus = focus
        self.anchor = anchor
    }

    private static func range(_ a: Int, _ b: Int) -> IndexSet { IndexSet(integersIn: min(a, b)...max(a, b)) }

    public mutating func click(_ index: Int, _ modifier: Modifier) {
        switch modifier {
        case .none:
            selected = [index]
            anchor = index
        case .toggle:
            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
            anchor = index
        case .extend:
            selected = Self.range(anchor ?? index, index)
            if anchor == nil { anchor = index }
        case .extendAdding:
            selected.formUnion(Self.range(anchor ?? index, index))
            if anchor == nil { anchor = index }
        }
        focus = index
    }

    /// Clicking empty space clears the selection unless ⌘ or Shift is held (Explorer). Focus stays.
    public mutating func clickBackground(keepSelection: Bool) {
        if !keepSelection { selected = [] }
    }

    /// Keyboard move to `index`: plain moves select it; Shift extends from the anchor; focus-only
    /// (⌃-arrow, Ctrl+arrow in Explorer) moves the caret without changing the selection.
    public mutating func move(to index: Int, extend: Bool, focusOnly: Bool) {
        if focusOnly {
            focus = index
            return
        }
        if extend {
            let start = anchor ?? focus ?? index
            selected = Self.range(start, index)
            anchor = start
        } else {
            selected = [index]
            anchor = index
        }
        focus = index
    }

    /// ⌃Space (Ctrl+Space): toggle the focused item.
    public mutating func toggleFocused() {
        guard let focus else { return }
        if selected.contains(focus) { selected.remove(focus) } else { selected.insert(focus) }
        anchor = focus
    }

    /// Programmatic selection (restore, Select All, after paste): focus and anchor go to the first item.
    /// Clearing keeps the caret where it was.
    public mutating func set(_ indexes: IndexSet) {
        selected = indexes
        if let first = indexes.first {
            focus = first
            anchor = first
        }
    }

    /// Drops indexes beyond `count` after the listing shrank.
    public mutating func clamp(to count: Int) {
        selected = selected.filteredIndexSet { $0 < count }
        if let f = focus, f >= count { focus = count > 0 ? count - 1 : nil }
        if let a = anchor, a >= count { anchor = nil }
    }

    /// Marquee (rubber-band) result: plain replaces, Shift adds, ⌘ toggles against the selection the
    /// drag started with (FE-058).
    public static func marquee(base: IndexSet, hits: IndexSet, toggle: Bool, add: Bool) -> IndexSet {
        if toggle { return base.symmetricDifference(hits) }
        if add { return base.union(hits) }
        return hits
    }
}

/// Explorer's type-to-select (windows11-reference §8.2): typing a prefix selects the next item whose
/// name starts with it; the buffer resets after about a second; repeating one letter cycles through
/// the items starting with that letter. Matching ignores case and diacritics.
public struct TypeSelect: Sendable {
    public var timeout: TimeInterval
    private(set) public var buffer = ""
    private var last: Date?

    public init(timeout: TimeInterval = 1.0) { self.timeout = timeout }

    /// True while a typed prefix is still being extended (a space then belongs to the name).
    public func isActive(at time: Date) -> Bool {
        guard let last, !buffer.isEmpty else { return false }
        return time.timeIntervalSince(last) < timeout
    }

    public mutating func reset() {
        buffer = ""
        last = nil
    }

    /// Returns the index to select, or nil if nothing matches.
    public mutating func input(_ text: String, at time: Date, names: [String], current: Int?) -> Int? {
        guard !text.isEmpty, !names.isEmpty else { return nil }
        if !isActive(at: time) { buffer = "" }
        buffer += text
        last = time
        let start = current.map { min(max($0, 0), names.count - 1) }
        let chars = Array(buffer)
        if chars.count > 1, chars.allSatisfy({ String($0).lowercased() == String(chars[0]).lowercased() }) {
            // "aaa": cycle through items starting with "a", unless a name really starts with "aaa".
            if let current = start, Self.matches(names[current], buffer) { return current }
            if let exact = Self.search(names, prefix: buffer, after: start, includeStart: false) { return exact }
            return Self.search(names, prefix: String(chars[0]), after: start, includeStart: false)
        }
        // Extending a prefix keeps the current item if it still matches; a fresh letter moves on.
        if chars.count > 1, let current = start, Self.matches(names[current], buffer) { return current }
        return Self.search(names, prefix: buffer, after: start, includeStart: false)
    }

    static func matches(_ name: String, _ prefix: String) -> Bool {
        name.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// First match after `start` (wrapping), or from the top when there's no start.
    static func search(_ names: [String], prefix: String, after start: Int?, includeStart: Bool) -> Int? {
        let n = names.count
        let first = start.map { includeStart ? $0 : $0 + 1 } ?? 0
        for offset in 0..<n {
            let i = (first + offset) % n
            if matches(names[i], prefix) { return i }
        }
        return nil
    }
}
