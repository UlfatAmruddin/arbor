import Foundation
import CoreServices
import ImageIO

/// Spotlight metadata with an ImageIO fallback for unindexed images (FE-151). Read-only (FE-152).
public struct MetadataRow: Equatable, Sendable {
    public var group: String
    public var label: String
    public var value: String
    public init(group: String, label: String, value: String) {
        self.group = group
        self.label = label
        self.value = value
    }
}

public enum SpotlightMetadata {
    public enum Format: Sendable {
        case text, list, date, number, duration, bitRate, hertz, pixels, dpi, fStop, exposure, focalLength, iso, flash,
             rating, bytes, version, framesPerSecond, meters, bool
    }

    public struct Field: Sendable {
        public let key: String
        public let label: String
        public let group: String
        public let format: Format
    }

    /// In Explorer's group order.
    public static let fields: [Field] = [
        Field(key: "kMDItemTitle", label: L10n.tr("Title"), group: L10n.tr("Description"), format: .text),
        Field(key: "kMDItemHeadline", label: L10n.tr("Subject"), group: L10n.tr("Description"), format: .text),
        Field(key: "kMDItemStarRating", label: L10n.tr("Rating"), group: L10n.tr("Description"), format: .rating),
        Field(key: "kMDItemKeywords", label: L10n.tr("Keywords"), group: L10n.tr("Description"), format: .list),
        Field(key: "kMDItemDescription", label: L10n.tr("Comments"), group: L10n.tr("Description"), format: .text),
        Field(key: "kMDItemAuthors", label: L10n.tr("Authors"), group: L10n.tr("Origin"), format: .list),
        Field(key: "kMDItemCreator", label: L10n.tr("Program name"), group: L10n.tr("Origin"), format: .text),
        Field(key: "kMDItemContentCreationDate", label: L10n.tr("Content created"), group: L10n.tr("Origin"), format: .date),
        Field(key: "kMDItemDateAdded", label: L10n.tr("Date acquired"), group: L10n.tr("Origin"), format: .date),
        Field(key: "kMDItemCopyright", label: L10n.tr("Copyright"), group: L10n.tr("Origin"), format: .text),
        Field(key: "kMDItemWhereFroms", label: L10n.tr("Where from"), group: L10n.tr("Origin"), format: .list),
        Field(key: "kMDItemPixelWidth", label: L10n.tr("Width"), group: L10n.tr("Image"), format: .pixels),
        Field(key: "kMDItemPixelHeight", label: L10n.tr("Height"), group: L10n.tr("Image"), format: .pixels),
        Field(key: "kMDItemResolutionWidthDPI", label: L10n.tr("Horizontal resolution"), group: L10n.tr("Image"), format: .dpi),
        Field(key: "kMDItemResolutionHeightDPI", label: L10n.tr("Vertical resolution"), group: L10n.tr("Image"), format: .dpi),
        Field(key: "kMDItemBitsPerSample", label: L10n.tr("Bit depth"), group: L10n.tr("Image"), format: .number),
        Field(key: "kMDItemColorSpace", label: L10n.tr("Color representation"), group: L10n.tr("Image"), format: .text),
        Field(key: "kMDItemProfileName", label: L10n.tr("Color profile"), group: L10n.tr("Image"), format: .text),
        Field(key: "kMDItemAcquisitionMake", label: L10n.tr("Camera maker"), group: L10n.tr("Camera"), format: .text),
        Field(key: "kMDItemAcquisitionModel", label: L10n.tr("Camera model"), group: L10n.tr("Camera"), format: .text),
        Field(key: "kMDItemFNumber", label: L10n.tr("F-stop"), group: L10n.tr("Camera"), format: .fStop),
        Field(key: "kMDItemExposureTimeSeconds", label: L10n.tr("Exposure time"), group: L10n.tr("Camera"), format: .exposure),
        Field(key: "kMDItemISOSpeed", label: L10n.tr("ISO speed"), group: L10n.tr("Camera"), format: .iso),
        Field(key: "kMDItemFocalLength", label: L10n.tr("Focal length"), group: L10n.tr("Camera"), format: .focalLength),
        Field(key: "kMDItemFlashOnOff", label: L10n.tr("Flash mode"), group: L10n.tr("Camera"), format: .flash),
        Field(key: "kMDItemLensModel", label: L10n.tr("Lens model"), group: L10n.tr("Camera"), format: .text),
        Field(key: "kMDItemLatitude", label: L10n.tr("Latitude"), group: L10n.tr("GPS"), format: .number),
        Field(key: "kMDItemLongitude", label: L10n.tr("Longitude"), group: L10n.tr("GPS"), format: .number),
        Field(key: "kMDItemAltitude", label: L10n.tr("Altitude"), group: L10n.tr("GPS"), format: .meters),
        Field(key: "kMDItemDurationSeconds", label: L10n.tr("Length"), group: L10n.tr("Media"), format: .duration),
        Field(key: "kMDItemAlbum", label: L10n.tr("Album"), group: L10n.tr("Media"), format: .text),
        Field(key: "kMDItemComposer", label: L10n.tr("Composers"), group: L10n.tr("Media"), format: .text),
        Field(key: "kMDItemMusicalGenre", label: L10n.tr("Genre"), group: L10n.tr("Media"), format: .text),
        Field(key: "kMDItemRecordingYear", label: L10n.tr("Year"), group: L10n.tr("Media"), format: .number),
        Field(key: "kMDItemAudioTrackNumber", label: "#", group: L10n.tr("Media"), format: .number),
        Field(key: "kMDItemAudioBitRate", label: L10n.tr("Bit rate"), group: L10n.tr("Audio"), format: .bitRate),
        Field(key: "kMDItemAudioSampleRate", label: L10n.tr("Audio sample rate"), group: L10n.tr("Audio"), format: .hertz),
        Field(key: "kMDItemAudioChannelCount", label: L10n.tr("Channels"), group: L10n.tr("Audio"), format: .number),
        Field(key: "kMDItemVideoBitRate", label: L10n.tr("Data rate"), group: L10n.tr("Video"), format: .bitRate),
        Field(key: "kMDItemCodecs", label: L10n.tr("Codecs"), group: L10n.tr("Video"), format: .list),
        Field(key: "kMDItemMediaTypes", label: L10n.tr("Media types"), group: L10n.tr("Video"), format: .list),
        Field(key: "kMDItemNumberOfPages", label: L10n.tr("Pages"), group: L10n.tr("Content"), format: .number),
        Field(key: "kMDItemPageWidth", label: L10n.tr("Page width"), group: L10n.tr("Content"), format: .number),
        Field(key: "kMDItemPageHeight", label: L10n.tr("Page height"), group: L10n.tr("Content"), format: .number),
        Field(key: "kMDItemLanguages", label: L10n.tr("Languages"), group: L10n.tr("Content"), format: .list),
        Field(key: "kMDItemEncodingApplications", label: L10n.tr("Encoded by"), group: L10n.tr("Content"), format: .list),
        Field(key: "kMDItemVersion", label: L10n.tr("Version"), group: L10n.tr("Content"), format: .text),
        Field(key: "kMDItemLastUsedDate", label: L10n.tr("Last opened"), group: L10n.tr("File"), format: .date),
        Field(key: "kMDItemUseCount", label: L10n.tr("Times opened"), group: L10n.tr("File"), format: .number),
    ]

