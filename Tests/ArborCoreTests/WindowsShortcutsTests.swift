import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ArborCore

// FE-215, docs/features/windows-shortcuts.md. Fixtures are built byte by byte from MS-SHLLINK, so no binaries are stored.

private func le16(_ value: UInt16) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
private func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
private func utf16(_ text: String) -> [UInt8] { text.utf16.flatMap(le16) }
private func ansiZ(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
private func utf16Z(_ text: String) -> [UInt8] { utf16(text) + [0, 0] }

private enum LinkFlag {
    static let idList: UInt32 = 0x1, linkInfo: UInt32 = 0x2, name: UInt32 = 0x4, relative: UInt32 = 0x8
    static let workingDir: UInt32 = 0x10, arguments: UInt32 = 0x20, icon: UInt32 = 0x40, unicode: UInt32 = 0x80
    static let forceNoLinkInfo: UInt32 = 0x100
}

private struct LinkFile {
    var attributes: UInt32 = 0
    var writeTime: UInt64 = 0
    var fileSize: UInt32 = 0
    var extraFlags: UInt32 = 0
    var idList: [UInt8]?
    var linkInfo: [UInt8]?
    var name: String?
    var relative: String?
    var workingDir: String?
    var arguments: String?
    var icon: String?
    var isUnicode = true
    var extra: [UInt8] = le32(0)

    func bytes() -> [UInt8] {
        var flags = extraFlags | (isUnicode ? LinkFlag.unicode : 0)
        let strings: [(String?, UInt32)] = [(name, LinkFlag.name), (relative, LinkFlag.relative), (workingDir, LinkFlag.workingDir),
                                            (arguments, LinkFlag.arguments), (icon, LinkFlag.icon)]
        var stringData: [UInt8] = []
        for (text, flag) in strings {
            guard let text else { continue }
            flags |= flag
            let units = UInt16(isUnicode ? text.utf16.count : text.utf8.count)
            stringData += le16(units) + (isUnicode ? utf16(text) : Array(text.utf8))
        }
        if idList != nil { flags |= LinkFlag.idList }
        if linkInfo != nil { flags |= LinkFlag.linkInfo }
        var out = le32(0x4C) + linkCLSID + le32(flags) + le32(attributes)
        out += [UInt8](repeating: 0, count: 16)
        out += withUnsafeBytes(of: writeTime.littleEndian, Array.init)
        out += le32(fileSize) + [UInt8](repeating: 0, count: 20)
        if let idList { out += le16(UInt16(idList.count)) + idList }
        if let linkInfo { out += linkInfo }
        return out + stringData + extra
    }
}

private let linkCLSID: [UInt8] = [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]

/// §2.3 LinkInfo with a local path; layout is header, volume id, ANSI strings, then Unicode strings.
private func localInfo(base: String, suffix: String = "", withUnicode: Bool = true) -> [UInt8] {
    let headerSize = withUnicode ? 0x24 : 0x1C
    let volume = le32(16) + [UInt8](repeating: 0, count: 12)
    let baseOffset = headerSize + volume.count
    let suffixOffset = baseOffset + ansiZ(base).count
    let unicodeBase = suffixOffset + ansiZ(suffix).count
    let unicodeSuffix = unicodeBase + utf16Z(base).count
    var body = volume + ansiZ(base) + ansiZ(suffix)
    if withUnicode { body += utf16Z(base) + utf16Z(suffix) }
    var header = le32(UInt32(headerSize + body.count)) + le32(UInt32(headerSize)) + le32(1)
    header += le32(UInt32(headerSize)) + le32(UInt32(baseOffset)) + le32(0) + le32(UInt32(suffixOffset))
    if withUnicode { header += le32(UInt32(unicodeBase)) + le32(UInt32(unicodeSuffix)) }
    return header + body
}

/// §2.3 with a §2.3.2 CommonNetworkRelativeLink; its offsets count from its own start.
private func networkInfo(share: String, suffix: String = "", withUnicode: Bool = true) -> [UInt8] {
    let nameOffset = withUnicode ? 0x1C : 0x14
    var networkBody = ansiZ(share)
    if withUnicode { networkBody += utf16Z(share) }
    var network = le32(UInt32(nameOffset + networkBody.count)) + le32(0x2) + le32(UInt32(nameOffset)) + le32(0) + le32(0x0020_0000)
    if withUnicode { network += le32(UInt32(nameOffset + ansiZ(share).count)) + le32(0) }
    network += networkBody
    let suffixOffset = 0x1C + network.count
    let body = network + ansiZ(suffix)
    return le32(UInt32(0x1C + body.count)) + le32(0x1C) + le32(2) + le32(0) + le32(0) + le32(0x1C) + le32(UInt32(suffixOffset)) + body
}

private func environmentBlock(_ target: String) -> [UInt8] {
    let unicode = utf16Z(target)
    return le32(0x314) + le32(0xA000_0001) + [UInt8](repeating: 0, count: 260) + unicode + [UInt8](repeating: 0, count: 520 - unicode.count)
}

private func patch(_ bytes: [UInt8], at offset: Int, u32 value: UInt32) -> [UInt8] {
    var out = bytes
    out.replaceSubrange(offset..<(offset + 4), with: le32(value))
    return out
}

@Suite struct ShellLinkParsingTests {
    private let infoStart = 0x4C

    @Test func readsUnicodeLinkWithEveryString() throws {
        var file = LinkFile()
        file.attributes = 0x10
        file.fileSize = 4096
        file.linkInfo = localInfo(base: "C:\\Users\\me\\", suffix: "Résumé.txt")
        file.name = "A comment"
        file.relative = "..\\Résumé.txt"
        file.workingDir = "C:\\Users\\me"
        file.arguments = "/quiet"
        file.icon = "\\\\server\\share\\icon.ico"
        let link = try ShellLink.parse(file.bytes())
        #expect(link.localPath == "C:\\Users\\me\\Résumé.txt")
        #expect(link.relativePath == "..\\Résumé.txt")
        #expect(link.workingDirectory == "C:\\Users\\me")
        #expect(link.arguments == "/quiet")
        #expect(link.comment == "A comment")
        #expect(link.targetSize == 4096)
    }

    @Test func readsANSILinkAndOlderLinkInfoHeader() throws {
        var file = LinkFile()
        file.isUnicode = false
        file.linkInfo = localInfo(base: "C:\\a.txt", withUnicode: false)
        file.relative = ".\\a.txt"
        let link = try ShellLink.parse(file.bytes())
        #expect(link.localPath == "C:\\a.txt")
        #expect(link.relativePath == ".\\a.txt")
    }

    @Test func worksWithoutLinkInfoAndSkipsIDList() throws {
        var file = LinkFile()
        file.idList = [1, 2, 3, 4, 5]
        file.relative = "a.txt"
        let link = try ShellLink.parse(file.bytes())
        #expect(link.localPath == nil && link.networkPath == nil)
        #expect(link.relativePath == "a.txt")
    }

    @Test(arguments: [true, false]) func readsNetworkTargetFromItsOwnStructure(withUnicode: Bool) throws {
        var file = LinkFile()
        file.linkInfo = networkInfo(share: "\\\\SERVER\\share", suffix: "docs\\a.txt", withUnicode: withUnicode)
        #expect(try ShellLink.parse(file.bytes()).networkPath == "\\\\SERVER\\share\\docs\\a.txt")
    }

    @Test func networkOffsetsAreCheckedAgainstTheirOwnWindow() throws {
        var file = LinkFile()
        file.linkInfo = networkInfo(share: "\\\\S\\s", suffix: "a", withUnicode: false)
        let bytes = file.bytes()
        let structure = infoStart + 0x1C
        // Inside LinkInfo, but past the end of the network structure.
        let networkSize = 0x14 + ansiZ("\\\\S\\s").count
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(bytes, at: structure + 8, u32: UInt32(networkSize))) }
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(bytes, at: structure, u32: 0x10)) }
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(bytes, at: structure, u32: 0xFFFF_FFFF)) }
    }

    @Test func readsEnvironmentTargetFromUnicodeField() throws {
        var file = LinkFile()
        file.extra = environmentBlock("%windir%\\notepad.txt") + le32(0)
        #expect(try ShellLink.parse(file.bytes()).environmentTarget == "%windir%\\notepad.txt")
    }

    @Test func forceNoLinkInfoDiscardsThePaths() throws {
        var file = LinkFile()
        file.extraFlags = LinkFlag.forceNoLinkInfo
        file.linkInfo = localInfo(base: "C:\\a.txt")
        file.relative = "a.txt"
        let link = try ShellLink.parse(file.bytes())
        #expect(link.localPath == nil)
        #expect(link.relativePath == "a.txt")
    }

    @Test func wrongHeaderIsNotAShortcut() {
        let good = LinkFile().bytes()
        #expect(throws: WindowsShortcutError.notAShortcut) { try ShellLink.parse(patch(good, at: 0, u32: 0x4D)) }
        #expect(throws: WindowsShortcutError.notAShortcut) { try ShellLink.parse(patch(good, at: 4, u32: 0)) }
        #expect(throws: WindowsShortcutError.notAShortcut) { try ShellLink.parse([]) }
        #expect(throws: WindowsShortcutError.notAShortcut) { try ShellLink.parse(Array(good.prefix(75))) }
    }

    @Test func idListPastTheEndIsMalformed() {
        var bytes = LinkFile().bytes()
        bytes.replaceSubrange(20..<24, with: le32(LinkFlag.idList))
        bytes.insert(contentsOf: le16(0xFFFF), at: 0x4C)
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(bytes) }
    }

    @Test(arguments: [UInt32(0), 4, 0x1B, 0xFFFF_FFFF]) func badLinkInfoSizeIsMalformed(size: UInt32) {
        var file = LinkFile()
        file.linkInfo = localInfo(base: "C:\\a.txt")
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(file.bytes(), at: infoStart, u32: size)) }
    }

    @Test(arguments: [UInt32(0), 0x1B, 0xFFFF_FFFF]) func badLinkInfoHeaderSizeIsMalformed(size: UInt32) {
        var file = LinkFile()
        file.linkInfo = localInfo(base: "C:\\a.txt")
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(file.bytes(), at: infoStart + 4, u32: size)) }
    }

    @Test(arguments: [16, 24, 28, 32]) func everyLinkInfoOffsetIsRangeChecked(field: Int) {
        var file = LinkFile()
        let info = localInfo(base: "C:\\a.txt")
        file.linkInfo = info
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(file.bytes(), at: infoStart + field, u32: 0xFFFF_FFFF)) }
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(file.bytes(), at: infoStart + field, u32: UInt32(info.count))) }
        // An offset into the header is outside the strings too.
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(patch(file.bytes(), at: infoStart + field, u32: 4)) }
    }

    @Test func unterminatedStringsAreMalformed() {
        // A LinkInfo whose window ends in the middle of each kind of string.
        func info(_ tail: [UInt8], unicode: Bool) -> [UInt8] {
            let headerSize = unicode ? 0x24 : 0x1C
            var header = le32(UInt32(headerSize + tail.count)) + le32(UInt32(headerSize)) + le32(1) + le32(0)
            header += le32(unicode ? 0 : UInt32(headerSize)) + le32(0) + le32(0)
            if unicode { header += le32(UInt32(headerSize)) + le32(0) }
            return header + tail
        }
        var file = LinkFile()
        file.linkInfo = info(Array("C:\\a".utf8), unicode: false)
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(file.bytes()) }
        file.linkInfo = info(utf16("C:\\a"), unicode: true)
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(file.bytes()) }
        file.linkInfo = info(utf16("C:\\a") + [0], unicode: true)   // odd-length window
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(file.bytes()) }
    }

    @Test func oversizedAndEmbeddedNULCountsAreMalformed() {
        var bytes = LinkFile().bytes()
        bytes.replaceSubrange(20..<24, with: le32(LinkFlag.relative | LinkFlag.unicode))
        bytes.insert(contentsOf: le16(0x7FFF) + utf16("ab"), at: 0x4C)
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(bytes) }
        bytes[0x4C] = 0xFF
        bytes[0x4D] = 0xFF    // over the cap as well
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(bytes) }

        var file = LinkFile()
        file.relative = "a\u{0}.exe"
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(file.bytes()) }
        file.isUnicode = false
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(file.bytes()) }
    }

    @Test func extraDataSizes() throws {
        var file = LinkFile()
        file.relative = "a.txt"
        for size in [UInt32(0), 3] {
            file.extra = le32(size)
            #expect(try ShellLink.parse(file.bytes()).relativePath == "a.txt")
        }
        file.extra = []    // no terminal block at all
        #expect(try ShellLink.parse(file.bytes()).relativePath == "a.txt")
        for size in [UInt32(4), 7, 0xFFFF_FFFF, 100] {
            file.extra = le32(size) + le32(0)
            #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(file.bytes()) }
        }
    }

    @Test func tooManyExtraBlocksAreMalformed() throws {
        let block = le32(8) + le32(0xA000_0002)
        var file = LinkFile()
        file.extra = Array(repeating: block, count: 64).flatMap { $0 } + le32(0)
        _ = try ShellLink.parse(file.bytes())
        file.extra = Array(repeating: block, count: 65).flatMap { $0 } + le32(0)
        #expect(throws: WindowsShortcutError.malformed) { try ShellLink.parse(file.bytes()) }
    }

    @Test func fileTimes() throws {
        var file = LinkFile()
        #expect(try ShellLink.parse(file.bytes()).targetModified == nil)
        file.writeTime = 116_444_736_000_000_000
        #expect(try ShellLink.parse(file.bytes()).targetModified == Date(timeIntervalSince1970: 0))
        file.writeTime = .max
        #expect(try ShellLink.parse(file.bytes()).targetModified == nil)
    }

    private var sample: [UInt8] {
        var file = LinkFile()
        file.idList = [1, 2, 3]
        file.linkInfo = networkInfo(share: "\\\\S\\s", suffix: "a.txt")
        file.name = "n"
        file.relative = "a.txt"
        file.workingDir = "w"
        file.icon = "i"
        file.extra = environmentBlock("%x%\\y") + le32(0)
        return file.bytes()
    }

    @Test func everyTruncationIsSafe() {
        let bytes = sample
        for length in 0..<bytes.count { _ = try? ShellLink.parse(Array(bytes.prefix(length))) }
    }

    @Test func seededMutationsAreSafe() {
        // A trap in the parser fails the whole test run, which is the assertion here.
        var random = SplitMix64(seed: 0x215)
        let original = sample
        let interesting: [UInt8] = [0, 1, 0x7F, 0x80, 0xFF]
        for _ in 0..<20_000 {
            var bytes = original
            for _ in 0..<(1 + Int(random.next() % 8)) {
                let index = Int(random.next() % UInt64(bytes.count))
                bytes[index] = random.next() % 2 == 0 ? UInt8(truncatingIfNeeded: random.next()) : interesting[Int(random.next() % 5)]
            }
            _ = try? ShellLink.parse(bytes)
        }
    }
}

