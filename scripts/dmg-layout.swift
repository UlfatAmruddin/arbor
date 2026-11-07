// Draws the disk image background and writes the Finder window layout (.DS_Store) for the
// Arbor disk image, without driving Finder. Used by scripts/make-dmg.sh.
//
//   swift scripts/dmg-layout.swift background <folder>
//       Writes background.png (640x400) and background@2x.png into <folder>.
//   swift scripts/dmg-layout.swift dsstore <volume root> <background file inside the volume>
//       Writes <volume root>/.DS_Store: window size, icon view, icon positions and background.
//
// .DS_Store format: a "buddy allocator" file holding one B-tree ("DSDB") of records keyed by
// file name and a four-character code. Arbor's tree is small enough for a single leaf node.
import AppKit

// MARK: - Layout shared by the background and the Finder window

enum Layout {
    static let width: CGFloat = 640
    static let height: CGFloat = 400
    static let iconSize: CGFloat = 128
    /// Icon centers, measured from the window's top-left corner (Finder's convention).
    static let app = CGPoint(x: 170, y: 180)
    static let applications = CGPoint(x: 470, y: 180)
    static let windowOrigin = CGPoint(x: 200, y: 120)
}

// MARK: - Background

func drawBackground(scale: CGFloat) -> Data {
    let w = Int(Layout.width * scale), h = Int(Layout.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: Layout.width, height: Layout.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
    // Drawing uses a bottom-left origin; Finder positions use top-left.
    func flip(_ y: CGFloat) -> CGFloat { Layout.height - y }

    // Soft light gradient, a little cooler at the top.
    NSGradient(starting: NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1),
               ending: NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.96, alpha: 1))!.draw(in: bounds, angle: -90)

    // A faint branching line along the bottom edge, echoing the tree in the app icon.
    let branch = NSBezierPath()
    branch.lineWidth = 2
    branch.lineCapStyle = .round
    branch.move(to: NSPoint(x: 40, y: 34))
    branch.line(to: NSPoint(x: Layout.width - 40, y: 34))
    for x in stride(from: CGFloat(120), through: Layout.width - 120, by: 100) {
        branch.move(to: NSPoint(x: x, y: 34))
        branch.line(to: NSPoint(x: x + 18, y: 52))
    }
    NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.55, alpha: 0.12).setStroke()
    branch.stroke()

    // Arrow from the app to the Applications folder.
    let ink = NSColor(calibratedRed: 0.22, green: 0.50, blue: 0.70, alpha: 1)
    let y = flip(Layout.app.y)
    let start = Layout.app.x + Layout.iconSize / 2 + 24
    let end = Layout.applications.x - Layout.iconSize / 2 - 24
    let shaft = NSBezierPath()
    shaft.lineWidth = 6
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: start, y: y))
    shaft.line(to: NSPoint(x: end - 10, y: y))
    ink.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end + 4, y: y))
    head.line(to: NSPoint(x: end - 18, y: y + 15))
    head.line(to: NSPoint(x: end - 18, y: y - 15))
    head.close()
    ink.setFill()
    head.fill()

    // Instruction under the icon labels.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "To install Arbor, drag it onto the Applications folder.", attributes: [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
        .paragraphStyle: style,
    ])
    text.draw(in: NSRect(x: 0, y: flip(318), width: Layout.width, height: 22))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Alias record (Finder still wants one for the background picture)

/// Creates a classic alias record for `path`. The function is long deprecated but still the only
/// way to make one, and Finder's icon view options store the background picture as an alias.
func aliasRecord(for path: String) -> Data? {
    typealias NewAlias = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>, UInt32,
                                         UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutableRawPointer?>?>,
                                         UnsafeMutableRawPointer?) -> Int32
    guard let lib = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW),
          let sym = dlsym(lib, "FSNewAliasFromPath") else { return nil }
    let newAlias = unsafeBitCast(sym, to: NewAlias.self)
    var handle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    guard newAlias(nil, path, 0, &handle, nil) == 0, let record = handle?.pointee else { return nil }
    // AliasRecord starts with a 4-byte user type and a big-endian 2-byte total size.
    let size = Int(UInt16(bigEndian: record.loadUnaligned(fromByteOffset: 4, as: UInt16.self)))
    return Data(bytes: record, count: size)
}

// MARK: - .DS_Store writer

struct Writer {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func code(_ s: String) { precondition(s.utf8.count == 4); data.append(contentsOf: Array(s.utf8)) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func pad(to size: Int) { precondition(data.count <= size); data.append(Data(count: size - data.count)) }
}

enum Value {
    case long(UInt32)
    case blob(Data)
}

struct Record {
    let name: String
    let code: String
    let value: Value

