import Foundation

/// A file type offered in New ▸ (FE-088). Every template is a complete, valid file of its format:
/// an empty `.docx` is not a document, so formats we can't produce correctly are simply not offered.
public struct NewItemTemplate: Sendable, Equatable, Identifiable {
    /// Stable id, also the command id suffix ("file.new.txt").
    public let id: String
    /// Title in New ▸, Windows wording ("Text Document").
    public let menuTitle: String
    /// Base name of the created file, Windows wording ("New Text Document").
    public let baseName: String
    public let fileExtension: String
    public let contents: Data

    public init(id: String, menuTitle: String, baseName: String, fileExtension: String, contents: Data) {
        self.id = id
        self.menuTitle = menuTitle
        self.baseName = baseName
        self.fileExtension = fileExtension
        self.contents = contents
    }
}

public enum NewItemTemplates {
    /// "New Bitmap image.bmp": a valid 1×1 white 24-bit BMP (Windows writes a zero-byte file, which
    /// most Mac image apps refuse to open).
    public static let bitmap = NewItemTemplate(
        id: "bmp", menuTitle: L10n.tr("Bitmap image"), baseName: L10n.tr("New Bitmap image"), fileExtension: "bmp",
        contents: bitmapData(width: 1, height: 1))

    /// "New Rich Text Document.rtf": a minimal, valid RTF document with one empty paragraph.
    public static let richText = NewItemTemplate(
        id: "rtf", menuTitle: L10n.tr("Rich Text Document"), baseName: L10n.tr("New Rich Text Document"), fileExtension: "rtf",
        contents: Data(#"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}}\f0\fs24\par}"#.utf8))

    /// "New Text Document.txt": an empty plain-text file, like Explorer.
    public static let text = NewItemTemplate(
        id: "txt", menuTitle: L10n.tr("Text Document"), baseName: L10n.tr("New Text Document"), fileExtension: "txt", contents: Data())

    /// In Windows order (alphabetical by display name). "Compressed (zipped) Folder" belongs between
    /// Bitmap image and Rich Text Document and is registered by the archives feature.
    public static let all: [NewItemTemplate] = [bitmap, richText, text]

    /// "New Text Document.txt", then "New Text Document (2).txt", "New Text Document (3).txt"…
    public static func uniqueName(base: String, ext: String?, isTaken: (String) -> Bool) -> String {
        func join(_ b: String) -> String { ext.map { "\(b).\($0)" } ?? b }
        if !isTaken(join(base)) { return join(base) }
        var n = 2
        while isTaken(join("\(base) (\(n))")) { n += 1 }
        return join("\(base) (\(n))")
    }

    /// Creates the template in `folder` under the next free Windows-style name. Never overwrites:
    /// if a file appears under the chosen name in the meantime, the next number is tried.
    @discardableResult
    public static func create(_ template: NewItemTemplate, in folder: URL) throws -> URL {
        for _ in 0..<50 {
            let name = uniqueName(base: template.baseName, ext: template.fileExtension) {
                FileOps.exists(folder.appendingPathComponent($0))
            }
            let url = folder.appendingPathComponent(name)
            do {
                try template.contents.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// An uncompressed 24-bit BMP (BITMAPINFOHEADER) filled with white.
    public static func bitmapData(width: Int, height: Int) -> Data {
        let rowBytes = (width * 3 + 3) & ~3
        let pixelBytes = rowBytes * height
        let offset = 14 + 40
        var data = Data()
        func u16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) { (0..<4).forEach { data.append(UInt8((v >> ($0 * 8)) & 0xFF)) } }
        data.append(contentsOf: [0x42, 0x4D])        // "BM"
        u32(offset + pixelBytes)                      // file size
        u32(0)                                        // reserved
        u32(offset)                                   // pixel data offset
        u32(40)                                       // header size
        u32(width)
        u32(height)                                   // positive: bottom-up rows
        u16(1)                                        // planes
        u16(24)                                       // bits per pixel
        u32(0)                                        // BI_RGB, no compression
        u32(pixelBytes)
        u32(2835)                                     // 72 dpi in pixels per metre
        u32(2835)
        u32(0)                                        // palette colors
        u32(0)                                        // important colors
        let row = [UInt8](repeating: 0xFF, count: width * 3) + [UInt8](repeating: 0, count: rowBytes - width * 3)
        for _ in 0..<height { data.append(contentsOf: row) }
        return data
    }
}

/// Names for shortcuts (macOS aliases) and symbolic links, Windows style (FE-092).
public enum ShortcutNaming {
    /// "Report.pdf - Shortcut", then "Report.pdf - Shortcut (2)". Explorer keeps the target's
    /// full name (with its extension) and appends " - Shortcut"; the alias itself has no extension.
    public static func shortcutName(for targetName: String, isTaken: (String) -> Bool) -> String {
        numbered("\(targetName) - Shortcut", isTaken: isTaken)
    }

    /// "Report.pdf - Symbolic link", then "… (2)". Clearly different from a shortcut.
    public static func symbolicLinkName(for targetName: String, isTaken: (String) -> Bool) -> String {
        numbered("\(targetName) - Symbolic link", isTaken: isTaken)
    }

    /// A name typed in the Create Shortcut wizard, made unique the same way.
    public static func numbered(_ name: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(name) { return name }
        var n = 2
        while isTaken("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }

    /// The name the Create Shortcut wizard proposes for a target: its name without the extension
    /// for files ("notes.txt" → "notes"), the name for folders, the host for web addresses.
    public static func wizardDefaultName(for target: URL, isFolder: Bool) -> String {
        if !target.isFileURL { return target.host ?? "New Internet Shortcut" }
        let name = target.lastPathComponent
        if isFolder || name == "/" { return name == "/" ? "Macintosh HD" : name }
        let base = NameRules.splitExtension(name, treatAsFolder: false).base
        return base.isEmpty ? name : base
    }
}

/// A `.webloc` file: the Mac's Internet shortcut (Windows `.url`), a property list holding one URL.
public enum WebLocation {
    public static func data(for url: URL) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }

    public static func url(from data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = plist["URL"] as? String else { return nil }
        return URL(string: text)
    }

    /// Accepts "https://…", "http://…" and "www.example.com" as web addresses.
    public static func parseWebAddress(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: t), url.host?.isEmpty == false else { return nil }
            return url
        }
        if lower.hasPrefix("www."), !t.contains(" "), let url = URL(string: "https://" + t) { return url }
        return nil
    }
}
