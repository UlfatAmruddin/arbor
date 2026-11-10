import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// The embedded properties Arbor can edit (FE-152).
public enum EmbeddedField: String, CaseIterable, Sendable {
    case title, subject, author, keywords, category, description, rating, dateTaken, artist, album, year, track, genre, comment

    public var label: String {
        switch self {
        case .title: return L10n.tr("Title")
        case .subject: return L10n.tr("Subject")
        case .author: return L10n.tr("Authors")
        case .keywords: return L10n.tr("Keywords")
        case .category: return L10n.tr("Categories")
        case .description: return L10n.tr("Description")
        case .rating: return L10n.tr("Rating")
        case .dateTaken: return L10n.tr("Date taken")
        case .artist: return L10n.tr("Contributing artists")
        case .album: return L10n.tr("Album")
        case .year: return L10n.tr("Year")
        case .track: return "#"
        case .genre: return L10n.tr("Genre")
        case .comment: return L10n.tr("Comments")
        }
    }
}

/// What ImageIO's lossless copy really stores per type; the audit is in docs/features/properties.md.
public struct EmbeddedSupport: Equatable, Sendable {
    public let fields: Set<EmbeddedField>
    /// HEIC and TIFF ignore the removal of a date.
    public let canRemoveDate: Bool

    private static let table: [String: EmbeddedSupport] = [
        UTType.jpeg.identifier: EmbeddedSupport(fields: [.title, .description, .rating, .dateTaken], canRemoveDate: true),
        // The description and date live in a legacy Exif copy the lossless path leaves behind.
        UTType.heic.identifier: EmbeddedSupport(fields: [.title, .rating], canRemoveDate: false),
        UTType.tiff.identifier: EmbeddedSupport(fields: [.title, .rating, .dateTaken], canRemoveDate: false),
        ID3Format.identifier: audio, FLACFormat.identifier: audio, M4AFormat.identifier: audio,
        PDFFormat.identifier: EmbeddedSupport(fields: [.title, .subject, .author, .keywords], canRemoveDate: false),
        OfficeFormat.identifier: EmbeddedSupport(fields: [.title, .subject, .author, .keywords, .category, .comment], canRemoveDate: false),
    ]

    private static let audio = EmbeddedSupport(fields: [.title, .artist, .album, .year, .track, .genre, .comment], canRemoveDate: false)

    /// Sound rather than a picture, which is all the Details tab's wording depends on.
    public var isAudio: Bool { fields.contains(.artist) }

    /// A PDF or Office document.
    public var isDocument: Bool { fields.contains(.author) }

    public static func forType(_ identifier: String) -> EmbeddedSupport? { table[identifier] }
}

/// Bounds on what is read from a file, all of it hostile until proven otherwise.
public enum EmbeddedLimits {
    public static let maxFileBytes: Int64 = 512 << 20
    /// Formats that stream the file through instead of holding it; the bound is only how long a save may take.
    public static let maxStreamedFileBytes: Int64 = 16 << 30
    public static let maxFrames = 64
    /// At most 2 GiB decoded even at 16 bits per channel; one frame at a time is held.
    public static let maxTotalPixels: Int64 = 256_000_000
    public static let maxTitleLength = 1024
    public static let maxDescriptionLength = 8192
}

public enum EmbeddedFailure: Error, LocalizedError, Equatable {
    case changedSinceRead, tooLarge, tooManyPixels, unsupportedFile, locked, hardLinked, volumeCannotSwap, readOnly, manufacturerData
    case invalidValue(String), notEditable, cannotRemoveDate, verificationFailed, writeFailed, trashFailed, changedSinceSaved
    /// `reason` says what about this file's own structure keeps it read-only.
    case structure(String)
    case soundUnverified, noRoomBesideMetadata, documentUnverified
    /// Another app got in during the swap. `keptAt` is where the set-aside file stayed; nil means it reached the Trash.
    case interrupted(keptAt: String?)

