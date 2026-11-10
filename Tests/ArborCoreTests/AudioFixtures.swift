import Foundation
import Testing
@testable import ArborCore

/// Hand-built ID3, FLAC and MPEG-4 bytes, and real files made with afconvert, for FE-152's audio formats.
enum AudioFixtures {
    // MARK: MP3

    static let mpegAudio = Data([0xFF, 0xFB, 0x90, 0x00]) + Data((0..<400).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    static let id3v1 = Data("TAG".utf8) + Data(repeating: 0x41, count: 125)

    static func synchsafe(_ value: Int) -> Data {
        Data([3, 2, 1, 0].map { UInt8((value >> ($0 * 7)) & 0x7F) })
    }

    static func frame(_ id: String, _ body: Data, version: UInt8 = 3, flags: [UInt8] = [0, 0]) -> Data {
        let size = version == 3 ? Data([24, 16, 8, 0].map { UInt8((body.count >> $0) & 0xFF) }) : synchsafe(body.count)
        return Data(id.utf8) + size + flags + body
    }

    static func latin1(_ id: String, _ text: String, version: UInt8 = 3) -> Data { frame(id, Data([0]) + Data(text.utf8), version: version) }

    static func utf16(_ id: String, _ text: String) -> Data {
        frame(id, Data([1, 0xFF, 0xFE]) + text.utf16.reduce(into: Data()) { $0 += [UInt8($1 & 255), UInt8($1 >> 8)] })
    }

    static func utf8(_ id: String, _ text: String) -> Data { frame(id, Data([3]) + Data(text.utf8), version: 4) }

    static let picture = frame("APIC", Data([0]) + Data("image/png\0".utf8) + [3, 0] + Data((0..<200).map { UInt8($0 & 0xFF) }))
    static let privateFrame = frame("PRIV", Data("owner\0".utf8) + [9, 8, 7, 6])
    static let unknownFrame = frame("XQZ1", Data([1, 2, 3, 4, 5]))
    static let iTunesComment = frame("COMM", Data([0]) + Data("eng".utf8) + Data("iTunNORM\0".utf8) + Data(" 0000 1111".utf8))

    static func tag(_ frames: [Data], version: UInt8 = 3, padding: Int = 64, flags: UInt8 = 0) -> Data {
        let body = frames.reduce(Data(), +) + Data(count: padding)
        return Data("ID3".utf8) + [version, 0, flags] + synchsafe(body.count) + body
    }

    static var richFrames: [Data] {
        [picture, latin1("TIT2", "Old title"), privateFrame, latin1("TPE1", "Old artist"), latin1("TALB", "Old album"), latin1("TYER", "1999"),
         latin1("TRCK", "1/9"), latin1("TCON", "Jazz"), iTunesComment, frame("COMM", Data([0]) + Data("deu".utf8) + Data("\0".utf8) + Data("Old comment".utf8)), unknownFrame]
    }

    static func mp3(_ frames: [Data]? = nil, version: UInt8 = 3, padding: Int = 64, flags: UInt8 = 0, trailer: Data = id3v1) -> Data {
        tag(frames ?? richFrames, version: version, padding: padding, flags: flags) + mpegAudio + trailer
    }

    // MARK: FLAC

    static let vendor = "reference libFLAC 1.4.3"
    static let flacFrames = Data([0xFF, 0xF8, 0x59, 0x18]) + Data((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 11) })

    static func block(_ type: UInt8, _ body: Data, last: Bool = false) -> Data {
        Data([type | (last ? 0x80 : 0), UInt8(body.count >> 16 & 255), UInt8(body.count >> 8 & 255), UInt8(body.count & 255)]) + body
    }

    static func le32(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }

    static func comments(_ list: [String], vendor: String = vendor) -> Data {
        list.reduce(le32(vendor.utf8.count) + Data(vendor.utf8) + le32(list.count)) { $0 + le32($1.utf8.count) + Data($1.utf8) }
    }

    static let streamInfo = block(0, Data(repeating: 0x22, count: 34))
    static let otherBlocks = block(1, Data(count: 32)) + block(6, Data("PICTURE-BYTES".utf8))
    static let plainComments = ["TITLE=Old title", "ARTIST=Old artist", "ALBUM=Old album", "DATE=1999", "TRACKNUMBER=1", "GENRE=Jazz", "COMMENT=Old comment",
                                "REPLAYGAIN_TRACK_GAIN=-1.20 dB", "CUSTOM=keep me"]

    static func flac(_ list: [String] = plainComments, vendor: String = vendor) -> Data {
        Data("fLaC".utf8) + streamInfo + block(4, comments(list, vendor: vendor)) + otherBlocks + block(1, Data(count: 8), last: true) + flacFrames
    }

    // MARK: MPEG-4

