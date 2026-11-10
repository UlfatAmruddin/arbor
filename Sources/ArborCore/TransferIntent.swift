import Foundation

/// What the user meant by putting files on the clipboard (FE-084, spec §8.2). Cut holds only while the
/// pasteboard has exactly what Arbor wrote; once it changes, paste is a copy and cut marks disappear.
public struct TransferIntent: Equatable, Sendable {
    public let kind: TransferKind
    public let urls: [URL]
    public let pasteboardChangeCount: Int

    public init(kind: TransferKind, urls: [URL], pasteboardChangeCount: Int) {
        self.kind = kind
        self.urls = urls.map(\.standardizedFileURL)
        self.pasteboardChangeCount = pasteboardChangeCount
    }

    public func isCurrent(changeCount: Int) -> Bool { changeCount == pasteboardChangeCount }

    public func marksCut(_ url: URL, changeCount: Int) -> Bool {
        kind == .move && isCurrent(changeCount: changeCount) && urls.contains(url.standardizedFileURL)
    }

    public static func pasteKind(intent: TransferIntent?, changeCount: Int, pasteboardURLs: [URL]) -> TransferKind {
        guard let intent, intent.kind == .move, intent.isCurrent(changeCount: changeCount),
              Set(intent.urls) == Set(pasteboardURLs.map(\.standardizedFileURL)) else { return .copy }
        return .move
    }
}

public enum StatusText {
    private static let counts: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    public static func items(_ n: Int) -> String {
        L10n.plural(one: "%lld item", other: "%lld items", n)
    }

    /// Explorer's adaptive 1024-based size (three significant digits); the Size column uses `ExplorerSize.detailsColumn`.
    public static func bytes(_ n: Int64) -> String {
        ExplorerSize.adaptive(n)
    }

    /// "12 items", "3 of 120 items match “rep”", plus "   2 selected · 4.1 MB" (size only if all are known).
    public static func summary(visible: Int, total: Int, query: String, selected: [FileItem]) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        var text = q.isEmpty ? items(total) : L10n.format("%@ of %@ match “%@”", number(visible), items(total), q)
        if !selected.isEmpty {
            text += "     " + L10n.plural(one: "%lld selected", other: "%lld selected", selected.count)
            let sizes = selected.compactMap(\.size)
            if sizes.count == selected.count { text += " · \(bytes(sizes.saturatingSum()))" }
        }
        return text
    }

    /// Explorer's status bar: "12 items  |  1 item selected  4.1 KB  |"; filtered: "3 of 120 items match “rep”  |". Size only when every selected item has one.
    public static func explorerSummary(visible: Int, total: Int, query: String, selected: [FileItem]) -> String {
        let sizes = selected.compactMap(\.size)
        return explorerSummary(visible: visible, total: total, query: query, selectedCount: selected.count,
                               selectedBytes: sizes.count == selected.count ? sizes.saturatingSum() : nil)
    }

    /// The same for pages whose rows aren't files; nil `selectedBytes` shows no size.
    public static func explorerSummary(visible: Int, total: Int, query: String, selectedCount: Int, selectedBytes: Int64?) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = number(visible)
        var parts = [q.isEmpty ? (visible == total ? items(total) : L10n.format("%@ of %@", shown, items(total)))   // column filters: "3 of 15 items"
                     : L10n.format("%@ of %@ match “%@”", shown, items(total), q)]
        if selectedCount > 0 {
            var text = L10n.plural(one: "%lld item selected", other: "%lld items selected", selectedCount)
            if let selectedBytes { text += "  \(bytes(selectedBytes))" }
            parts.append(text)
        }
        return parts.map { $0 + "  |" }.joined(separator: "  ")
    }
}

/// "Copy as path" text: each path in double quotes, one per line, like Explorer (FE-085).
public enum CopyAsPath {
    public static func text(for paths: [String]) -> String {
        paths.map { "\"\($0)\"" }.joined(separator: "\n")
    }
}
