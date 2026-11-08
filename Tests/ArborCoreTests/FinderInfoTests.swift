import Darwin
import Foundation
import Testing
@testable import ArborCore

@Suite("Custom Finder icon flag (DEC-performance-3)")
struct FinderInfoTests {
    @Test func flagIsReadFromTheFinderFlags() {
        var bytes = [UInt8](repeating: 0, count: 32)
        #expect(!FinderInfo.hasCustomIcon(bytes))
        bytes[8] = 0x04   // kHasCustomIcon, big-endian high byte
        #expect(FinderInfo.hasCustomIcon(bytes))
        bytes[8] = 0x40   // another flag only (kIsInvisible)
        #expect(!FinderInfo.hasCustomIcon(bytes))
        #expect(!FinderInfo.hasCustomIcon([0, 1, 2]))
    }

    @Test func flagIsReadFromAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("finderinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("plain.txt"), custom = folder.appendingPathComponent("custom.txt")
        try Data("a".utf8).write(to: plain)
        try Data("b".utf8).write(to: custom)
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04
        let status = info.withUnsafeBytes { setxattr(custom.path, FinderInfo.attributeName, $0.baseAddress, 32, 0, 0) }
        #expect(status == 0)
        #expect(FinderInfo.hasCustomIcon(atPath: custom.path))
        #expect(!FinderInfo.hasCustomIcon(atPath: plain.path))
        #expect(!FinderInfo.hasCustomIcon(atPath: folder.appendingPathComponent("missing.txt").path))
    }
}