    /// True when what is on disk may no longer be what was read.
    public var fileMayHaveChanged: Bool {
        switch self {
        case .changedSinceRead, .interrupted: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .changedSinceRead: return L10n.tr("The file changed after these properties were read, so nothing was written. They have been read again; make your changes again if you still want them.")
        case .tooLarge: return L10n.tr("This file is too large to edit its properties safely.")
        case .tooManyPixels: return L10n.tr("This image has too many pixels to verify a change safely.")
        case .unsupportedFile: return L10n.tr("This file can't be edited.")
        case .locked: return L10n.tr("The file is locked. Unlock it, then try again.")
        case .hardLinked: return L10n.tr("Other names point to this file (hard links), and replacing it would separate them.")
        case .volumeCannotSwap: return L10n.tr("This disk can't replace a file in one step, so properties aren't edited here.")
        case .readOnly: return L10n.tr("The file or its folder can't be written to.")
        case .manufacturerData: return L10n.tr("This photo holds data that rewriting its properties would lose, so they can't be edited here.")
        case .invalidValue(let reason): return reason
        case .notEditable: return L10n.tr("This property can't be changed in this file.")
        case .cannotRemoveDate: return L10n.tr("This type of file can't have its date taken removed.")
        case .verificationFailed: return L10n.tr("The change couldn't be verified as harmless to the image, so the file wasn't changed.")
        case .writeFailed: return L10n.tr("The properties couldn't be written, so the file wasn't changed.")
        case .trashFailed: return L10n.tr("The original couldn't be moved to the Trash, so it wasn't replaced.")
        case .changedSinceSaved: return L10n.tr("The file or its previous version changed since the edit.")
        case .structure(let reason): return reason
        case .soundUnverified: return L10n.tr("The change couldn't be verified as harmless to the audio, so the file wasn't changed.")
        case .documentUnverified: return L10n.tr("The change couldn't be verified as harmless to the document, so the file wasn't changed.")
        case .noRoomBesideMetadata: return L10n.tr("There isn't enough free space inside this file to store that without moving its audio, so nothing was changed.")
        case .interrupted(nil): return L10n.tr("Another app changed the file while it was being replaced. The version set aside is in the Trash; check the file before relying on it.")
        case .interrupted(let path?): return L10n.format("Another app changed the file while it was being replaced, and the version set aside couldn't go to the Trash. It is at %@; copy it somewhere safe, because that folder is temporary.", path)
        }
    }
}

/// One file's embedded properties as read, and which can be edited. Off the main thread; only headers are parsed.
public struct EmbeddedSnapshot: Sendable {
    public let url: URL
    public let stamp: FileStamp
    public let typeIdentifier: String
    /// Safe to show: control characters removed, length capped. Date in `EmbeddedDate` Exif form.
    public let values: [EmbeddedField: String]
    /// Empty when `blocked` is set.
    public let editable: Set<EmbeddedField>
    /// Why this file can't be rewritten at all.
    public let blocked: EmbeddedFailure?
    public let support: EmbeddedSupport

    /// nil for anything that isn't a regular file of an editable type.
    public static func read(_ url: URL) -> EmbeddedSnapshot? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let stamp = FileStamp(info)
        guard let (format, found) = EmbeddedFormats.inspect(url, info: info) else { return nil }
        guard FileStamp(url)?.sameState(as: stamp) == true else { return nil }