    /// Empty when missing or unindexed.
    public static func rawValues(_ url: URL, keys: [String]? = nil) -> [String: Any] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return [:] }
        let wanted = keys ?? fields.map(\.key)
        guard let dict = MDItemCopyAttributes(item, wanted as CFArray) as? [String: Any] else { return [:] }
        return dict
    }

    /// Reads headers only, no pixels.
    public static func imageValues(_ url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [String: Any] = [:]
        out["kMDItemPixelWidth"] = props[kCGImagePropertyPixelWidth]
        out["kMDItemPixelHeight"] = props[kCGImagePropertyPixelHeight]
        out["kMDItemResolutionWidthDPI"] = props[kCGImagePropertyDPIWidth]
        out["kMDItemResolutionHeightDPI"] = props[kCGImagePropertyDPIHeight]
        out["kMDItemBitsPerSample"] = props[kCGImagePropertyDepth]
        out["kMDItemColorSpace"] = props[kCGImagePropertyColorModel]
        out["kMDItemProfileName"] = props[kCGImagePropertyProfileName]
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            out["kMDItemAcquisitionMake"] = tiff[kCGImagePropertyTIFFMake]
            out["kMDItemAcquisitionModel"] = tiff[kCGImagePropertyTIFFModel]
            out["kMDItemCopyright"] = tiff[kCGImagePropertyTIFFCopyright]
            out["kMDItemCreator"] = tiff[kCGImagePropertyTIFFSoftware]
            if let artist = tiff[kCGImagePropertyTIFFArtist] as? String { out["kMDItemAuthors"] = [artist] }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            out["kMDItemFNumber"] = exif[kCGImagePropertyExifFNumber]
            out["kMDItemExposureTimeSeconds"] = exif[kCGImagePropertyExifExposureTime]
            out["kMDItemFocalLength"] = exif[kCGImagePropertyExifFocalLength]
            out["kMDItemLensModel"] = exif[kCGImagePropertyExifLensModel]
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { out["kMDItemISOSpeed"] = iso }
            if let flash = exif[kCGImagePropertyExifFlash] as? NSNumber { out["kMDItemFlashOnOff"] = NSNumber(value: flash.intValue & 1) }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
                out["kMDItemLatitude"] = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                out["kMDItemLongitude"] = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            }
            out["kMDItemAltitude"] = gps[kCGImagePropertyGPSAltitude]
        }
        return out.filter { !($0.value is NSNull) }
    }

    /// Spotlight values win; ImageIO fills gaps for images.
    public static func rows(for url: URL, isImage: Bool) -> [MetadataRow] {
        var values = rawValues(url)
        if isImage {
            for (k, v) in imageValues(url) where values[k] == nil { values[k] = v }
        }
        // Some importers fill Title/Subject with the file name.
        let names: Set<String> = [url.lastPathComponent, url.deletingPathExtension().lastPathComponent]
        for key in ["kMDItemTitle", "kMDItemHeadline"] {
            if let s = values[key] as? String, names.contains(s) { values.removeValue(forKey: key) }
        }
        return rows(from: values)
    }

    public static func rows(from values: [String: Any]) -> [MetadataRow] {
        var rows: [MetadataRow] = []
        if let w = number(values["kMDItemPixelWidth"]), let h = number(values["kMDItemPixelHeight"]), w > 0, h > 0,
           let w = Int(checked: w), let h = Int(checked: h) {
            rows.append(MetadataRow(group: L10n.tr("Image"), label: L10n.tr("Dimensions"), value: "\(w) x \(h)"))
        }
        for field in fields {
            guard let raw = values[field.key], let text = format(raw, field.format), !text.isEmpty else { continue }
            rows.append(MetadataRow(group: field.group, label: field.label, value: text))
        }
        // Stable sort by group keeps Dimensions first in Image.
        let order = ["Description", "Origin", "Image", "Camera", "GPS", "Media", "Audio", "Video", "Content", "File"].map { L10n.tr($0) }   // groups are stored localized
        return rows.enumerated().sorted { a, b in
            let ga = order.firstIndex(of: a.element.group) ?? order.count
            let gb = order.firstIndex(of: b.element.group) ?? order.count
            return ga != gb ? ga < gb : a.offset < b.offset
        }.map(\.element)
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    public static func format(_ value: Any, _ format: Format) -> String? {
        switch format {
        case .text, .version:
            if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let list = value as? [String] { return list.joined(separator: "; ") }
            return (value as? NSNumber)?.stringValue
        case .list:
            if let list = value as? [Any] { return list.compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: "; ") }
            return value as? String
        case .date:
            return (value as? Date).map { PropertyFormat.shortDate($0) }
        case .number:
            guard let n = number(value) else { return nil }
            return n == n.rounded() && abs(n) < 1e15 ? PropertyFormat.grouped(Int64(n)) : PropertyFormat.compact(n)
        case .duration:
            return number(value).map(PropertyFormat.duration)
        case .bitRate:
            // Spotlight reports kbps; some importers report bps.
            guard let n = number(value), n > 0 else { return nil }
            let kbps = n >= 10_000 ? n / 1000 : n
            return Int(checked: kbps.rounded()).map { L10n.format("%@kbps", PropertyFormat.ungrouped($0)) }
        case .hertz:
            guard let n = number(value) else { return nil }
            if n >= 1000 { return L10n.format("%@ kHz", PropertyFormat.compact((n / 100).rounded() / 10)) }
            return Int(checked: n).map { L10n.format("%@ Hz", PropertyFormat.grouped($0)) }
        case .pixels:
            return number(value).flatMap { Int(checked: $0) }.map { L10n.format("%@ pixels", PropertyFormat.ungrouped($0)) }
        case .dpi:
            return number(value).flatMap { Int(checked: $0.rounded()) }.map { L10n.format("%@ dpi", PropertyFormat.ungrouped($0)) }
        case .fStop:
            return number(value).map { L10n.format("f/%@", PropertyFormat.compact(($0 * 10).rounded() / 10)) }
        case .exposure:
            guard let n = number(value), n > 0 else { return nil }
            if n < 1 { return Int(checked: (1 / n).rounded()).map { L10n.format("1/%@ sec.", PropertyFormat.ungrouped($0)) } }
            return L10n.format("%@ sec.", PropertyFormat.compact(n))
        case .focalLength:
            return number(value).map { L10n.format("%@ mm", PropertyFormat.compact(($0 * 10).rounded() / 10)) }
        case .iso:
            return number(value).flatMap { Int(checked: $0) }.map { L10n.format("ISO-%@", PropertyFormat.ungrouped($0)) }
        case .flash:
            return number(value).map { $0 != 0 ? L10n.tr("Flash") : L10n.tr("No flash") }
        case .rating:
            guard let n = number(value), let rounded = Int(checked: n.rounded()) else { return nil }
            let stars = max(0, min(5, rounded))
            return String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
        case .bytes:
            return number(value).flatMap { Int(checked: $0) }.map { PropertyFormat.adaptiveSize(Int64($0)) }
        case .framesPerSecond:
            return number(value).map { L10n.format("%@ frames/second", PropertyFormat.compact($0)) }
        case .meters:
            return number(value).map { L10n.format("%@ m", SizeUnit.number($0, decimals: 1)) }
        case .bool:
            return number(value).map { $0 != 0 ? L10n.tr("Yes") : L10n.tr("No") }
        }
    }
}
