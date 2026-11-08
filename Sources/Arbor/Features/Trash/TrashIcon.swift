import AppKit
import ArborCore

/// Code-drawn Trash icons (original artwork, DEC-018): a grey-blue bin, with sheets over the rim when full.
enum TrashIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(full: Bool, size: CGFloat) -> NSImage {
        let key = "\(full)-\(size)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(in: rect, full: full)
            return true
        }
        image.accessibilityDescription = full ? L10n.tr("Trash (contains items)") : L10n.tr("Trash (empty)")
        cache.setObject(image, forKey: key)
        return image
    }

    /// 32-unit grid, y grows downward.
    static func draw(in rect: NSRect, full: Bool) {
        let u = rect.width / 32
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * u, y: rect.minY + y * u) }

        if full {
            // Sheets behind the rim, slightly tilted.
            let back = NSBezierPath()
            back.move(to: p(9, 10)); back.line(to: p(12.5, 2.5)); back.line(to: p(20, 5)); back.line(to: p(18, 10)); back.close()
            Theme.rgb(0xFFFFFF).setFill(); back.fill()
            Theme.rgb(0x9AA7B4).setStroke(); back.lineWidth = 0.6 * u; back.stroke()
            let front = NSBezierPath()
            front.move(to: p(14, 10)); front.line(to: p(17, 3.5)); front.line(to: p(24.5, 6)); front.line(to: p(23, 10)); front.close()
            Theme.rgb(0xFFE08A).setFill(); front.fill()
            Theme.rgb(0xC9A24A).setStroke(); front.lineWidth = 0.6 * u; front.stroke()
            Theme.rgb(0x5B8FD6).setStroke()
            for i in 0..<2 {
                let line = NSBezierPath()
                let y = 6.2 + CGFloat(i) * 1.6
                line.move(to: p(12.8 + CGFloat(i) * 0.4, y + 0.6)); line.line(to: p(17.2, y + 1.9))
                line.lineWidth = 0.5 * u
                line.stroke()
            }
        }

        // Tapered bin body.
        let body = NSBezierPath()
        body.move(to: p(6.5, 10)); body.line(to: p(25.5, 10)); body.line(to: p(23.4, 29))
        body.appendArc(from: p(23.2, 30), to: p(21.8, 30), radius: 1.2 * u)
        body.line(to: p(10.2, 30))
        body.appendArc(from: p(8.8, 30), to: p(8.6, 29), radius: 1.2 * u)
        body.close()
        let gradient = NSGradient(colors: [Theme.rgb(0xE9EEF3, alpha: 0.96), Theme.rgb(0xC3CDD7, alpha: 0.96)])
        gradient?.draw(in: body, angle: 90)
        Theme.rgb(0x7D8B99).setStroke()
        body.lineWidth = 0.9 * u
        body.stroke()

        // Ribs.
        Theme.rgb(0x98A6B4).setStroke()
        for x: CGFloat in [12, 16, 20] {
            let rib = NSBezierPath()
            rib.move(to: p(x, 13.5)); rib.line(to: p(x + (x - 16) * -0.08, 26.5))
            rib.lineWidth = 0.8 * u
            rib.lineCapStyle = .round
            rib.stroke()
        }

        // Rim.
        let rim = NSBezierPath(roundedRect: NSRect(x: rect.minX + 5 * u, y: rect.minY + 8.6 * u, width: 22 * u, height: 2.6 * u),
                               xRadius: 1.1 * u, yRadius: 1.1 * u)
        Theme.rgb(0xD5DDE5).setFill()
        rim.fill()
        Theme.rgb(0x7D8B99).setStroke()
        rim.lineWidth = 0.9 * u
        rim.stroke()
    }
}