        var shown: [EmbeddedField: String] = [:]
        var plain = Set<EmbeddedField>()
        for (field, raw) in found.fields {
            let cleaned = EmbeddedText.clean(raw.text, limit: EmbeddedText.limit(field))
            shown[field] = cleaned.text
            if cleaned.isExact, raw.canEdit, field != .dateTaken || EmbeddedDate.isValidExif(raw.text) { plain.insert(field) }
        }
        let blocked = blockReason(url, info, limit: format.maxFileBytes, found)
        let offered = found.support.fields.filter { found.fields[$0] == nil || plain.contains($0) }
        return EmbeddedSnapshot(url: url, stamp: stamp, typeIdentifier: found.typeIdentifier, values: shown,
                                editable: blocked == nil ? offered : [], blocked: blocked, support: found.support)
    }

    /// A rename doesn't change the file, so the stamp still identifies what was read.
    public func moved(to newURL: URL) -> EmbeddedSnapshot {
        EmbeddedSnapshot(url: newURL, stamp: stamp, typeIdentifier: typeIdentifier, values: values, editable: editable,
                         blocked: blocked, support: support)
    }

    private static func blockReason(_ url: URL, _ info: stat, limit: Int64, _ found: EmbeddedInspection) -> EmbeddedFailure? {
        if Int64(info.st_size) > limit { return .tooLarge }
        if let budget = found.budgetBlock { return budget }
        if info.st_nlink > 1 { return .hardLinked }
        if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .locked }
        if access(url.path, W_OK) != 0 || access(url.deletingLastPathComponent().path, W_OK) != 0 { return .readOnly }
        if let mount = FileOps.mountPoint(of: url),
           VolumeCapabilities.interfaceCapability(mount, UInt32(VOL_CAP_INT_RENAME_SWAP)) == false { return .volumeCannotSwap }
        return found.contentBlock
    }
}

/// Reads the four fields out of an image source. ImageIO reconciles XMP, IPTC and TIFF into its property dictionaries.
enum EmbeddedReader {
    struct Raw: Equatable {
        var text: String
        /// False for a value a rewrite would lose or can't reproduce (other languages, an impossible rating).
        var canEdit = true
    }

    /// nil when the first frame's properties can't be read.
    static func values(in source: CGImageSource) -> [EmbeddedField: Raw]? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var out: [EmbeddedField: Raw] = [:]
        out[.title] = text(metadata, "dc:title", fallback: iptc[kCGImagePropertyIPTCObjectName])
        out[.description] = text(metadata, "dc:description",
                                 fallback: tiff[kCGImagePropertyTIFFImageDescription] ?? iptc[kCGImagePropertyIPTCCaptionAbstract])
        if let rating = rating(iptc[kCGImagePropertyIPTCStarRating]) { out[.rating] = rating }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !date.isEmpty { out[.dateTaken] = Raw(text: date) }
        return out
    }

    /// Prefers XMP, which alone can say a title has other languages; shows the default one, else the first listed.
    private static func text(_ metadata: CGImageMetadata?, _ path: String, fallback: Any?) -> Raw? {
        if let metadata, let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
           let value = CGImageMetadataTagCopyValue(tag) {
            if let plain = value as? String { return plain.isEmpty ? nil : Raw(text: plain) }
            if let languages = value as? [String: Any] {
                let chosen = languages["x-default"] ?? languages.keys.sorted().first.flatMap { languages[$0] }
                if let text = chosen.flatMap(tagText), !text.isEmpty { return Raw(text: text, canEdit: languages.count <= 1) }
            } else if let items = value as? [Any], let text = items.first.flatMap(tagText), !text.isEmpty {
                return Raw(text: text, canEdit: items.count <= 1)
            }
        }
        return (fallback as? String).flatMap { $0.isEmpty ? nil : Raw(text: $0) }
    }

    private static func tagText(_ item: Any) -> String? {
        if let plain = item as? String { return plain }
        guard CFGetTypeID(item as CFTypeRef) == CGImageMetadataTagGetTypeID() else { return nil }
        return unsafeDowncast(item as CFTypeRef, to: CGImageMetadataTag.self).valueString
    }

    /// Out of 5; nil when absent or zero (no rating). A value outside 0...5 stays visible but is not offered as a choice.
    private static func rating(_ value: Any?) -> Raw? {
        guard let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init),
              let whole = Int(checked: number) else { return nil }
        if Double(whole) == number, (0...5).contains(whole) { return whole == 0 ? nil : Raw(text: String(whole)) }
        return Raw(text: String(whole), canEdit: false)
    }

    /// Refuses a source whose frames can't be counted or would decode past `EmbeddedLimits`.
    static func checkPixelBudget(_ source: CGImageSource) throws {
        let frames = CGImageSourceGetCount(source)
        guard frames > 0 else { throw EmbeddedFailure.unsupportedFile }
        guard frames <= EmbeddedLimits.maxFrames else { throw EmbeddedFailure.tooManyPixels }
        var total: Int64 = 0
        for index in 0..<frames {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
                  let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
                  width > 0, height > 0 else { throw EmbeddedFailure.unsupportedFile }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow else { throw EmbeddedFailure.tooManyPixels }
            total = total.saturatingAdd(pixels)
            guard total <= EmbeddedLimits.maxTotalPixels else { throw EmbeddedFailure.tooManyPixels }
        }
    }
}

