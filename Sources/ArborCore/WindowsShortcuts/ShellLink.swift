import Foundation

/// What a Windows .lnk file records (MS-SHLLINK revision 10.0, FE-215); all of it is hostile outside data.
public struct ShellLink: Equatable, Sendable {
    public var localPath: String?
    public var networkPath: String?
    public var relativePath: String?
    public var workingDirectory: String?
    public var arguments: String?
    public var comment: String?
    public var environmentTarget: String?
    public var targetModified: Date?
    public var targetSize: Int64 = 0

    public init() {}

    /// Any violation throws: a partly parsed link is never acted on.
    public static func parse(_ bytes: [UInt8]) throws -> ShellLink {
        var parser = try ShellLinkParser(bytes)
        return try parser.parse()
    }
}

/// A bounds-checked part of the file. Every read is optional, and ranges are tested without adding outside values.
private struct ByteWindow {
    /// Longest string taken from a link; Windows paths and arguments stop well short of it.
    static let maxStringUnits = 32_767

    private let bytes: [UInt8]
    private let base: Int
    let count: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        base = 0
        count = bytes.count
    }

    private init(bytes: [UInt8], base: Int, count: Int) {
        self.bytes = bytes
        self.base = base
        self.count = count
    }

    func contains(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    func window(offset: Int, length: Int) -> ByteWindow? {
        guard contains(offset: offset, length: length) else { return nil }
        return ByteWindow(bytes: bytes, base: base + offset, count: length)
    }

    func u16(at offset: Int) -> UInt16? { unsigned(at: offset, width: 2).map { UInt16(truncatingIfNeeded: $0) } }
    func u32(at offset: Int) -> UInt32? { unsigned(at: offset, width: 4).map { UInt32(truncatingIfNeeded: $0) } }
    func u64(at offset: Int) -> UInt64? { unsigned(at: offset, width: 8) }

    /// A size or offset; clamping can't trap, and a 64-bit Int holds any u32 unchanged.
    func length(at offset: Int) -> Int? { u32(at: offset).map { Int(clamping: $0) } }
    func shortLength(at offset: Int) -> Int? { u16(at: offset).map { Int(clamping: $0) } }

    func starts(with expected: [UInt8], at offset: Int) -> Bool {
        guard contains(offset: offset, length: expected.count) else { return false }
        return expected.indices.allSatisfy { bytes[base + offset + $0] == expected[$0] }
    }

    private func unsigned(at offset: Int, width: Int) -> UInt64? {
        guard contains(offset: offset, length: width) else { return nil }
        return (0..<width).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[base + offset + $1]) }
    }

    var hasZeroByte: Bool { (0..<count).contains { bytes[base + $0] == 0 } }
    var hasZeroUnit: Bool { utf16Units.contains(0) }

    private var utf16Units: [UInt16] {
        stride(from: 0, to: count - 1, by: 2).map { UInt16(bytes[base + $0]) | UInt16(bytes[base + $0 + 1]) << 8 }
    }

    /// Invalid sequences are replaced, never trapped on.
    var utf16Text: String { String(decoding: utf16Units, as: UTF16.self) }

    /// CP1252 refuses a few undefined bytes, so Latin-1 stands in. The writer's real code page isn't recorded.
    var ansiText: String {
        let slice = bytes[base..<(base + count)]
        return String(bytes: slice, encoding: .windowsCP1252) ?? String(bytes: slice, encoding: .isoLatin1) ?? ""
    }

    /// The text from `offset` to its NUL; nil unless the NUL lies inside the window and under the cap.
    func terminatedANSI(at offset: Int) -> String? {
        var end = offset
        while contains(offset: end, length: 1), end - offset <= Self.maxStringUnits {
            if bytes[base + end] == 0 { return window(offset: offset, length: end - offset)?.ansiText }
            end += 1
        }
        return nil
    }

    /// As `terminatedANSI`, in two-byte units.
    func terminatedUTF16(at offset: Int) -> String? {
        var end = offset
        while contains(offset: end, length: 2), end - offset <= 2 * Self.maxStringUnits {
            if bytes[base + end] == 0, bytes[base + end + 1] == 0 { return window(offset: offset, length: end - offset)?.utf16Text }
            end += 2
        }
        return nil
    }
}

