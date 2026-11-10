import Foundation

struct PDFObjectID: Hashable {
    let number: Int
    let generation: Int
}

enum PDFValue: Equatable {
    case null, bool(Bool), integer(Int64), real, name(String), string(Data), array([PDFValue]), dictionary(PDFDictionary), reference(PDFObjectID)
}

/// Keeps each entry's original bytes, so what an edit doesn't touch is written back exactly.
struct PDFDictionary: Equatable {
    struct Entry: Equatable {
        let key: String
        let rawKey: Data
        let value: PDFValue
        let rawValue: Data
    }

    var entries: [Entry] = []

    subscript(key: String) -> PDFValue? { entries.first { $0.key == key }?.value }
}

/// Reads PDF syntax from a bounded window of bytes: every length and nesting level is checked, and running out of window is reported, never guessed at.
struct PDFLexer {
    enum Failure: Error { case malformed, windowTooShort }

    private let bytes: [UInt8]
    private(set) var position = 0
    private static let maxDepth = 32

    init(_ data: Data) { bytes = [UInt8](data) }

    /// Shares `bytes` and starts at `position`, for reading one object out of a larger buffer.
    init(_ bytes: [UInt8], from position: Int) {
        self.bytes = bytes
        self.position = position
    }

    /// "N G obj", which must start exactly here: an offset that lands anywhere else is wrong.
    mutating func objectHeader() throws -> PDFObjectID {
        guard let number = try wholeNumber(), let generation = try wholeNumber(), try consume("obj"), let id = Self.id(number, generation) else { throw Failure.malformed }
        return id
    }

    /// Digits, then the space after them.
    private mutating func wholeNumber() throws -> Int64? {
        let start = position
        while position < bytes.count, Self.isDigit(bytes[position]) { position += 1 }
        guard position > start else { return nil }
        guard position < bytes.count else { throw Failure.windowTooShort }
        let number = Self.integer(bytes[start..<position])
        skipSpace()
        return number
    }

    private static func id(_ number: Int64, _ generation: Int64) -> PDFObjectID? {
        guard let number = Int(exactly: number), number < 1 << 31, let generation = Int(exactly: generation), generation <= 65535 else { return nil }
        return PDFObjectID(number: number, generation: generation)
    }

    mutating func skipSpace() {
        while position < bytes.count {
            let byte = bytes[position]
            if Self.isSpace(byte) {
                position += 1
            } else if byte == UInt8(ascii: "%") {
                while position < bytes.count, bytes[position] != 10, bytes[position] != 13 { position += 1 }
            } else {
                return
            }
        }
    }

    /// True and past it when `text` is next.
    mutating func consume(_ text: String) throws -> Bool {
        let wanted = Array(text.utf8)
        let available = min(wanted.count, bytes.count - position)
        guard available >= 0, Array(bytes[position..<(position + available)]) == Array(wanted[..<available]) else { return false }
        guard available == wanted.count else { throw Failure.windowTooShort }
        position += wanted.count
        return true
    }

    /// Stream data starts after CRLF or LF; a lone CR is ambiguous, so it counts as damage.
    mutating func consumeStreamLineEnd() throws -> Bool {
        if try consume("\r\n") { return true }
        return try consume("\n")
    }

    mutating func value() throws -> PDFValue { try value(depth: 0) }

    private mutating func value(depth: Int) throws -> PDFValue {
        guard depth < Self.maxDepth else { throw Failure.malformed }
        skipSpace()
        guard position < bytes.count else { throw Failure.windowTooShort }
        switch bytes[position] {
        case UInt8(ascii: "/"): return .name(try name())
        case UInt8(ascii: "("): return .string(try literalString())
        case UInt8(ascii: "["): return .array(try array(depth: depth))
        case UInt8(ascii: "<"):
            guard position + 1 < bytes.count else { throw Failure.windowTooShort }
            return bytes[position + 1] == UInt8(ascii: "<") ? .dictionary(try dictionary(depth: depth)) : .string(try hexString())
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."): return try number()
        default: return try keyword()
        }
    }