/// Deterministic, so a failure can be reproduced.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct InternetShortcutTests {
    private func parsed(_ text: String) throws -> InternetShortcut { try InternetShortcut.parse(Array(text.utf8)) }
    private func address(_ raw: String) -> Result<URL, AddressRefusal> { InternetShortcut(rawAddress: raw).address }

    @Test func parsesLineEndingsAndCaseInsensitively() throws {
        #expect(try parsed("[InternetShortcut]\r\nURL=https://example.com/\r\n").rawAddress == "https://example.com/")
        #expect(try parsed("[internetshortcut]\nurl=https://example.com/a\n").rawAddress == "https://example.com/a")
    }

    @Test func parsesByteOrderMarksAndLatin1() throws {
        let body = "[InternetShortcut]\r\nURL=https://example.com/\r\n"
        #expect(try InternetShortcut.parse([0xEF, 0xBB, 0xBF] + Array(body.utf8)).rawAddress == "https://example.com/")
        #expect(try InternetShortcut.parse([0xFF, 0xFE] + utf16(body)).rawAddress == "https://example.com/")
        let bigEndian = body.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        #expect(try InternetShortcut.parse([0xFE, 0xFF] + bigEndian).rawAddress == "https://example.com/")
        let latin1 = Array("[InternetShortcut]\nURL=https://example.com/caf".utf8) + [0xE9]
        #expect(try InternetShortcut.parse(latin1).rawAddress == "https://example.com/café")
    }

    @Test func noSectionIsNotAShortcut() {
        #expect(throws: WindowsShortcutError.notAShortcut) { try parsed("URL=https://example.com/") }
        #expect(throws: WindowsShortcutError.notAShortcut) { try parsed("[Other]\nURL=https://example.com/") }
    }

    @Test func onlyTheFirstURLInTheFirstSectionCounts() throws {
        #expect(try parsed("[Other]\nURL=https://evil.example/\n[InternetShortcut]\nURL=https://good.example/\n").rawAddress == "https://good.example/")
        #expect(try parsed("[InternetShortcut]\nURL=https://first.example/\nURL=https://second.example/\n").rawAddress == "https://first.example/")
        #expect(try parsed("[InternetShortcut]\nIconFile=x\n[Other]\nURL=https://evil.example/\n").rawAddress == nil)
    }

    @Test func lineCapApplies() throws {
        let filler = String(repeating: "a=b\n", count: InternetShortcut.maxLines)
        #expect(throws: WindowsShortcutError.malformed) { try parsed("[InternetShortcut]\n" + filler + "URL=https://example.com/") }
        #expect(try parsed("[InternetShortcut]\nURL=https://example.com/\n" + filler).rawAddress == "https://example.com/")
    }

    @Test(arguments: ["http://example.com/", "https://example.com/path?q=1#f", "HTTPS://example.com/"])
    func webAddressesPass(raw: String) throws {
        #expect(try address(raw).get().absoluteString == raw)
    }

    @Test func wwwGetsHTTPS() throws {
        #expect(try address("www.example.com").get().absoluteString == "https://www.example.com")
    }

    @Test(arguments: [("file:///etc/passwd", "file"), ("smb://server/share", "smb"), ("ftp://x.example/", "ftp"), ("mailto:a@b.example", "mailto"),
                      ("javascript:alert(1)", "javascript"), ("data:text/html,x", "data"), ("vbscript:x", "vbscript"),
                      ("search-ms:query=x", "search-ms"), ("myapp://open", "myapp"), ("file:///C:\\Windows", "file")])
    func otherSchemesAreRefused(raw: String, scheme: String) {
        #expect(address(raw) == .failure(.unsupportedScheme(scheme)))
    }

    @Test func refusedShapes() {
        #expect(address("") == .failure(.missing))
        #expect(InternetShortcut(rawAddress: nil).address == .failure(.missing))
        #expect(address("https://user@example.com/") == .failure(.hasCredentials))
        #expect(address("https://user:pw@example.com/") == .failure(.hasCredentials))
        #expect(address("https://good.example\\@evil.example/") == .failure(.unsafeCharacters))
        #expect(address("https://example.com/a b") == .failure(.unsafeCharacters))
        #expect(address("https://example.com/a\tb") == .failure(.unsafeCharacters))
        #expect(address("https://example.com/a\nb") == .failure(.unsafeCharacters))
        #expect(address("https://example.com/a\u{85}b") == .failure(.unsafeCharacters))
        #expect(address("https://example.com/a\u{7F}b") == .failure(.unsafeCharacters))
        #expect(address("https://ex%61mple.com/") == .failure(.unsafeCharacters))
        #expect(address("example.com") == .failure(.notWebAddress))
        #expect(address("https://") == .failure(.notWebAddress))
    }

    @Test func hostileUnicodeComesOutEscaped() throws {
        let idn = try address("https://bücher.example/").get()
        #expect(idn.absoluteString == "https://xn--bcher-kva.example/")
        let bidi = try address("https://example.com/a\u{202E}b").get()
        #expect(bidi.absoluteString == "https://example.com/a%E2%80%AEb")
    }

    @Test func theConfirmedAddressIsNeverCutOff() throws {
        let base = "https://example.com/"
        let fits = base + String(repeating: "a", count: InternetShortcut.maxAddressLength - base.count)
        let url = try address(fits).get()
        #expect(url.absoluteString == fits)
        #expect(UntrustedText.display(url.absoluteString) == url.absoluteString)
        #expect(address(fits + "a") == .failure(.tooLong))
        // Under the cap as typed, over it once each character is escaped.
        let grows = base + String(repeating: "é", count: 300)
        #expect(grows.count < InternetShortcut.maxAddressLength)
        #expect(address(grows) == .failure(.tooLong))
    }
}

