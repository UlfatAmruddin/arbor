import Foundation

/// Address history as completion rows (FE-006). Works on strings only, so it is safe on every keystroke.
extension PathCompletion {
    /// Leaves room for the folder's own names.
    static let historyRowLimit = 4

    /// Recent folders first, newest on top. A folder already listed keeps its plain row.
    public static func addingHistory(_ folderPaths: [String], to listed: (rows: [PathCompletionCandidate], hasMore: Bool),
                                     for query: PathCompletionQuery, includeHidden: Bool) -> (rows: [PathCompletionCandidate], hasMore: Bool) {
        let listedTexts = Set(listed.rows.map(\.text))
        var history: [PathCompletionCandidate] = []
        for path in folderPaths where history.count < historyRowLimit {
            guard let row = historyRow(path, query: query, includeHidden: includeHidden || query.typedName.hasPrefix(".")),
                  !listedTexts.contains(row.text) else { continue }
            history.append(row)
        }
        let rows = history + listed.rows
        return (Array(rows.prefix(rowLimit)), listed.hasMore || rows.count > rowLimit)
    }

    private static func historyRow(_ path: String, query: PathCompletionQuery, includeHidden: Bool) -> PathCompletionCandidate? {
        let root = query.folder.path == "/" ? "/" : query.folder.path + "/"
        guard path.hasPrefix(root) else { return nil }
        let name = String(path.dropFirst(root.count))
        guard !name.isEmpty, matches(name, query.typedName) else { return nil }
        let parts = name.split(separator: "/")
        guard parts.allSatisfy({ isDisplayable(String($0)) && (includeHidden || !$0.hasPrefix(".")) }) else { return nil }
        let text = query.literalPrefix + name + "/"
        guard leads(text, to: path, query: query) else { return nil }
        return PathCompletionCandidate(text: text, name: name, isFolder: true, isFromHistory: true)
    }
}