private struct ShellLinkParser {
    private struct LinkFlags: OptionSet {
        let rawValue: UInt32
        static let hasIDList = LinkFlags(rawValue: 0x1)
        static let hasLinkInfo = LinkFlags(rawValue: 0x2)
        static let hasName = LinkFlags(rawValue: 0x4)
        static let hasRelativePath = LinkFlags(rawValue: 0x8)
        static let hasWorkingDirectory = LinkFlags(rawValue: 0x10)
        static let hasArguments = LinkFlags(rawValue: 0x20)
        static let hasIconLocation = LinkFlags(rawValue: 0x40)
        static let isUnicode = LinkFlags(rawValue: 0x80)
        static let forceNoLinkInfo = LinkFlags(rawValue: 0x100)
    }

    private static let headerSize = 0x4C
    /// 00021401-0000-0000-C000-000000000046 as stored.
    private static let linkCLSID: [UInt8] = [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]
    private static let minLinkInfoSize = 0x1C
    private static let unicodeLinkInfoHeaderSize = 0x24
    private static let minNetworkLinkSize = 0x14
    private static let maxExtraBlocks = 64
    private static let environmentBlockSignature: UInt32 = 0xA000_0001
    private static let environmentBlockSize = 0x314
    private static let environmentUnicodeOffset = 268

    private let file: ByteWindow
    private let flags: LinkFlags
    private var cursor = ShellLinkParser.headerSize
    private var link = ShellLink()

    init(_ bytes: [UInt8]) throws {
        file = ByteWindow(bytes)
        guard file.count >= Self.headerSize, file.length(at: 0) == Self.headerSize, file.starts(with: Self.linkCLSID, at: 4),
              let rawFlags = file.u32(at: 20), let written = file.u64(at: 44),
              let size = file.u32(at: 52) else { throw WindowsShortcutError.notAShortcut }
        flags = LinkFlags(rawValue: rawFlags)
        link.targetModified = Self.date(fromFileTime: written)
        link.targetSize = Int64(clamping: size)
    }

    mutating func parse() throws -> ShellLink {
        try skipIDList()
        try readLinkInfo()
        try readStrings()
        try readExtraData()
        return link
    }

    /// Shell items are never interpreted, so nothing can be launched or resolved from them.
    private mutating func skipIDList() throws {
        guard flags.contains(.hasIDList) else { return }
        guard let size = file.shortLength(at: cursor), file.contains(offset: cursor + 2, length: size) else {
            throw WindowsShortcutError.malformed
        }
        cursor += 2 + size
    }

    private mutating func readLinkInfo() throws {
        guard flags.contains(.hasLinkInfo) else { return }
        guard let size = file.length(at: cursor), size >= Self.minLinkInfoSize,
              let info = file.window(offset: cursor, length: size),
              let headerSize = info.length(at: 4), headerSize >= Self.minLinkInfoSize, headerSize <= size,
              let infoFlags = info.u32(at: 8), let localOffset = info.length(at: 16),
              let networkOffset = info.length(at: 20), let suffixOffset = info.length(at: 24) else { throw WindowsShortcutError.malformed }
        cursor += size
        let hasUnicode = headerSize >= Self.unicodeLinkInfoHeaderSize
        let suffix = try Self.text(ansi: suffixOffset, unicode: hasUnicode ? info.length(at: 32) : nil, in: info, past: headerSize) ?? ""
        var local: String?
        var network: String?
        if infoFlags & 0x1 != 0 {
            guard let base = try Self.text(ansi: localOffset, unicode: hasUnicode ? info.length(at: 28) : nil, in: info, past: headerSize) else {
                throw WindowsShortcutError.malformed
            }
            local = base + suffix
        }
        if infoFlags & 0x2 != 0 {
            let share = try Self.networkName(at: networkOffset, in: info, past: headerSize)
            network = suffix.isEmpty || share.hasSuffix("\\") ? share + suffix : share + "\\" + suffix
        }
        guard !flags.contains(.forceNoLinkInfo) else { return }
        link.localPath = Self.nonEmpty(local)
        link.networkPath = Self.nonEmpty(network)
    }