@Suite struct WindowsShortcutPolicyTests {
    private static let folder = TargetProbe.Entry(kind: .directory, device: 1)
    private static let file = TargetProbe.Entry(kind: .regularFile, device: 1)
    private static let other = TargetProbe.Entry(kind: .other, device: 1)

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        var all: [String] { lock.withLock { paths } }
        func add(_ path: String) { lock.withLock { paths.append(path) } }
    }

    private func probe(_ entries: [String: TargetProbe.Entry], calls: Calls = Calls(), packages: Set<String> = []) -> TargetProbe {
        TargetProbe(entry: { path, _ in calls.add(path); return entries[path] },
                    contentType: { UTType(filenameExtension: $0.pathExtension) },
                    isPackage: { packages.contains($0.path) })
    }

    private func link(relative: String? = nil, local: String? = nil, network: String? = nil, environment: String? = nil, arguments: String? = nil) -> ShellLink {
        var link = ShellLink()
        link.relativePath = relative
        link.localPath = local
        link.networkPath = network
        link.environmentTarget = environment
        link.arguments = arguments
        return link
    }

    private let home = URL(fileURLWithPath: "/Users/me/Fixture/x.lnk")
    private let onVolume = URL(fileURLWithPath: "/Volumes/USB/a/b/x.lnk")
    private let volume = URL(fileURLWithPath: "/Volumes/USB", isDirectory: true)

    private func destination(_ link: ShellLink, shortcut: URL? = nil, volumeRoot: URL? = nil, _ probe: TargetProbe) -> LinkDestination {
        WindowsShortcutPolicy.destination(for: link, shortcut: shortcut ?? home, volumeRoot: volumeRoot, probe: probe)
    }

    @Test func argumentsBlockEvenWhenTheTargetExists() {
        let disk = probe(["/Users/me/Fixture": Self.folder, "/Users/me/Fixture/a.pdf": Self.file])
        #expect(destination(link(relative: "a.pdf", arguments: "/s"), disk) == .blocked(.hasArguments))
    }

    @Test(arguments: ["evil.exe", "evil.exe.", "evil.exe ", "..\\tools\\EVIL.EXE", "setup.msi", "a.bat", "x.appref-ms"])
    func windowsProgramsBlock(name: String) {
        guard case .blocked(.windowsProgram) = destination(link(relative: name), probe([:])) else {
            Issue.record("\(name) was not blocked as a Windows program")
            return
        }
    }

    @Test func aWindowsProgramInAnyRecordedTargetBlocks() {
        #expect(destination(link(relative: "a.pdf", local: "C:\\run.exe"), probe([:])) == .blocked(.windowsProgram("run.exe")))
        #expect(destination(link(environment: "%windir%\\cmd.exe"), probe([:])) == .blocked(.windowsProgram("cmd.exe")))
    }

    @Test func unmappedTargetsEachGiveTheirOwnReason() {
        let disk = probe([:])
        #expect(destination(link(local: "C:\\docs\\a.pdf"), disk) == .blocked(.driveLetter("C:\\docs\\a.pdf")))
        #expect(destination(link(local: "\\\\srv\\s\\a.pdf"), disk) == .blocked(.network("\\\\srv\\s\\a.pdf")))
        #expect(destination(link(network: "\\\\srv\\s\\a.pdf"), disk) == .blocked(.network("\\\\srv\\s\\a.pdf")))
        #expect(destination(link(environment: "%USERPROFILE%\\a.pdf"), disk) == .blocked(.windowsOnlyPath("%USERPROFILE%\\a.pdf")))
        #expect(destination(link(relative: "missing.pdf"), disk) == .blocked(.notFound("missing.pdf")))
        #expect(destination(link(), disk) == .blocked(.noPath))
    }

    @Test func aFolderBesideTheShortcutIsFollowed() {
        let disk = probe(["/Users/me/Fixture": Self.folder, "/Users/me/Fixture/sub": Self.folder])
        #expect(destination(link(relative: ".\\sub"), disk) == .folder(URL(fileURLWithPath: "/Users/me/Fixture/sub", isDirectory: true)))
    }

    @Test(arguments: ["next.js", "tools.com", "drivers.sys"]) func aRealFolderWithAProgramsExtensionIsFollowed(name: String) {
        let disk = probe(["/Users/me/Fixture": Self.folder, "/Users/me/Fixture/\(name)": Self.folder])
        #expect(destination(link(relative: ".\\\(name)", local: "C:\\proj\\\(name)"), disk)
                == .folder(URL(fileURLWithPath: "/Users/me/Fixture/\(name)", isDirectory: true)))
    }

    @Test func aFileWithAProgramsExtensionStaysRefusedThoughItExists() {
        let disk = probe(["/Users/me/Fixture": Self.folder, "/Users/me/Fixture/setup.exe": Self.file])
        #expect(destination(link(relative: ".\\setup.exe"), disk) == .blocked(.windowsProgram("setup.exe")))
    }

    @Test func allowedFileIsADocumentAndOthersAreRevealOnly() {
        let disk = probe(["/Users/me/Fixture": Self.folder, "/Users/me/Fixture/a.pdf": Self.file, "/Users/me/Fixture/run.command": Self.file,
                          "/Users/me/Fixture/Tool.app": Self.folder], packages: ["/Users/me/Fixture/Tool.app"])
        #expect(destination(link(relative: "a.pdf"), disk) == .document(URL(fileURLWithPath: "/Users/me/Fixture/a.pdf")))
        #expect(destination(link(relative: "run.command"), disk) == .revealOnly(URL(fileURLWithPath: "/Users/me/Fixture/run.command")))
        #expect(destination(link(relative: "Tool.app"), disk) == .revealOnly(URL(fileURLWithPath: "/Users/me/Fixture/Tool.app", isDirectory: true)))
    }

    @Test func parentReferencesStopAtTheShortcutsFolderOnTheStartupDisk() {
        let calls = Calls()
        let disk = probe(["/Users/me": Self.folder, "/Users/me/secret.pdf": Self.file], calls: calls)
        #expect(destination(link(relative: "..\\secret.pdf"), disk) == .blocked(.notFound("..\\secret.pdf")))
        #expect(destination(link(relative: "..\\..\\..\\net\\evil\\a.pdf"), disk) == .blocked(.notFound("..\\..\\..\\net\\evil\\a.pdf")))
        #expect(calls.all.isEmpty)
    }

    @Test func parentReferencesReachTheRootOfAVolumeAndNoFurther() {
        let root = "/Volumes/USB"
        let calls = Calls()
        let disk = probe([root: Self.folder, "\(root)/c.pdf": Self.file], calls: calls)
        #expect(destination(link(relative: "..\\..\\c.pdf"), shortcut: onVolume, volumeRoot: volume, disk)
                == .document(URL(fileURLWithPath: "\(root)/c.pdf")))
        let before = calls.all.count
        #expect(destination(link(relative: "..\\..\\..\\c.pdf"), shortcut: onVolume, volumeRoot: volume, disk)
                == .blocked(.notFound("..\\..\\..\\c.pdf")))
        #expect(calls.all.count == before)
    }

    @Test func aVolumeThatDoesntContainTheShortcutIsNotTheFloor() {
        let calls = Calls()
        #expect(destination(link(relative: "..\\a.pdf"), volumeRoot: volume, probe([:], calls: calls)) == .blocked(.notFound("..\\a.pdf")))
        #expect(calls.all.isEmpty)
    }

    @Test func aLinkInTheMiddleIsNeverWalkedThrough() {
        let calls = Calls()
        let disk = probe(["/Users/me/Fixture": Self.folder, "/Users/me/Fixture/link": Self.other], calls: calls)
        #expect(destination(link(relative: "link\\share\\a.pdf"), disk) == .blocked(.notFound("link\\share\\a.pdf")))
        #expect(calls.all == ["/Users/me/Fixture", "/Users/me/Fixture/link"])
    }

    @Test func nonRegularFinalItemsAndOtherDevicesAreRefused() {
        let disk = probe(["/Users/me/Fixture": Self.folder, "/Users/me/Fixture/pipe.pdf": Self.other, "/Users/me/Fixture/mount": .init(kind: .directory, device: 9),
                          "/Users/me/Fixture/a.txt": Self.file])
        #expect(destination(link(relative: "pipe.pdf"), disk) == .blocked(.notFound("pipe.pdf")))
        #expect(destination(link(relative: "mount"), disk) == .blocked(.notFound("mount")))
        #expect(destination(link(relative: "a.txt\\b.pdf"), disk) == .blocked(.notFound("a.txt\\b.pdf")))
    }

    @Test(arguments: ["a.pdf:stream", "C:a.pdf", "a\u{7}.pdf"]) func colonsAndControlsAreNeverProbed(relative: String) {
        let calls = Calls()
        #expect(destination(link(relative: relative), probe([:], calls: calls)) == .blocked(.notFound(relative)))
        #expect(calls.all.isEmpty)
    }

    @Test(arguments: ["pdf", "txt", "md", "csv", "rtf", "png", "jpg", "heic", "mp3", "mp4", "mov", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
                      "odt", "ods", "pages", "numbers", "key"])
    func namedDocumentTypesOpen(fileExtension: String) throws {
        #expect(WindowsShortcutPolicy.isDocument(try #require(UTType(filenameExtension: fileExtension))))
    }

    @Test(arguments: ["svg", "html", "htm", "xhtml", "xml", "json", "shortcut", "webarchive", "mht", "mhtml", "ics", "vcf", "mobileconfig", "m3u", "pls", "asx", "wax", "wvx", "wmx", "ram",
                      "docm", "xlsm", "xlsb", "pptm", "zip", "dmg", "iso", "command", "tool", "terminal", "fileloc", "inetloc", "webloc", "scpt", "applescript",
                      "jar", "pkg", "app", "exe", "bat", "cmd", "ps1", "vbs", "js", "sh", "py", "url", "lnk", "workflow", "swift", "mkv"])
    func everythingElseIsRefused(fileExtension: String) throws {
        #expect(!WindowsShortcutPolicy.isDocument(try #require(UTType(filenameExtension: fileExtension))))
    }

    @Test func explanationsCleanWhatTheFileSupplied() {
        let text = LinkBlock.network("\\\\srv\u{202E}\n\\s").explanation
        #expect(text.contains("\\\\srv\\s"))
        #expect(!text.contains("\u{202E}"))
    }
}

