import Foundation

/// What the user meant when they put files on the clipboard (FE-084, spec §8.2).
///
/// Cut is an intent, not a Boolean: it only applies while the system pasteboard still
/// holds exactly the content this app wrote. Once another app (or another copy) changes
/// the pasteboard, a paste becomes a plain copy and cut marks disappear.
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
        let number = counts.string(from: NSNumber(value: n)) ?? "\(n)"
        return n == 1 ? "1 item" : "\(number) items"
    }

    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "12 items", "3 of 120 items match “rep”", plus "   2 selected · 4.1 MB".
    /// Size is shown only when every selected item has a known size.
    public static func summary(visible: Int, total: Int, query: String, selected: [FileItem]) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        var text = q.isEmpty ? items(total) : "\(counts.string(from: NSNumber(value: visible)) ?? "\(visible)") of \(items(total)) match “\(q)”"
        if !selected.isEmpty {
            text += "     \(selected.count) selected"
            let sizes = selected.compactMap(\.size)
            if sizes.count == selected.count { text += " · \(bytes(sizes.reduce(0, +)))" }
        }
        return text
    }

    /// Explorer's status bar wording: "12 items  |  1 item selected  4.1 KB  |".
    /// A filtered folder reads "3 of 120 items match “rep”  |". Size is shown only when every
    /// selected item has a known size (folders have none).
    public static func explorerSummary(visible: Int, total: Int, query: String, selected: [FileItem]) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = counts.string(from: NSNumber(value: visible)) ?? "\(visible)"
        var parts = [q.isEmpty ? (visible == total ? items(total) : "\(shown) of \(items(total))")   // column filters: "3 of 15 items"
                     : "\(shown) of \(items(total)) match “\(q)”"]
        if !selected.isEmpty {
            var text = selected.count == 1 ? "1 item selected" : "\(counts.string(from: NSNumber(value: selected.count)) ?? "\(selected.count)") items selected"
            let sizes = selected.compactMap(\.size)
            if sizes.count == selected.count { text += "  \(bytes(sizes.reduce(0, +)))" }
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
