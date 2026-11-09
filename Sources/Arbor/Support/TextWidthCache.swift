import AppKit

/// Single-line text widths, kept so a sweep over thousands of names measures each one once.
enum TextWidthCache {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 20000
        return cache
    }()

    static func width(_ text: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let hit = cache.object(forKey: key) { return CGFloat(hit.doubleValue) }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        cache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }
}