/// The real disk, for what a stand-in probe can't show.
@Suite struct WindowsShortcutFileTests {
    private func writeLink(_ fx: Fixture, _ path: String, relative: String) throws -> URL {
        var file = LinkFile()
        file.relative = relative
        let url = fx.url(path)
        try Data(file.bytes()).write(to: url)
        return url
    }

    private func destination(_ shortcut: URL) throws -> LinkDestination {
        guard case .link(_, let destination) = try WindowsShortcutPolicy.inspect(shortcut) else { throw WindowsShortcutError.malformed }
        return destination
    }

    @Test func readsBothKinds() throws {
        let fx = try Fixture()
        try fx.file("site.url", "[InternetShortcut]\nURL=https://example.com/\n")
        #expect(try WindowsShortcut.read(fx.url("site.url")) == .internet(InternetShortcut(rawAddress: "https://example.com/")))
        let link = try writeLink(fx, "a.lnk", relative: "b.txt")
        guard case .link(let parsed) = try WindowsShortcut.read(link) else { Issue.record("not a link"); return }
        #expect(parsed.relativePath == "b.txt")
    }

    @Test func aFIFONamedLikeAShortcutReturnsPromptly() throws {
        let fx = try Fixture()
        #expect(mkfifo(fx.url("x.lnk").path, 0o600) == 0)
        #expect(throws: WindowsShortcutError.unreadable) { try WindowsShortcut.read(fx.url("x.lnk")) }
    }