    /// Bytes up to the next space or delimiter; the window ending first means the token may go on.
    private mutating func regularToken() throws -> ArraySlice<UInt8> {
        let start = position
        while position < bytes.count, !Self.isSpace(bytes[position]), !Self.isDelimiter(bytes[position]) { position += 1 }
        guard position < bytes.count else { throw Failure.windowTooShort }
        return bytes[start..<position]
    }

    private mutating func number() throws -> PDFValue {
        let token = try regularToken()
        guard token.allSatisfy({ Self.isDigit($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") }) else { throw Failure.malformed }
        guard !token.contains(UInt8(ascii: ".")), let whole = Self.integer(token) else { return .real }
        if whole >= 0, let id = referenceTail(whole) { return .reference(id) }
        return .integer(whole)
    }

    /// Only an unmistakable "G R" makes a reference; otherwise the position is left alone.
    private mutating func referenceTail(_ number: Int64) -> PDFObjectID? {
        let saved = position
        skipSpace()
        let start = position
        while position < bytes.count, Self.isDigit(bytes[position]) { position += 1 }
        let digits = bytes[start..<position]
        skipSpace()
        guard !digits.isEmpty, position < bytes.count, bytes[position] == UInt8(ascii: "R"), position + 1 < bytes.count,
              Self.isSpace(bytes[position + 1]) || Self.isDelimiter(bytes[position + 1]),
              let generation = Self.integer(digits), let id = Self.id(number, generation) else {
            position = saved
            return nil
        }
        position += 1
        return id
    }

    private static func integer(_ token: ArraySlice<UInt8>) -> Int64? {
        var digits = token[...]
        var negative = false
        if let sign = digits.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            negative = sign == UInt8(ascii: "-")
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return nil }
        var value: Int64 = 0
        for digit in digits {
            guard isDigit(digit) else { return nil }
            let (scaled, overflowed) = value.multipliedReportingOverflow(by: 10)
            let (next, carried) = scaled.addingReportingOverflow(Int64(digit - 48))
            guard !overflowed, !carried else { return nil }
            value = next
        }
        return negative ? -value : value
    }

    private mutating func keyword() throws -> PDFValue {
        switch String(decoding: try regularToken(), as: UTF8.self) {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: throw Failure.malformed
        }
    }

    private mutating func name() throws -> String {
        position += 1
        var out: [UInt8] = []
        let token = Array(try regularToken())
        var index = 0
        while index < token.count {
            if token[index] == UInt8(ascii: "#") {
                guard index + 2 < token.count, let high = Self.nibble(token[index + 1]), let low = Self.nibble(token[index + 2]) else { throw Failure.malformed }
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(token[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func array(depth: Int) throws -> [PDFValue] {
        position += 1
        var items: [PDFValue] = []
        while true {
            skipSpace()
            guard position < bytes.count else { throw Failure.windowTooShort }
            if bytes[position] == UInt8(ascii: "]") {
                position += 1
                return items
            }
            items.append(try value(depth: depth + 1))
        }
    }

    private mutating func dictionary(depth: Int) throws -> PDFDictionary {
        position += 2
        var result = PDFDictionary()
        var keys = Set<String>()
        while true {
            skipSpace()
            guard position + 1 < bytes.count else { throw Failure.windowTooShort }
            if bytes[position] == UInt8(ascii: ">"), bytes[position + 1] == UInt8(ascii: ">") {
                position += 2
                return result
            }
            guard bytes[position] == UInt8(ascii: "/") else { throw Failure.malformed }
            let keyStart = position
            let key = try name()
            let rawKey = Data(bytes[keyStart..<position])
            skipSpace()
            let valueStart = position
            let item = try value(depth: depth + 1)
            // Readers disagree on which of two equal keys wins, so such a dictionary can't be understood.
            guard keys.insert(key).inserted else { throw Failure.malformed }
            result.entries.append(.init(key: key, rawKey: rawKey, value: item, rawValue: Data(bytes[valueStart..<position])))
        }
    }

    private mutating func literalString() throws -> Data {
        position += 1
        var out = Data()
        var depth = 1
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            switch byte {
            case UInt8(ascii: "("):
                depth += 1
                out.append(byte)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return out }
                out.append(byte)
            case UInt8(ascii: "\\"):
                try escape(into: &out)
            case 13:
                if position < bytes.count, bytes[position] == 10 { position += 1 }
                out.append(10)
            default:
                out.append(byte)
            }
        }
        throw Failure.windowTooShort
    }

    private mutating func escape(into out: inout Data) throws {
        guard position < bytes.count else { throw Failure.windowTooShort }
        let byte = bytes[position]
        position += 1
        switch byte {
        case UInt8(ascii: "n"): out.append(10)
        case UInt8(ascii: "r"): out.append(13)
        case UInt8(ascii: "t"): out.append(9)
        case UInt8(ascii: "b"): out.append(8)
        case UInt8(ascii: "f"): out.append(12)
        case 13:
            if position < bytes.count, bytes[position] == 10 { position += 1 }
        case 10:
            break
        case UInt8(ascii: "0")...UInt8(ascii: "7"):
            var value = Int(byte - 48), count = 1
            while count < 3, position < bytes.count, (48...55).contains(bytes[position]) {
                value = value * 8 + Int(bytes[position] - 48)
                position += 1
                count += 1
            }
            out.append(UInt8(truncatingIfNeeded: value))
        default:
            out.append(byte)
        }
    }

    private mutating func hexString() throws -> Data {
        position += 1
        var out = Data()
        var high: UInt8?
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == UInt8(ascii: ">") {
                if let high { out.append(high << 4) }
                return out
            }
            if Self.isSpace(byte) { continue }
            guard let digit = Self.nibble(byte) else { throw Failure.malformed }
            if let first = high {
                out.append(first << 4 | digit)
                high = nil
            } else {
                high = digit
            }
        }
        throw Failure.windowTooShort
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 10 || byte == 13 || byte == 9 || byte == 12 || byte == 0 }

    private static func isDelimiter(_ byte: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(byte) }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

/// PDF text strings: UTF-16 or UTF-8 with a byte order mark, else PDFDocEncoding, read strictly.
enum PDFText {
    /// nil when the bytes aren't valid text.
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFE, 0xFF]) { return utf16BE(bytes.dropFirst(2)) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(bytes: bytes.dropFirst(3), encoding: .utf8) }
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            guard let scalar = docEncoding(byte) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func utf16BE(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        let raw = Array(bytes)
        let units = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]) }
        var decoder = UTF16()
        var iterator = units.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    private static func docEncoding(_ byte: UInt8) -> Unicode.Scalar? {
        switch byte {
        case 0x18...0x1F: return Unicode.Scalar(high1[Int(byte) - 0x18])
        case 0x80...0xA0: return high2[Int(byte) - 0x80].flatMap { Unicode.Scalar($0) }
        case 0x7F, 0xAD: return nil
        default: return Unicode.Scalar(byte)
        }
    }

    private static let high1: [UInt16] = [0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC]
    private static let high2: [UInt16?] = [
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044, 0x2039, 0x203A, 0x2212, 0x2030, 0x201E, 0x201C, 0x201D, 0x2018,
        0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141, 0x0152, 0x0160, 0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, nil, 0x20AC,
    ]

    /// A PDF string literal: plain ASCII stays readable, anything else is UTF-16 in hex.
    static func encoded(_ text: String) -> Data {
        if text.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) || $0 == "\n" || $0 == "\t" }) {
            var out = Data("(".utf8)
            for byte in text.utf8 {
                switch byte {
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"): out.append(contentsOf: [UInt8(ascii: "\\"), byte])
                case 10: out.append(contentsOf: Array("\\n".utf8))
                case 9: out.append(contentsOf: Array("\\t".utf8))
                default: out.append(byte)
                }
            }
            out.append(UInt8(ascii: ")"))
            return out
        }
        var hex = "<FEFF"
        for unit in text.utf16 { hex += String(format: "%04X", unit) }
        return Data((hex + ">").utf8)
    }
}