    func encode(into w: inout Writer) {
        let utf16 = Array(name.utf16)
        w.u32(UInt32(utf16.count))
        for unit in utf16 { w.u8(UInt8(unit >> 8)); w.u8(UInt8(unit & 0xff)) }
        w.code(code)
        switch value {
        case .long(let v): w.code("long"); w.u32(v)
        case .blob(let d): w.code("blob"); w.u32(UInt32(d.count)); w.bytes(d)
        }
    }
}

func binaryPlist(_ object: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

func iconLocation(_ p: CGPoint) -> Data {
    var w = Writer()
    w.u32(UInt32(p.x)); w.u32(UInt32(p.y)); w.u32(0xffff_ffff); w.u32(0xffff_0000)
    return w.data
}

func writeDSStore(volume: URL, background: URL) throws {
    let size = (Layout.width, Layout.height)
    let windowSettings: [String: Any] = [
        "WindowBounds": "{{\(Int(Layout.windowOrigin.x)), \(Int(Layout.windowOrigin.y))}, {\(Int(size.0)), \(Int(size.1))}}",
        "ShowSidebar": false, "ContainerShowSidebar": false, "SidebarWidth": 0,
        "ShowToolbar": false, "ShowTabView": false, "ShowPathbar": false, "ShowStatusBar": false,
        "PreviewPaneVisibility": false,
    ]
    var iconView: [String: Any] = [
        "viewOptionsVersion": 1, "arrangeBy": "none", "iconSize": Double(Layout.iconSize), "textSize": 13.0,
        "labelOnBottom": true, "showItemInfo": false, "showIconPreview": true,
        "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        "backgroundType": 1,   // plain color unless the picture can be referenced
        "backgroundColorRed": 0.92, "backgroundColorGreen": 0.94, "backgroundColorBlue": 0.97,
    ]
    var records = [
        Record(name: ".", code: "bwsp", value: .blob(binaryPlist(windowSettings))),
        Record(name: ".", code: "vSrn", value: .long(1)),
        Record(name: "Applications", code: "Iloc", value: .blob(iconLocation(Layout.applications))),
        Record(name: "Arbor.app", code: "Iloc", value: .blob(iconLocation(Layout.app))),
    ]
    if let alias = aliasRecord(for: background.path) {
        iconView["backgroundType"] = 2
        iconView["backgroundImageAlias"] = alias
        if let bookmark = try? background.bookmarkData() {
            records.append(Record(name: ".", code: "pBBk", value: .blob(bookmark)))
        }
    } else {
        FileHandle.standardError.write(Data("dmg-layout: could not reference the background picture; using a plain color\n".utf8))
    }
    records.append(Record(name: ".", code: "icvp", value: .blob(binaryPlist(iconView))))
    // Records are ordered by case-insensitive name, then by code.
    records.sort { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }

    // Buddy allocator layout (offsets are relative to file offset 4; a block's address is its
    // offset OR'd with log2 of its size, and blocks are aligned to their size):
    //   header      offset    0, 32 bytes
    //   DSDB info   offset   32, 32 bytes   (block 1)
    //   root block  offset 2048, 2048 bytes (block 0)
    //   leaf node   offset 4096, 4096 bytes (block 2)
    // Free lists describe the rest of the 2^31-byte space split the buddy way.
    let header = (offset: 0, log2: 5)
    let dsdb = (offset: 32, log2: 5)
    let root = (offset: 2048, log2: 11)
    let leaf = (offset: 4096, log2: 12)
    func address(_ b: (offset: Int, log2: Int)) -> UInt32 { UInt32(b.offset | b.log2) }
    var free = [[Int]](repeating: [], count: 32)
    for k in 5...30 { free[k] = [1 << k] }   // splitting 2^31 down to the 32-byte header
    for used in [dsdb, root, leaf] { free[used.log2].removeAll { $0 == used.offset } }
    _ = header

    var leafNode = Writer()
    leafNode.u32(0)                        // 0 = leaf (no child pointer)
    leafNode.u32(UInt32(records.count))
    for r in records { r.encode(into: &leafNode) }
    guard leafNode.data.count <= 4096 else { throw NSError(domain: "dmg-layout", code: 1, userInfo: [NSLocalizedDescriptionKey: "layout records do not fit one node"]) }
    leafNode.pad(to: 4096)

    var info = Writer()
    info.u32(2)                            // root node: block 2
    info.u32(0)                            // tree levels below the root
    info.u32(UInt32(records.count))
    info.u32(1)                            // nodes
    info.u32(0x1000)                       // page size
    info.pad(to: 32)

    var rootBlock = Writer()
    let blocks = [address(root), address(dsdb), address(leaf)]
    rootBlock.u32(UInt32(blocks.count))
    rootBlock.u32(0)
    for b in blocks { rootBlock.u32(b) }
    for _ in blocks.count..<256 { rootBlock.u32(0) }   // the address table is padded to 256 entries
    rootBlock.u32(1)                       // table of contents: "DSDB" -> block 1
    rootBlock.u8(4); rootBlock.code("DSDB"); rootBlock.u32(1)
    for list in free {
        rootBlock.u32(UInt32(list.count))
        for offset in list { rootBlock.u32(UInt32(offset)) }
    }
    rootBlock.pad(to: 2048)

    var file = Writer()
    file.u32(1)
    file.code("Bud1")
    file.u32(UInt32(root.offset)); file.u32(2048); file.u32(UInt32(root.offset))
    file.bytes(Data([0x00, 0x00, 0x10, 0x0c, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0b, 0x00, 0x00, 0x00, 0x00]))
    func place(_ block: Writer, at offset: Int) {
        file.pad(to: 4 + offset)
        file.bytes(block.data)
    }
    place(info, at: dsdb.offset)
    place(rootBlock, at: root.offset)
    place(leafNode, at: leaf.offset)
    try file.data.write(to: volume.appendingPathComponent(".DS_Store"))
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("background", 2):
    let folder = URL(fileURLWithPath: args[1])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try drawBackground(scale: 1).write(to: folder.appendingPathComponent("background.png"))
    try drawBackground(scale: 2).write(to: folder.appendingPathComponent("background@2x.png"))
case ("dsstore", 3):
    try writeDSStore(volume: URL(fileURLWithPath: args[1]), background: URL(fileURLWithPath: args[2]))
default:
    FileHandle.standardError.write(Data("usage: dmg-layout.swift background <folder> | dsstore <volume root> <background file>\n".utf8))
    exit(2)
}