    @Test func aSymlinkNamedLikeAShortcutIsRefused() throws {
        let fx = try Fixture()
        let real = try writeLink(fx, "real.lnk", relative: "b.txt")
        try FileManager.default.createSymbolicLink(at: fx.url("x.lnk"), withDestinationURL: real)
        #expect(throws: WindowsShortcutError.unreadable) { try WindowsShortcut.read(fx.url("x.lnk")) }
    }

    @Test func oversizedFilesAreRefused() throws {
        let fx = try Fixture()
        try Data(count: (1 << 20) + 1).write(to: fx.url("big.lnk"))
        try Data(count: (64 << 10) + 1).write(to: fx.url("big.url"))
        try Data(count: 1 << 20).write(to: fx.url("limit.lnk"))
        #expect(throws: WindowsShortcutError.tooLarge) { try WindowsShortcut.read(fx.url("big.lnk")) }
        #expect(throws: WindowsShortcutError.tooLarge) { try WindowsShortcut.read(fx.url("big.url")) }
        #expect(throws: WindowsShortcutError.notAShortcut) { try WindowsShortcut.read(fx.url("limit.lnk")) }
    }

    @Test func unreadableAndEmptyFiles() throws {
        let fx = try Fixture()
        let locked = try fx.file("locked.lnk", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        if getuid() != 0 { #expect(throws: WindowsShortcutError.unreadable) { try WindowsShortcut.read(locked) } }
        try Data().write(to: fx.url("empty.lnk"))
        #expect(throws: WindowsShortcutError.notAShortcut) { try WindowsShortcut.read(fx.url("empty.lnk")) }
    }

    @Test func aDocumentBesideTheShortcutOpens() throws {
        let fx = try Fixture()
        try fx.file("a.pdf")
        let expected = fx.url("a.pdf").path
        guard case .document(let url) = try destination(try writeLink(fx, "x.lnk", relative: ".\\a.pdf")) else { Issue.record("not a document"); return }
        #expect(url.path == expected)
    }

    @Test func aLinkMidPathIsNotFollowedOnDisk() throws {
        let fx = try Fixture()
        try fx.file("outside/a.pdf")
        try fx.folder("floor")
        try FileManager.default.createSymbolicLink(at: fx.url("floor/link"), withDestinationURL: fx.url("outside"))
        let shortcut = try writeLink(fx, "floor/x.lnk", relative: "link\\a.pdf")
        #expect(try destination(shortcut) == .blocked(.notFound("link\\a.pdf")))
    }

    @Test func aFinalLinkIsNotFollowedOnDisk() throws {
        let fx = try Fixture()
        try fx.file("outside.pdf")
        try fx.folder("floor")
        try FileManager.default.createSymbolicLink(at: fx.url("floor/a.pdf"), withDestinationURL: fx.url("outside.pdf"))
        let shortcut = try writeLink(fx, "floor/x.lnk", relative: "a.pdf")
        #expect(try destination(shortcut) == .blocked(.notFound("a.pdf")))
    }

    @Test func aFIFONamedAsADocumentIsRefused() throws {
        let fx = try Fixture()
        #expect(mkfifo(fx.url("x.pdf").path, 0o600) == 0)
        let shortcut = try writeLink(fx, "s.lnk", relative: "x.pdf")
        #expect(try destination(shortcut) == .blocked(.notFound("x.pdf")))
    }

    @Test func anExtensionlessExecutableIsRevealOnly() throws {
        let fx = try Fixture()
        let tool = try fx.file("tool", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let shortcut = try writeLink(fx, "x.lnk", relative: "tool")
        guard case .revealOnly = try destination(shortcut) else { Issue.record("expected reveal only"); return }
    }

    @Test func aFolderOnDiskIsFollowed() throws {
        let fx = try Fixture()
        try fx.folder("sub")
        guard case .folder(let url) = try destination(try writeLink(fx, "x.lnk", relative: "sub")) else { Issue.record("not a folder"); return }
        #expect(url.lastPathComponent == "sub")
    }
}

@Suite struct WindowsShortcutNamingTests {
    @Test func typeNames() {
        func name(_ fileName: String, id: String? = nil, symlink: Bool = false) -> String {
            ExplorerTypeName.name(localized: "Document", typeIdentifier: id, isFolder: false, isSymbolicLink: symlink,
                                  windowsShortcut: WindowsShortcutKind(fileName: fileName))
        }
        #expect(name("a.lnk") == "Windows shortcut")
        #expect(name("A.LNK") == "Windows shortcut")
        #expect(name("a.url") == "Internet shortcut")
        #expect(name("a.txt") == "Document")
        #expect(name("a.lnk", id: ExplorerTypeName.aliasTypeIdentifier) == "Shortcut")
        #expect(name("a.url", symlink: true) == "Symbolic link")
        #expect(ExplorerTypeName.name(localized: "Alias", typeIdentifier: nil, isFolder: false, windowsShortcut: .link) == "Shortcut")
    }

    @Test func foldersAndPackagesAreNeverShortcutFiles() {
        #expect(WindowsShortcutKind(itemName: "a.lnk", isFolder: false, isPackage: false) == .link)
        #expect(WindowsShortcutKind(itemName: "a.lnk", isFolder: true, isPackage: false) == nil)
        #expect(WindowsShortcutKind(itemName: "a.url", isFolder: false, isPackage: true) == nil)
    }

    @Test func listedItemsReportTheTwoTypeNames() throws {
        let fx = try Fixture()
        try fx.file("a.lnk", "x")
        try fx.file("a.url", "x")
        try fx.folder("b.lnk")
        #expect(FileItem(url: fx.url("a.lnk"))?.typeDescription == "Windows shortcut")
        #expect(FileItem(url: fx.url("a.url"))?.typeDescription == "Internet shortcut")
        #expect(FileItem(url: fx.url("a.lnk"))?.windowsShortcutKind == .link)
        #expect(FileItem(url: fx.url("b.lnk"))?.windowsShortcutKind == nil)
    }

    @Test func typeSearchesMatchTheTypeColumn() throws {
        func candidate(_ name: String, symlink: Bool = false) -> SearchCandidate {
            SearchCandidate(name: name, folderPath: "/Users/me", isFolder: false, isSymbolicLink: symlink, typeDescription: "Document")
        }
        #expect(candidate("a.lnk").typeDescription == "Windows shortcut")
        #expect(candidate("a.url").typeDescription == "Internet shortcut")
        #expect(candidate("a.txt").typeDescription == "Document")
        #expect(candidate("a.url", symlink: true).typeDescription == "Document")
    }

    @Test func untrustedTextIsCleaned() {
        #expect(UntrustedText.display("a\u{202E}b\u{200B}c\nd\u{2028}e\u{0}") == "abcde")
        #expect(UntrustedText.display("abcdef", limit: 3) == "abc…")
        #expect(UntrustedText.display("abc", limit: 3) == "abc")
        #expect(UntrustedText.eliding("abcdefghij", limit: 5) == "ab…ij")
        #expect(UntrustedText.eliding("abcde", limit: 5) == "abcde")
    }

    @Test func detailRowsAreCleanAndHonest() {
        var link = ShellLink()
        link.localPath = "C:\\a\u{202E}.txt"
        link.arguments = "/x"
        let rows = WindowsShortcutInspection.link(link, .blocked(.hasArguments)).detailRows
        #expect(rows.first?.value == "Windows shortcut")
        #expect(rows.contains { $0.label == "Target:" && $0.value == "C:\\a.txt" })
        #expect(rows.contains { $0.label == "Arguments:" && $0.value == "/x" })
        #expect(rows.last?.value == LinkBlock.hasArguments.explanation)

        let site = WindowsShortcutInspection.internet(InternetShortcut(rawAddress: "ftp://x.example/")).detailRows
        #expect(site.contains { $0.label == "Address:" && $0.value == "ftp://x.example/" })
        #expect(site.last?.value == AddressRefusal.unsupportedScheme("ftp").explanation)
    }

    @Test func resolvedLinkMatchesLinkStaysInside() {
        #expect(ArchivePath.resolvedLink(entry: ["a", "l"], target: "../b/./c") == ["b", "c"])
        #expect(ArchivePath.linkStaysInside(entry: ["a", "l"], target: "../b/./c"))
        #expect(ArchivePath.resolvedLink(entry: ["l"], target: "..") == nil)
        #expect(!ArchivePath.linkStaysInside(entry: ["l"], target: ".."))
        #expect(ArchivePath.resolvedLink(entry: ["a", "l"], target: "..") == [])
        #expect(ArchivePath.linkStaysInside(entry: ["a", "l"], target: ".."))
    }
}
