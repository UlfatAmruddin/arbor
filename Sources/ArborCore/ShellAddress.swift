import Foundation

/// Windows `shell:` folder names mapped to Mac places (FE-213); constant tables, so typed text never starts anything.
public enum ShellAddress {
    public enum Outcome: Equatable {
        case place(Location)
        /// Home's Recent list is the real counterpart.
        case recentFiles
        case handoff(AddressHandoffTarget)
        case noCounterpart(String)
        case unknown(String)
    }

    public enum CommandOutcome: Equatable {
        case handoff(AddressHandoffTarget)
        case refused(String)
    }

    private enum Target: Sendable {
        case homeFolder
        case inHome(String)
        case absolute(String)
        case place(Location)
        case recentFiles
        case noCounterpart(@Sendable () -> String)
    }

    private static let prefix = "shell:"
    private static let echoLimit = 64

    // Reasons are closures so each lookup uses the current language.
    private static let table: [(names: [String], target: Target)] = [
        (["desktop"], .inHome("Desktop")),
        (["downloads"], .inHome("Downloads")),
        (["personal", "documents"], .inHome("Documents")),
        (["my pictures", "pictures"], .inHome("Pictures")),
        (["my music", "music"], .inHome("Music")),
        (["my video", "videos", "movies"], .inHome("Movies")),
        (["profile"], .homeFolder),
        (["userprofiles"], .absolute("/Users")),
        (["public"], .absolute("/Users/Shared")),
        (["appsfolder"], .absolute("/Applications")),
        (["appdata"], .inHome("Library/Application Support")),
        (["recent"], .recentFiles),
        (["recyclebinfolder"], .place(.trash)),
        (["mycomputerfolder"], .place(.thisMac)),
        (["networkplacesfolder"], .place(.network)),
        (["libraries"], .place(.library(LibraryLogic.rootName))),
        (["start menu", "programs", "common programs"], .noCounterpart { L10n.tr("Macs have no Start menu. Apps are in the Applications folder.") }),
        (["sendto"], .noCounterpart { L10n.tr("Macs have no Send to folder.") }),
        (["windows", "system", "programfiles"], .noCounterpart { L10n.tr("This Windows system folder has no Mac counterpart.") }),
    ]

    static func hasPrefix(_ text: String) -> Bool { text.lowercased().hasPrefix(prefix) }

    /// nil unless the text is a `shell:` address.
    public static func outcome(for text: String, homeDirectory: URL) -> Outcome? {
        let address = PathResolver.unquoted(text)
        guard hasPrefix(address) else { return nil }
        let name = String(address.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return .noCounterpart(L10n.tr("Type a name after “shell:”, for example shell:downloads.")) }
        if name.hasPrefix("::") { return .noCounterpart(L10n.tr("Windows folder IDs aren't supported. Try a name such as shell:downloads.")) }
        let key = name.lowercased()
        if let handoff = AddressHandoffTarget.forShellName(key) { return .handoff(handoff) }
        guard let target = table.first(where: { $0.names.contains(key) })?.target else { return .unknown(echoed(name)) }
        switch target {
        case .homeFolder: return .place(.folder(homeDirectory))
        case .inHome(let path): return .place(.folder(homeDirectory.appendingPathComponent(path, isDirectory: true)))
        case .absolute(let path): return .place(.folder(URL(fileURLWithPath: path, isDirectory: true)))
        case .place(let location): return .place(location)
        case .recentFiles: return .recentFiles
        case .noCounterpart(let reason): return .noCounterpart(reason())
        }
    }

    /// Words with no sensible Mac tool; the ones that have one are in `AddressHandoffTarget.table`.
    private static let commandWords: Set<String> = ["notepad", "calc", "mspaint", "regedit", "explorer"]
    private static let commandSuffixes = [".exe", ".bat", ".cmd", ".ps1", ".msi"]

    /// Whether a bare first word looks like a Windows program; path-shaped text keeps the resolver's own error.
    static func isWindowsCommand(_ text: String) -> Bool {
        guard let word = PathResolver.unquoted(text).split(whereSeparator: \.isWhitespace).first?.lowercased(),
              !word.contains("/"), !word.contains("\\"), !word.hasPrefix("~") else { return false }
        return commandWords.contains(word) || AddressHandoffTarget.forWord(word) != nil || commandSuffixes.contains(where: word.hasSuffix)
    }

    /// nil unless the text starts with a Windows command word. A hand-off needs the word alone: extra text is refused, never passed on.
    public static func commandOutcome(for text: String) -> CommandOutcome? {
        guard isWindowsCommand(text) else { return nil }
        let words = PathResolver.unquoted(text).split(whereSeparator: \.isWhitespace)
        guard let word = words.first?.lowercased(), let target = AddressHandoffTarget.forWord(word) else {
            return .refused(commandMessage(for: text))
        }
        guard words.count == 1 else {
            return .refused(L10n.format("Arbor doesn't pass typed text to other apps. Type “%@” on its own to open %@.", word, target.appName))
        }
        return .handoff(target)
    }

    /// Stays true when the user meant a folder called `control`.
    static func commandMessage(for text: String) -> String {
        L10n.format("Can't find “%@”. Arbor doesn't run commands from the address bar.", echoed(PathResolver.unquoted(text)))
    }

    public static func unknownNameMessage(_ name: String) -> String {
        L10n.format("Arbor doesn't know the shell name “%@”.", name)
    }

    /// The ellipsis keeps a shortened echo from reading like text the user typed.
    private static func echoed(_ text: String) -> String {
        text.count > echoLimit ? text.prefix(echoLimit) + "…" : text
    }
}
