// Generates the benchmark fixtures for scripts/bench.sh (docs/PERFORMANCE.md, spec §15.4).
// Usage: swift scripts/bench-fixtures.swift <empty folder> [--quick]
// Deterministic: the same version always produces the same names, sizes, dates and image content.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let version = 1
let args = CommandLine.arguments.dropFirst()
guard let rootPath = args.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: bench-fixtures.swift <folder> [--quick]\n".utf8))
    exit(2)
}
let quick = args.contains("--quick")
let root = URL(fileURLWithPath: rootPath, isDirectory: true)
let fm = FileManager.default

/// Small deterministic generator (xorshift) so fixtures don't depend on the system RNG.
struct Seeded {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}
var rng = Seeded(state: 0x9E3779B97F4A7C15)

func mkdir(_ url: URL) { try? fm.createDirectory(at: url, withIntermediateDirectories: true) }

let epoch = 1_700_000_000.0   // 2023-11-14; dates spread over the following two years
func write(_ url: URL, bytes: Int, date offset: Int) {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    if bytes > 0 {
        var buffer = [UInt8](repeating: 0x2E, count: min(bytes, 1 << 20))
        for i in stride(from: 0, to: buffer.count, by: 97) { buffer[i] = UInt8(truncatingIfNeeded: i &* 31 &+ offset) }
        var left = bytes
        while left > 0 {
            let n = min(left, buffer.count)
            _ = buffer.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, n) }
            left -= n
        }
    }
    let t = epoch + Double(offset % 63_072_000)
    var times = [timeval(tv_sec: Int(t), tv_usec: 0), timeval(tv_sec: Int(t), tv_usec: 0)]
    futimes(fd, &times)
    close(fd)
}

let extensions = ["txt", "pdf", "docx", "xlsx", "png", "jpg", "md", "zip", "csv", "json", "swift", "mov"]
let words = ["notes", "report", "budget", "photo", "invoice", "draft", "summary", "plan", "data", "backup", "letter", "scan"]

/// A folder with `files` files of mixed types and sizes and `folders` empty subfolders.
func mixedFolder(_ url: URL, files: Int, folders: Int, prefix: String) {
    mkdir(url)
    for i in 0..<folders { mkdir(url.appendingPathComponent("\(prefix) folder \(i)")) }
    for i in 0..<files {
        let word = words[rng.int(0..<words.count)]
        let ext = extensions[rng.int(0..<extensions.count)]
        write(url.appendingPathComponent("\(word) \(prefix)-\(i).\(ext)"), bytes: rng.int(0..<4096), date: rng.int(0..<63_072_000))
    }
}

let started = Date()
func step(_ name: String) { print(String(format: "  %-12@ %.1fs", name as NSString, Date().timeIntervalSince(started))) }

// Idle launch: one ordinary folder.
mixedFolder(root.appendingPathComponent("idle"), files: 40, folders: 10, prefix: "idle")
step("idle")

// Ordinary browsing: ten 1,000-entry mixed folders.
for f in 1...10 {
    mixedFolder(root.appendingPathComponent(String(format: "browse/f%02d", f)), files: 900, folders: 100, prefix: "b\(f)")
}
step("browse")

// Large folder: 100,000 entries (10,000 with --quick), varied names, sizes and dates.
let big = root.appendingPathComponent("big")
mkdir(big)
let bigCount = quick ? 10_000 : 100_000
for i in 0..<bigCount {
    if i % 50 == 0 { mkdir(big.appendingPathComponent("dir \(i)")); continue }
    let word = words[i % words.count]
    let ext = extensions[(i / 7) % extensions.count]
    write(big.appendingPathComponent("\(word) \(i).\(ext)"), bytes: (i &* 7919) % 2048, date: (i &* 104_729) % 63_072_000)
}
step("big")

// Images and PDFs with large decoded sizes (compressed size is small; decoded is ~48 MB per photo).
let media = root.appendingPathComponent("media")
mkdir(media)
func pattern(width: Int, height: Int, seed: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let hue = CGFloat(seed % 12) / 12
    let base = NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).cgColor
    ctx.setFillColor(base)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for k in 0..<24 {
        ctx.setFillColor(NSColor(hue: (hue + CGFloat(k) / 24).truncatingRemainder(dividingBy: 1), saturation: 0.7,
                                 brightness: 0.75, alpha: 1).cgColor)
        let s = CGFloat(width) / 8
        ctx.fillEllipse(in: CGRect(x: CGFloat((k * 677 + seed * 131) % width), y: CGFloat((k * 401 + seed * 59) % height), width: s, height: s))
    }
    return ctx.makeImage()
}
let photoCount = quick ? 12 : 60
for i in 0..<photoCount {
    guard let image = pattern(width: 4000, height: 3000, seed: i) else { continue }
    let url = media.appendingPathComponent(String(format: "photo %03d.jpg", i)) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
let pdfCount = quick ? 4 : 20
for i in 0..<pdfCount {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let url = media.appendingPathComponent(String(format: "document %02d.pdf", i)) as CFURL
    guard let pdf = CGContext(url, mediaBox: &box, nil) else { continue }
    for page in 0..<40 {
        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor(hue: CGFloat((i + page) % 10) / 10, saturation: 0.4, brightness: 0.95, alpha: 1).cgColor)
        pdf.fill(box.insetBy(dx: 36, dy: 36))
        pdf.endPDFPage()
    }
    pdf.closePDF()
}
step("media")

// Search churn: 5,000 files in 20 folders. File contents never contain the words, so a name match
// is the only correct reason for a result.
let search = root.appendingPathComponent("search")
for d in 0..<20 {
    let dir = search.appendingPathComponent("area \(d)/sub \(d % 4)")
    mkdir(dir)
    for i in 0..<250 {
        let word = words[(d * 250 + i) % words.count]
        write(dir.appendingPathComponent("\(word) \(d)-\(i).txt"), bytes: 64 + i, date: d * 1000 + i)
    }
}
step("search")

// Copies: many small files, and one large file.
let small = root.appendingPathComponent("copy-small/tree")
for d in 0..<30 {
    let dir = small.appendingPathComponent("part \(d)")
    mkdir(dir)
    for i in 0..<(quick ? 20 : 100) { write(dir.appendingPathComponent("piece \(i).dat"), bytes: 4096, date: i) }
}
let large = root.appendingPathComponent("copy-large")
mkdir(large)
write(large.appendingPathComponent("large.bin"), bytes: (quick ? 64 : 512) << 20, date: 1)
step("copies")

try? "version=\(version) quick=\(quick)\n".write(to: root.appendingPathComponent("FIXTURE"), atomically: true, encoding: .utf8)