    /// CommonNetworkRelativeLink is its own window: its offsets count from its own start, not from LinkInfo (§2.3.2).
    private static func networkName(at offset: Int, in info: ByteWindow, past headerSize: Int) throws -> String {
        guard offset >= headerSize, let size = info.length(at: offset), size >= minNetworkLinkSize,
              let network = info.window(offset: offset, length: size), let nameOffset = network.length(at: 8) else {
            throw WindowsShortcutError.malformed
        }
        var unicodeOffset: Int?
        if nameOffset > minNetworkLinkSize {
            guard let value = network.length(at: minNetworkLinkSize) else { throw WindowsShortcutError.malformed }
            unicodeOffset = value
        }
        guard let name = try text(ansi: nameOffset, unicode: unicodeOffset, in: network, past: minNetworkLinkSize) else {
            throw WindowsShortcutError.malformed
        }
        return name
    }

    /// Every offset that is set is checked; the Unicode text wins when there is one. Zero means "not recorded".
    private static func text(ansi: Int, unicode: Int?, in window: ByteWindow, past floor: Int) throws -> String? {
        var result: String?
        if ansi != 0 {
            guard ansi >= floor, let text = window.terminatedANSI(at: ansi) else { throw WindowsShortcutError.malformed }
            result = text
        }
        if let unicode, unicode != 0 {
            guard unicode >= floor, let text = window.terminatedUTF16(at: unicode) else { throw WindowsShortcutError.malformed }
            result = text
        }
        return result
    }

    private mutating func readStrings() throws {
        if flags.contains(.hasName) { link.comment = try countedString() }
        if flags.contains(.hasRelativePath) { link.relativePath = try countedString() }
        if flags.contains(.hasWorkingDirectory) { link.workingDirectory = try countedString() }
        if flags.contains(.hasArguments) { link.arguments = try countedString() }
        // Skipped, not stored: a UNC icon path must never reach anything that would fetch it.
        if flags.contains(.hasIconLocation) { _ = try nextCountedWindow() }
    }

    private mutating func countedString() throws -> String? {
        let window = try nextCountedWindow()
        let isUnicode = flags.contains(.isUnicode)
        guard !(isUnicode ? window.hasZeroUnit : window.hasZeroByte) else { throw WindowsShortcutError.malformed }
        return Self.nonEmpty(isUnicode ? window.utf16Text : window.ansiText)
    }

    private mutating func nextCountedWindow() throws -> ByteWindow {
        let unitSize = flags.contains(.isUnicode) ? 2 : 1
        guard let units = file.shortLength(at: cursor), units <= ByteWindow.maxStringUnits,
              let window = file.window(offset: cursor + 2, length: units * unitSize) else { throw WindowsShortcutError.malformed }
        cursor += 2 + window.count
        return window
    }

    /// A file ending where the terminal block should be is tolerated: this section only feeds display and blocking.
    private mutating func readExtraData() throws {
        var blocks = 0
        while let size = file.length(at: cursor), size >= 4 {
            blocks += 1
            guard size >= 8, blocks <= Self.maxExtraBlocks, let block = file.window(offset: cursor, length: size) else {
                throw WindowsShortcutError.malformed
            }
            if block.u32(at: 4) == Self.environmentBlockSignature, link.environmentTarget == nil {
                guard size == Self.environmentBlockSize, let target = block.terminatedUTF16(at: Self.environmentUnicodeOffset) else {
                    throw WindowsShortcutError.malformed
                }
                link.environmentTarget = Self.nonEmpty(target)
            }
            cursor += size
        }
    }

    private static func nonEmpty(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }

    /// Through Double, so no value can trap; 0 and anything past year 9999 mean "not recorded".
    private static func date(fromFileTime ticks: UInt64) -> Date? {
        let unixEpochSeconds = 11_644_473_600.0
        let year10000UnixSeconds = 253_402_300_800.0
        guard ticks != 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000 - unixEpochSeconds
        return seconds < year10000UnixSeconds ? Date(timeIntervalSince1970: seconds) : nil
    }
}
