import Foundation
import UniformTypeIdentifiers

/// What the disk says about a path. Injected so tests can prove which paths were touched.
public struct TargetProbe: Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Kind: Sendable { case directory, regularFile, other }
        public var kind: Kind
        public var device: Int32

        public init(kind: Kind, device: Int32) {
            self.kind = kind
            self.device = device
        }
    }

    /// `followLast` is true only for the floor, a folder the user is already in.
    public var entry: @Sendable (_ path: String, _ followLast: Bool) -> Entry?
    public var contentType: @Sendable (URL) -> UTType?
    public var isPackage: @Sendable (URL) -> Bool

    public init(entry: @escaping @Sendable (String, Bool) -> Entry?, contentType: @escaping @Sendable (URL) -> UTType?,
                isPackage: @escaping @Sendable (URL) -> Bool) {
        self.entry = entry
        self.contentType = contentType
        self.isPackage = isPackage
    }

    public static let disk = TargetProbe(
        entry: { path, followLast in
            var info = stat()
            guard (followLast ? stat(path, &info) : lstat(path, &info)) == 0 else { return nil }
            let kind: Entry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = .directory
            case S_IFREG: kind = .regularFile
            default: kind = .other
            }
            return Entry(kind: kind, device: info.st_dev)
        },
        contentType: { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType },
        isPackage: { (try? $0.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false })
}

/// Why a .lnk won't be followed; the UI shows `explanation`.
public enum LinkBlock: Equatable, Sendable {
    case hasArguments
    case windowsProgram(String)
    case driveLetter(String)
    case network(String)
    case windowsOnlyPath(String)
    case notFound(String)
    case noPath

    public var explanation: String {
        switch self {
        case .hasArguments:
            return L10n.tr("This shortcut starts its target with extra instructions (arguments). Arbor never runs a target with arguments.")
        case .windowsProgram(let name):
            return L10n.format("This shortcut points to “%@”, a Windows program. Windows programs can't run on a Mac.", "\(UntrustedText.display(name))")
        case .driveLetter(let path):
            return PathResolutionError.windowsDriveLetter(UntrustedText.display(path)).localizedDescription
        case .network(let path):
            return L10n.format("This shortcut points to “%@” on a network. Arbor doesn't connect to servers named in a shortcut. If you trust this server, you can connect to it from the address bar.", "\(UntrustedText.display(path))")
        case .windowsOnlyPath(let path):
            return L10n.format("This shortcut points to “%@”, which only means something on Windows.", "\(UntrustedText.display(path))")
        case .notFound(let path):
            return L10n.format("Arbor can't find “%@” on this Mac. It only follows a relative path that stays in the shortcut's folder, or anywhere on its drive if that isn't the startup disk.", "\(UntrustedText.display(path))")
        case .noPath:
            return L10n.tr("This shortcut doesn't record a file path. It may point to a Windows settings page or another special item.")
        }
    }
}

public enum LinkDestination: Equatable, Sendable {
    case folder(URL)
    /// A file of a kind that is safe to hand to its app, after confirmation.
    case document(URL)
    /// Exists, but may run code or change the Mac, so it can only be shown in its folder.
    case revealOnly(URL)
    case blocked(LinkBlock)
}

/// A shortcut and what opening it would do.
public enum WindowsShortcutInspection: Equatable, Sendable {
    case link(ShellLink, LinkDestination)
    case internet(InternetShortcut)
}

/// Decides what opening a Windows shortcut may do (FE-215); only a .lnk's relative path ever reaches the disk.
public enum WindowsShortcutPolicy {
    /// Off the main thread: reads the file and probes the disk.
    public static func inspect(_ url: URL, probe: TargetProbe = .disk) throws -> WindowsShortcutInspection {
        switch try WindowsShortcut.read(url) {
        case .internet(let shortcut):
            return .internet(shortcut)
        case .link(let link):
            let volumeRoot = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
            return .link(link, destination(for: link, shortcut: url, volumeRoot: volumeRoot, probe: probe))
        }
    }

    public static func destination(for link: ShellLink, shortcut: URL, volumeRoot: URL?, probe: TargetProbe) -> LinkDestination {
        if link.arguments?.isEmpty == false { return .blocked(.hasArguments) }
        let mapped = link.relativePath.flatMap { mappedTarget($0, shortcut: shortcut, volumeRoot: volumeRoot, probe: probe) }
        // Only the walk can tell a folder named next.js from a script; navigating inside the floor runs nothing.
        if case .folder(let folder)? = mapped { return .folder(folder) }
        if let program = windowsProgramName(in: link) { return .blocked(.windowsProgram(program)) }
        return mapped ?? .blocked(reasonNotMapped(link))
    }

