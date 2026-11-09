import Foundation

public enum WindowsShortcutError: LocalizedError, Equatable, Sendable {
    case tooLarge, notDownloaded, unreadable, notAShortcut, malformed

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return L10n.tr("This file is too large to be a Windows shortcut.")
        case .notDownloaded: return L10n.tr("This shortcut is stored in the cloud and hasn't been downloaded. Download it, then try again.")
        case .unreadable: return L10n.tr("This shortcut couldn't be read.")
        case .notAShortcut: return L10n.tr("This file has a shortcut's extension, but it isn't a Windows shortcut.")
        case .malformed: return L10n.tr("This Windows shortcut is damaged, so Arbor won't use it.")
        }
    }
}

public enum WindowsShortcut: Equatable, Sendable {
    case link(ShellLink)
    case internet(InternetShortcut)

    /// Reads only a regular file, without following links, downloading a placeholder or taking more than the cap.
    public static func read(_ url: URL) throws -> WindowsShortcut {
        guard let kind = WindowsShortcutKind(fileName: url.lastPathComponent) else { throw WindowsShortcutError.notAShortcut }
        let bytes = try contents(of: url, limit: kind.maxFileBytes)
        switch kind {
        case .link: return .link(try ShellLink.parse(bytes))
        case .internet: return .internet(try InternetShortcut.parse(bytes))
        }
    }

    private static func contents(of url: URL, limit: Int) throws -> [UInt8] {
        guard let handle = FileHandle.openRegularFile(atPath: url.path) else { throw WindowsShortcutError.unreadable }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw WindowsShortcutError.unreadable }
        guard !info.isDataless else { throw WindowsShortcutError.notDownloaded }
        let data: Data
        do { data = try handle.read(upToCount: limit + 1) ?? Data() } catch { throw WindowsShortcutError.unreadable }
        guard data.count <= limit else { throw WindowsShortcutError.tooLarge }
        return [UInt8](data)
    }
}