extension CGImageMetadataTag {
    fileprivate var valueString: String? { CGImageMetadataTagCopyValue(self).flatMap { $0 as? String } }
}

/// Keeps file-supplied text from misleading the display, and tells whether showing it changed it.
public enum EmbeddedText {
    public static func limit(_ field: EmbeddedField) -> Int {
        field == .description || field == .comment || field == .keywords ? EmbeddedLimits.maxDescriptionLength : EmbeddedLimits.maxTitleLength
    }

    public static func clean(_ raw: String, limit: Int) -> (text: String, isExact: Bool) {
        var kept = String.UnicodeScalarView()
        var dropped = false
        var count = 0
        for scalar in raw.unicodeScalars {
            if count == limit { dropped = true; break }
            count += 1
            if isUnsafe(scalar) { dropped = true } else { kept.append(scalar) }
        }
        return (String(kept), !dropped)
    }

    /// Control characters other than tab and line breaks, and direction overrides that can disguise text.
    public static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
        if scalar.properties.generalCategory == .control { return true }
        return (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
}

/// "Date taken" kept as Exif's own text, so editing never moves a photo between time zones.
public enum EmbeddedDate {
    private static let exifShape = "dddd:dd:dd dd:dd:dd"

    /// True for a real "2024:03:07 14:30:00".
    public static func isValidExif(_ text: String) -> Bool { parts(text) != nil }

    /// "2024-03-07 14:30:00" for display, nil when the text isn't valid Exif.
    public static func display(fromExif text: String) -> String? {
        guard let p = parts(text) else { return nil }
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", p[0], p[1], p[2], p[3], p[4], p[5])
    }

    /// Accepts "2024-03-07", "2024-03-07 14:30" and "2024-03-07 14:30:00".
    public static func exif(fromDisplay text: String) -> String? {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
        guard (1...2).contains(pieces.count) else { return nil }
        let date = pieces[0].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let time = pieces.count == 2 ? pieces[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init) : ["0", "0", "0"]
        guard date.count == 3, date[0].count == 4, (2...3).contains(time.count) else { return nil }
        let numbers = (date + time + ["0"]).prefix(6).map { Int($0) ?? -1 }
        guard numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        let result = String(format: "%04d:%02d:%02d %02d:%02d:%02d", numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5])
        return isValidExif(result) ? result : nil
    }

    private static func parts(_ text: String) -> [Int]? {
        let scalars = Array(text.utf8)
        guard scalars.count == exifShape.utf8.count else { return nil }
        for (byte, shape) in zip(scalars, exifShape.utf8) {
            if shape == UInt8(ascii: "d") ? !(48...57).contains(byte) : byte != shape { return nil }
        }
        func number(_ start: Int, _ length: Int) -> Int { scalars[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - 48) } }
        let p = [number(0, 4), number(5, 2), number(8, 2), number(11, 2), number(14, 2), number(17, 2)]
        var components = DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4], second: p[5])
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        guard p[0] >= 1, components.isValidDate else { return nil }
        return p
    }
}

