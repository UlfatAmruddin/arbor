// Draws Arbor's original app icon and writes an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Arbor-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Rounded-square background, deep teal to blue.
    let inset = 100 * s
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.47, blue: 0.62, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.55, alpha: 1))!.draw(in: tilePath, angle: -90)

    // Folder body.
    let folderColor = NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.36, alpha: 1)
    let tab = NSBezierPath(roundedRect: NSRect(x: 230 * s, y: 610 * s, width: 230 * s, height: 90 * s), xRadius: 28 * s, yRadius: 28 * s)
    folderColor.blended(withFraction: 0.18, of: .brown)!.setFill()
    tab.fill()
    let body = NSBezierPath(roundedRect: NSRect(x: 230 * s, y: 300 * s, width: 564 * s, height: 360 * s), xRadius: 40 * s, yRadius: 40 * s)
    folderColor.setFill()
    body.fill()

    // A branching tree on the folder: the navigation hierarchy.
    let ink = NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.40, alpha: 0.9)
    ink.setStroke()
    let trunk = NSBezierPath()
    trunk.lineWidth = 26 * s
    trunk.lineCapStyle = .round
    trunk.lineJoinStyle = .round
    trunk.move(to: NSPoint(x: 330 * s, y: 590 * s))
    trunk.line(to: NSPoint(x: 330 * s, y: 370 * s))
    for y in [520.0, 445.0, 370.0] {
        trunk.move(to: NSPoint(x: 330 * s, y: CGFloat(y) * s))
        trunk.line(to: NSPoint(x: 420 * s, y: CGFloat(y) * s))
    }
    trunk.stroke()
    ink.setFill()
    for (y, width) in [(520.0, 300.0), (445.0, 230.0), (370.0, 270.0)] {
        NSBezierPath(roundedRect: NSRect(x: 450 * s, y: (CGFloat(y) - 18) * s, width: CGFloat(width) * s, height: 36 * s),
                     xRadius: 18 * s, yRadius: 18 * s).fill()
    }
    NSBezierPath(ovalIn: NSRect(x: 300 * s, y: 570 * s, width: 60 * s, height: 60 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
exit(task.terminationStatus)