    // MARK: Windows programs

    /// Can only refuse: `isDocument` is the real gate for files, so a name missing here still can't open.
    private static let windowsProgramExtensions: Set<String> = [
        "exe", "com", "bat", "cmd", "msi", "msp", "msix", "appx", "application", "appref-ms", "scr", "pif", "cpl", "ps1", "vbs",
        "vbe", "js", "jse", "wsf", "wsh", "hta", "msc", "reg", "dll", "sys",
    ]

    private static func windowsProgramName(in link: ShellLink) -> String? {
        for recorded in [link.localPath, link.networkPath, link.relativePath, link.environmentTarget].compactMap({ $0 }) {
            guard var name = recorded.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) else { continue }
            // Windows ignores these at the end of a name, so "evil.exe. " still runs.
            while name.last == "." || name.last == " " { name.removeLast() }
            if windowsProgramExtensions.contains((name as NSString).pathExtension.lowercased()) { return name }
        }
        return nil
    }

    // MARK: Following the relative path

    private static func mappedTarget(_ relative: String, shortcut: URL, volumeRoot: URL?, probe: TargetProbe) -> LinkDestination? {
        // A colon is a drive-relative path or an NTFS stream; neither exists here.
        guard !relative.unicodeScalars.contains(where: { $0 == ":" || $0.properties.generalCategory == .control }) else { return nil }
        let floor = self.floor(containing: shortcut, volumeRoot: volumeRoot)
        let entry = Array(shortcut.pathComponents.dropFirst(floor.pathComponents.count))
        let target = relative.replacingOccurrences(of: "\\", with: "/")
        guard let components = ArchivePath.resolvedLink(entry: entry, target: target),
              let found = walk(from: floor.path, through: components, probe: probe) else { return nil }
        let url = URL(fileURLWithPath: found.path, isDirectory: found.kind == .directory)
        if found.kind == .directory { return probe.isPackage(url) ? .revealOnly(url) : .folder(url) }
        return probe.contentType(url).map(isDocument) == true ? .document(url) : .revealOnly(url)
    }

    /// The shortcut's own folder on the startup disk, so a hostile `..` can't reach /net, /Volumes or /dev.
    private static func floor(containing shortcut: URL, volumeRoot: URL?) -> URL {
        let folder = shortcut.deletingLastPathComponent()
        guard let volumeRoot, volumeRoot.pathComponents.count > 1,
              folder.pathComponents.starts(with: volumeRoot.pathComponents) else { return folder }
        return volumeRoot
    }

    /// One non-following check per component, so a planted link can't trigger an automount or lead outside the floor.
    private static func walk(from floor: String, through components: [String],
                             probe: TargetProbe) -> (path: String, kind: TargetProbe.Entry.Kind)? {
        guard let start = probe.entry(floor, true), start.kind == .directory else { return nil }
        var path = floor
        var kind = start.kind
        for name in components {
            guard kind == .directory else { return nil }
            path = (path as NSString).appendingPathComponent(name)
            guard let entry = probe.entry(path, false), entry.device == start.device, entry.kind != .other else { return nil }
            kind = entry.kind
        }
        return (path, kind)
    }

    private static func reasonNotMapped(_ link: ShellLink) -> LinkBlock {
        let recorded = [link.localPath, link.relativePath].compactMap { $0 }
        if let path = recorded.first(where: PathResolver.isWindowsDrivePath) { return .driveLetter(path) }
        if let path = link.networkPath ?? recorded.first(where: { $0.hasPrefix("\\\\") }) { return .network(path) }
        if let path = link.environmentTarget ?? link.localPath { return .windowsOnlyPath(path) }
        if let path = link.relativePath { return .notFound(path) }
        return .noPath
    }

    // MARK: Which files may open

    private static let documentFamilies: [UTType] = [.pdf, .rtf, .plainText, .image, .audiovisualContent, .spreadsheet, .presentation]
        + ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document", "org.oasis-open.opendocument.text",
           "com.apple.iwork.pages.sffpages"].compactMap(UTType.init)

    /// Members of those families that run code or fetch from a network (DEC-winlink-10).
    private static let excludedMembers: [UTType] = [.sourceCode, .executable, .svg, .m3uPlaylist]
        + ["com.microsoft.advanced-stream-redirector", "com.real.realaudio"].compactMap(UTType.init)

    /// A positive list: a type nobody has named here is never opened from a shortcut.
    static func isDocument(_ type: UTType) -> Bool {
        documentFamilies.contains { type.conforms(to: $0) } && !excludedMembers.contains { type.conforms(to: $0) }
    }
}
