import Foundation
import Testing
@testable import ArborCore

@Suite("Temporary files cleanup")
struct TemporaryFilesTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func ownerPIDReadsEveryPerProcessName() {
        #expect(TemporaryFiles.ownerPID(of: "arbor-headless-123") == 123)
        #expect(TemporaryFiles.ownerPID(of: "arbor-test-journal-45") == 45)
        #expect(TemporaryFiles.ownerPID(of: "arbor-test-trash-678.arbor-journal.json") == 678)
        #expect(TemporaryFiles.ownerPID(of: "arbor-fake-network-9") == 9)
        #expect(TemporaryFiles.ownerPID(of: "arbor-headless-") == nil)
        #expect(TemporaryFiles.ownerPID(of: "arbor-tests-1234") == nil)
        #expect(TemporaryFiles.ownerPID(of: "Arbor Archives") == nil)
        #expect(TemporaryFiles.ownerPID(of: "tmp.AbCdEf1234") == nil)
    }

    @Test func removesOnlyFoldersOfProcessesThatEnded() throws {
        let dir = try makeDirectory()
        defer { TemporaryFiles.removeTree(dir) }
        let fm = FileManager.default
        for name in ["arbor-headless-111", "arbor-headless-222", "arbor-test-journal-111", "unrelated-111", "arbor-tests-x"] {
            try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("arbor-test-trash-111.arbor-journal.json"))
        let mine = "arbor-headless-\(getpid())"
        try fm.createDirectory(at: dir.appendingPathComponent(mine), withIntermediateDirectories: true)

        // 222 still runs; 111 ended; this process is never touched even if reported as ended.
        let removed = TemporaryFiles.sweepLeftovers(in: dir, isRunning: { $0 == 222 })
        #expect(Set(removed) == ["arbor-headless-111", "arbor-test-journal-111", "arbor-test-trash-111.arbor-journal.json"])
        #expect(names(dir) == ["arbor-headless-222", mine, "arbor-tests-x", "unrelated-111"].sorted())
    }

    @Test func removesLockedVersionCopiesAfterADay() throws {
        let dir = try makeDirectory()
        defer { TemporaryFiles.removeTree(dir) }
        let fm = FileManager.default
        let versions = dir.appendingPathComponent("Arbor Versions")
        let old = versions.appendingPathComponent("old"), recent = versions.appendingPathComponent("recent")
        for folder in [old, recent] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Report (version).txt")
            try Data("v1".utf8).write(to: file)
            var values = URLResourceValues()
            values.isUserImmutable = true   // copies from earlier versions were locked
            var target = file
            try target.setResourceValues(values)
        }
        let created = Date(timeIntervalSince1970: 1_000_000)
        try fm.setAttributes([.creationDate: created], ofItemAtPath: old.path)
        try fm.setAttributes([.creationDate: created.addingTimeInterval(TemporaryFiles.versionCopyLifetime)], ofItemAtPath: recent.path)

        let now = created.addingTimeInterval(TemporaryFiles.versionCopyLifetime + 60)
        let removed = TemporaryFiles.sweepLeftovers(in: dir, now: now, isRunning: { _ in true })
        #expect(removed == ["Arbor Versions/old"])
        #expect(names(versions) == ["recent"])
    }

    @Test func versionCopiesAreReadOnlyButRemovableByAPlainUnlink() throws {
        let dir = try makeDirectory()
        defer { TemporaryFiles.removeTree(dir) }
        let fm = FileManager.default
        let folder = dir.appendingPathComponent("Arbor Versions").appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("Report (version).txt")
        let package = folder.appendingPathComponent("Notes (version).rtfd")
        let inner = package.appendingPathComponent("TXT.rtf")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: file)
        try Data("v1".utf8).write(to: inner)

        try TemporaryFiles.makeVersionCopyReadOnly(file)
        try TemporaryFiles.makeVersionCopyReadOnly(package)
        for item in [file, inner] {
            #expect(try FileFlags.read(item).isLocked == false)
            #expect((try fm.attributesOfItem(atPath: item.path)[.posixPermissions] as? Int) == 0o444)
            #expect(!fm.isWritableFile(atPath: item.path))
        }
        #expect(fm.isExecutableFile(atPath: package.path))   // the package stays readable
        // What the system's temp cleanup does after a crash or force quit: a plain unlink.
        try fm.removeItem(at: folder)
        #expect(!fm.fileExists(atPath: folder.path))
    }

    @Test func removeTreeUnlocksLockedItems() throws {
        let dir = try makeDirectory()
        let file = dir.appendingPathComponent("locked.txt")
        try Data("x".utf8).write(to: file)
        var values = URLResourceValues()
        values.isUserImmutable = true
        var target = file
        try target.setResourceValues(values)
        TemporaryFiles.removeTree(dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