/// Turns what was typed into the edits to write. Unchanged fields are left out; "" removes a value.
public enum EmbeddedEdits {
    /// `typed`: rating as "0"..."5" (0 = none), date in `EmbeddedDate` display form.
    public static func make(from typed: [EmbeddedField: String], snapshot: EmbeddedSnapshot) throws -> [EmbeddedField: String] {
        var edits: [EmbeddedField: String] = [:]
        for (field, text) in typed where snapshot.editable.contains(field) {
            let value = try canonical(text, field, snapshot)
            if value != (snapshot.values[field] ?? "") { edits[field] = value }
        }
        return edits
    }

    private static func canonical(_ text: String, _ field: EmbeddedField, _ snapshot: EmbeddedSnapshot) throws -> String {
        switch field {
        case .title, .subject, .author, .keywords, .category, .description, .artist, .album, .genre, .comment:
            guard text.count <= EmbeddedText.limit(field) else { throw EmbeddedFailure.invalidValue(L10n.format("%@ is too long.", "\(field.label)")) }
            // XML can't hold U+FFFE or U+FFFF, and reads a carriage return back as a line feed.
            let unstorable: (Unicode.Scalar) -> Bool = { snapshot.support.isDocument && ($0 == "\r" || $0.value == 0xFFFE || $0.value == 0xFFFF) }
            guard !text.unicodeScalars.contains(where: { EmbeddedText.isUnsafe($0) || unstorable($0) }) else {
                throw EmbeddedFailure.invalidValue(L10n.format("%@ contains characters that can't be stored.", "\(field.label)"))
            }
            // ID3 reads a leading bracket or a bare number as a code from its fixed genre list.
            if field == .genre, text != snapshot.values[.genre] ?? "", text.hasPrefix("(") || (!text.isEmpty && text.allSatisfy(\.isNumber)) {
                throw EmbeddedFailure.invalidValue(L10n.tr("Enter the genre as a name."))
            }
            return text
        case .rating:
            guard let n = Int(text), (0...5).contains(n) else { throw EmbeddedFailure.invalidValue(L10n.tr("A rating must be between 0 and 5.")) }
            return n == 0 ? "" : String(n)
        case .dateTaken:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                guard snapshot.support.canRemoveDate || snapshot.values[.dateTaken] == nil else { throw EmbeddedFailure.cannotRemoveDate }
                return ""
            }
            guard let exif = EmbeddedDate.exif(fromDisplay: trimmed) else {
                throw EmbeddedFailure.invalidValue(L10n.tr("Enter the date taken as YYYY-MM-DD HH:MM:SS."))
            }
            return exif
        case .year:
            // Stray spaces already in the file aren't the user's input.
            if text == snapshot.values[.year] { return text }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed == snapshot.values[.year] || isFourDigits(trimmed) else {
                throw EmbeddedFailure.invalidValue(L10n.tr("Enter the year as four digits."))
            }
            return trimmed
        case .track:
            if text == snapshot.values[.track] { return text }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == snapshot.values[.track] { return trimmed }
            guard let track = EmbeddedTrack(trimmed) else {
                throw EmbeddedFailure.invalidValue(L10n.tr("Enter the track as a number, or a number and a total such as 3/12."))
            }
            return track.text
        }
    }

    private static func isFourDigits(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 4 && bytes.allSatisfy { (48...57).contains($0) }
    }
}

/// A track position: M4A stores both numbers in sixteen bits, so every format keeps to that range.
struct EmbeddedTrack: Equatable {
    let number: UInt16
    /// Zero when there is none.
    let total: UInt16

    /// "3" or "3/12".
    init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let number = Self.number(parts[0]), number > 0 else { return nil }
        guard parts.count == 2 else { self.init(number: number, total: 0); return }
        guard let total = Self.number(parts[1]), total > 0 else { return nil }
        self.init(number: number, total: total)
    }

    init(number: UInt16, total: UInt16) {
        self.number = number
        self.total = total
    }

    var text: String { total == 0 ? String(number) : "\(number)/\(total)" }

    private static func number(_ text: Substring) -> UInt16? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt16(text)
    }
}
