import Foundation
import CoreServices
import ImageIO

/// Embedded/indexed metadata for the Details tab and Details pane (FE-151): Spotlight (`MDItem`)
/// attributes, with an ImageIO fallback for images Spotlight hasn't indexed yet (new files, volumes
/// without an index). Read-only: Arbor never rewrites embedded metadata in place (FE-152).
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

    /// Explorer's groups and order (Description, Origin, Image, Camera, Audio/Media, Video, Content).
    public static let fields: [Field] = [
        Field(key: "kMDItemTitle", label: "Title", group: "Description", format: .text),
        Field(key: "kMDItemHeadline", label: "Subject", group: "Description", format: .text),
        Field(key: "kMDItemStarRating", label: "Rating", group: "Description", format: .rating),
        Field(key: "kMDItemKeywords", label: "Keywords", group: "Description", format: .list),
        Field(key: "kMDItemDescription", label: "Comments", group: "Description", format: .text),
        Field(key: "kMDItemAuthors", label: "Authors", group: "Origin", format: .list),
        Field(key: "kMDItemCreator", label: "Program name", group: "Origin", format: .text),
        Field(key: "kMDItemContentCreationDate", label: "Content created", group: "Origin", format: .date),
        Field(key: "kMDItemDateAdded", label: "Date acquired", group: "Origin", format: .date),
        Field(key: "kMDItemCopyright", label: "Copyright", group: "Origin", format: .text),
        Field(key: "kMDItemWhereFroms", label: "Where from", group: "Origin", format: .list),
        Field(key: "kMDItemPixelWidth", label: "Width", group: "Image", format: .pixels),
        Field(key: "kMDItemPixelHeight", label: "Height", group: "Image", format: .pixels),
        Field(key: "kMDItemResolutionWidthDPI", label: "Horizontal resolution", group: "Image", format: .dpi),
        Field(key: "kMDItemResolutionHeightDPI", label: "Vertical resolution", group: "Image", format: .dpi),
        Field(key: "kMDItemBitsPerSample", label: "Bit depth", group: "Image", format: .number),
        Field(key: "kMDItemColorSpace", label: "Color representation", group: "Image", format: .text),
        Field(key: "kMDItemProfileName", label: "Color profile", group: "Image", format: .text),
        Field(key: "kMDItemAcquisitionMake", label: "Camera maker", group: "Camera", format: .text),
        Field(key: "kMDItemAcquisitionModel", label: "Camera model", group: "Camera", format: .text),
        Field(key: "kMDItemFNumber", label: "F-stop", group: "Camera", format: .fStop),
        Field(key: "kMDItemExposureTimeSeconds", label: "Exposure time", group: "Camera", format: .exposure),
        Field(key: "kMDItemISOSpeed", label: "ISO speed", group: "Camera", format: .iso),
        Field(key: "kMDItemFocalLength", label: "Focal length", group: "Camera", format: .focalLength),
        Field(key: "kMDItemFlashOnOff", label: "Flash mode", group: "Camera", format: .flash),
        Field(key: "kMDItemLensModel", label: "Lens model", group: "Camera", format: .text),
        Field(key: "kMDItemLatitude", label: "Latitude", group: "GPS", format: .number),
        Field(key: "kMDItemLongitude", label: "Longitude", group: "GPS", format: .number),
        Field(key: "kMDItemAltitude", label: "Altitude", group: "GPS", format: .meters),
        Field(key: "kMDItemDurationSeconds", label: "Length", group: "Media", format: .duration),
        Field(key: "kMDItemAlbum", label: "Album", group: "Media", format: .text),
        Field(key: "kMDItemComposer", label: "Composers", group: "Media", format: .text),
        Field(key: "kMDItemMusicalGenre", label: "Genre", group: "Media", format: .text),
        Field(key: "kMDItemRecordingYear", label: "Year", group: "Media", format: .number),
        Field(key: "kMDItemAudioTrackNumber", label: "#", group: "Media", format: .number),
        Field(key: "kMDItemAudioBitRate", label: "Bit rate", group: "Audio", format: .bitRate),
        Field(key: "kMDItemAudioSampleRate", label: "Audio sample rate", group: "Audio", format: .hertz),
        Field(key: "kMDItemAudioChannelCount", label: "Channels", group: "Audio", format: .number),
        Field(key: "kMDItemVideoBitRate", label: "Data rate", group: "Video", format: .bitRate),
        Field(key: "kMDItemCodecs", label: "Codecs", group: "Video", format: .list),
        Field(key: "kMDItemMediaTypes", label: "Media types", group: "Video", format: .list),
        Field(key: "kMDItemNumberOfPages", label: "Pages", group: "Content", format: .number),
        Field(key: "kMDItemPageWidth", label: "Page width", group: "Content", format: .number),
        Field(key: "kMDItemPageHeight", label: "Page height", group: "Content", format: .number),
        Field(key: "kMDItemLanguages", label: "Languages", group: "Content", format: .list),
        Field(key: "kMDItemEncodingApplications", label: "Encoded by", group: "Content", format: .list),
        Field(key: "kMDItemVersion", label: "Version", group: "Content", format: .text),
        Field(key: "kMDItemLastUsedDate", label: "Last opened", group: "File", format: .date),
        Field(key: "kMDItemUseCount", label: "Times opened", group: "File", format: .number),
    ]

    /// Raw Spotlight values for `fields` (and any extra keys). Missing or unindexed → empty.
    public static func rawValues(_ url: URL, keys: [String]? = nil) -> [String: Any] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return [:] }
        let wanted = keys ?? fields.map(\.key)
        guard let dict = MDItemCopyAttributes(item, wanted as CFArray) as? [String: Any] else { return [:] }
        return dict
    }

    /// Image properties from the file itself (ImageIO reads only the header and metadata, no pixels).
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

    /// Grouped, formatted rows in Explorer's order. Spotlight values win; ImageIO fills gaps for images.
    public static func rows(for url: URL, isImage: Bool) -> [MetadataRow] {
        var values = rawValues(url)
        if isImage {
            for (k, v) in imageValues(url) where values[k] == nil { values[k] = v }
        }
        // Some importers fill Title/Subject with the file name; that isn't embedded metadata.
        let names: Set<String> = [url.lastPathComponent, url.deletingPathExtension().lastPathComponent]
        for key in ["kMDItemTitle", "kMDItemHeadline"] {
            if let s = values[key] as? String, names.contains(s) { values.removeValue(forKey: key) }
        }
        return rows(from: values)
    }

    public static func rows(from values: [String: Any]) -> [MetadataRow] {
        var rows: [MetadataRow] = []
        if let w = number(values["kMDItemPixelWidth"]), let h = number(values["kMDItemPixelHeight"]), w > 0, h > 0 {
            rows.append(MetadataRow(group: "Image", label: "Dimensions", value: "\(Int(w)) x \(Int(h))"))
        }
        for field in fields {
            guard let raw = values[field.key], let text = format(raw, field.format), !text.isEmpty else { continue }
            rows.append(MetadataRow(group: field.group, label: field.label, value: text))
        }
        // Keep Explorer's group order with Dimensions first in Image.
        let order = ["Description", "Origin", "Image", "Camera", "GPS", "Media", "Audio", "Video", "Content", "File"]
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

    /// Formats one value. Public for tests and the Details pane.
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
            return n == n.rounded() && abs(n) < 1e15 ? PropertyFormat.grouped(Int64(n)) : String(format: "%.6g", n)
        case .duration:
            return number(value).map(PropertyFormat.duration)
        case .bitRate:
            // Spotlight reports kbps for audio; some importers report bits per second.
            guard let n = number(value), n > 0 else { return nil }
            let kbps = n >= 10_000 ? n / 1000 : n
            return "\(Int(kbps.rounded()))kbps"
        case .hertz:
            guard let n = number(value) else { return nil }
            return n >= 1000 ? "\(String(format: "%g", (n / 100).rounded() / 10)) kHz" : "\(Int(n)) Hz"
        case .pixels:
            return number(value).map { "\(Int($0)) pixels" }
        case .dpi:
            return number(value).map { "\(Int($0.rounded())) dpi" }
        case .fStop:
            return number(value).map { "f/\(String(format: "%g", ($0 * 10).rounded() / 10))" }
        case .exposure:
            guard let n = number(value), n > 0 else { return nil }
            return n < 1 ? "1/\(Int((1 / n).rounded())) sec." : "\(String(format: "%g", n)) sec."
        case .focalLength:
            return number(value).map { "\(String(format: "%g", ($0 * 10).rounded() / 10)) mm" }
        case .iso:
            return number(value).map { "ISO-\(Int($0))" }
        case .flash:
            return number(value).map { $0 != 0 ? "Flash" : "No flash" }
        case .rating:
            guard let n = number(value) else { return nil }
            let stars = max(0, min(5, Int(n.rounded())))
            return String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
        case .bytes:
            return number(value).map { PropertyFormat.adaptiveSize(Int64($0)) }
        case .framesPerSecond:
            return number(value).map { "\(String(format: "%g", $0)) frames/second" }
        case .meters:
            return number(value).map { "\(String(format: "%.1f", $0)) m" }
        case .bool:
            return number(value).map { $0 != 0 ? "Yes" : "No" }
        }
    }
}
