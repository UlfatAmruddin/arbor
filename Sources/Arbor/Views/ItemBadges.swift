import AppKit
import ArborCore

/// Small status glyphs composited onto item icons of 32 pt and up (icon views). The Details view
/// shows the same information in a column instead, so its 16 pt icons stay clean.
enum ItemBadges {
    static let providers = Handlers<FileItem, NSImage>(
        "ItemBadges.providers", "A status glyph on icons of 32 pt and up (cloud status).", signature: "(item) -> badge?")

    static func register(_ id: String, order: ExtensionOrder = .normal, _ provider: @escaping (FileItem) -> NSImage?) {
        providers.register(id, order: order, provider)
    }

    static func badge(for item: FileItem) -> NSImage? { providers.first(item) }

    static func decorate(_ icon: NSImage, item: FileItem, size: CGFloat) -> NSImage {
        guard size >= 32, !providers.isEmpty, let badge = badge(for: item) else { return icon }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            icon.draw(in: rect)
            let side = max(12, round(size * 0.34))
            let badgeRect = NSRect(x: rect.minX, y: rect.minY, width: side, height: side)
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
            badge.draw(in: badgeRect)
            return true
        }
    }
}