    static func type(_ name: String) -> Data { Data(name.unicodeScalars.map { UInt8($0.value) }) }
    static func be32(_ value: Int) -> Data { Data([24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }) }
    static func atom(_ name: String, _ body: Data) -> Data { be32(body.count + 8) + type(name) + body }
    static func handler(_ kind: String) -> Data { Data(count: 8) + type(kind) + Data(count: 12) }
    static func textItem(_ name: String, _ text: String) -> Data { atom(name, atom("data", be32(1) + be32(0) + Data(text.utf8))) }

    static let ftyp = atom("ftyp", type("M4A ") + be32(0) + type("M4A ") + type("mp42"))
    static let media = atom("mdat", Data((0..<500).map { UInt8(truncatingIfNeeded: $0 &* 13) }))
    static let customItem = atom("----", atom("mean", Data(count: 4) + Data("com.apple.iTunes".utf8)) + atom("name", Data(count: 4) + Data("iTunSMPB".utf8))
                                 + atom("data", be32(1) + be32(0) + Data(" 00000000".utf8)))
    static let coverItem = atom("covr", atom("data", be32(14) + be32(0) + Data(repeating: 0x7E, count: 300)))
    static let unknownItem = atom("zzzz", atom("data", be32(1) + be32(0) + Data("kept".utf8)))
    static var richItems: [Data] {
        [textItem("\u{A9}nam", "Old title"), customItem, textItem("\u{A9}ART", "Old artist"), textItem("\u{A9}alb", "Old album"), textItem("\u{A9}day", "1999"),
         atom("trkn", atom("data", be32(0) + be32(0) + Data([0, 0, 0, 1, 0, 9, 0, 0]))), textItem("\u{A9}gen", "Jazz"), coverItem, textItem("\u{A9}cmt", "Old comment"), unknownItem]
    }

    static func moov(items: [Data] = richItems, metaFree: Int = 0, handler kind: String = "soun") -> Data {
        var meta = Data(count: 4) + atom("hdlr", handler("mdir")) + atom("ilst", items.reduce(Data(), +))
        if metaFree > 0 { meta += atom("free", Data(count: metaFree - 8)) }
        let track = atom("trak", atom("tkhd", Data(count: 16)) + atom("mdia", atom("hdlr", handler(kind))))
        return atom("moov", atom("mvhd", Data(repeating: 0x33, count: 32)) + track + atom("udta", atom("meta", meta) + atom("chpl", Data([1, 2, 3]))) + atom("wxyz", Data([4, 5])))
    }

    /// The layout streaming-unfriendly encoders leave: index last, so it may grow.
    static func m4aIndexLast(items: [Data] = richItems) -> Data { ftyp + media + moov(items: items) }

    /// The layout most players want: index first, with `free` bytes between it and the audio.
    static func m4aIndexFirst(items: [Data] = richItems, topFree: Int = 512, metaFree: Int = 0) -> Data {
        ftyp + moov(items: items, metaFree: metaFree) + (topFree > 0 ? atom("free", Data(count: topFree - 8)) : Data()) + media
    }

    // MARK: Real audio

    static func wav(seconds: Double = 0.5, tone: Double = 20) -> Data {
        let frames = Int(44_100 * seconds)
        var samples = Data(capacity: frames * 4)
        for index in 0..<frames {
            let left = Int16(9000 * sin(Double(index) / tone)), right = Int16(7000 * sin(Double(index) / (tone * 1.5)))
            samples += withUnsafeBytes(of: left.littleEndian) { Data($0) } + withUnsafeBytes(of: right.littleEndian) { Data($0) }
        }
        var header = Data("RIFF".utf8) + le32(36 + samples.count) + Data("WAVEfmt ".utf8) + le32(16)
        header += [1, 0, 2, 0] + le32(44_100) + le32(176_400) + [4, 0, 16, 0] + Data("data".utf8) + le32(samples.count)
        return header + samples
    }

    /// `afconvert -f <file type> -d <data format>` on a generated tone.
    static func real(_ fileType: String, _ dataFormat: String, name: String, in fixture: Fixture) throws -> URL {
        let wavURL = fixture.url("source-\(UUID().uuidString).wav")
        try wav().write(to: wavURL)
        let out = fixture.url(name)
        try run(["-f", fileType, "-d", dataFormat, wavURL.path, out.path])
        return out
    }

    /// Decodes to PCM, so "the sound is the same" is asked of the system's own decoder.
    static func decoded(_ url: URL, in fixture: Fixture) throws -> Data {
        let out = fixture.url("decoded-\(UUID().uuidString).caf")
        try run(["-f", "caff", "-d", "LEI16", url.path, out.path])
        return try Data(contentsOf: out)
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    static func dispose(into fixture: Fixture) -> EmbeddedMetadataEditor.Disposer {
        { staged, _ in
            let target = fixture.trash.appendingPathComponent(UUID().uuidString + "-" + staged.lastPathComponent)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
    }
}
