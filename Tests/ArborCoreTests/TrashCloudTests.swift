import Foundation
import Testing
@testable import ArborCore

@Suite("Trash journal (FE-077)")
struct TrashJournalTests {
    @Test func recordsAndPersists() throws {
        let fx = try Fixture()
        let trashed = try fx.file(".fixture-trash/UUID-a.txt")
        let journalURL = fx.url("journal.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let journal = TrashJournal(fileURL: journalURL, saveDelay: 0)
        journal.record(original: fx.url("Docs/a.txt"), trashed: trashed, date: date)

        let reloaded = TrashJournal(fileURL: journalURL, saveDelay: 0)
        let record = try #require(reloaded.lookup(trashed))
        #expect(record.originalPath == fx.url("Docs/a.txt").standardizedFileURL.path)
        #expect(record.originalFolder == fx.url("Docs").standardizedFileURL.path)
        #expect(record.originalName == "a.txt")
        #expect(record.dateDeleted == date)
    }

    @Test func differentFileAtSamePathGetsNoRecord() throws {
        let fx = try Fixture()
        let trashed = try fx.file(".fixture-trash/a.txt", "first")
        let journal = TrashJournal(fileURL: fx.url("journal.json"), saveDelay: 0)
        journal.record(original: fx.url("a.txt"), trashed: trashed)
        #expect(journal.lookup(trashed) != nil)
        // Emptied elsewhere, then another item lands at the same Trash path.
        try FileManager.default.removeItem(at: trashed)
        _ = try fx.file("other.txt", "second")
        try FileManager.default.moveItem(at: fx.url("other.txt"), to: trashed)
        #expect(journal.lookup(trashed) == nil)
    }

    @Test func missingItemHasNoRecord() throws {
        let fx = try Fixture()
        let journal = TrashJournal(fileURL: fx.url("journal.json"), saveDelay: 0)
        journal.record(original: fx.url("a.txt"), trashed: fx.url(".fixture-trash/gone.txt"))
        #expect(journal.lookup(fx.url(".fixture-trash/gone.txt")) == nil)
    }

    @Test func pruneDropsOnlyVanishedItemsOfThatFolder() throws {
        let fx = try Fixture()
        let keep = try fx.file(".fixture-trash/keep.txt")
        let gone = fx.url(".fixture-trash/gone.txt")
        let elsewhere = try fx.file("OtherTrash/x.txt")
        let journal = TrashJournal(fileURL: fx.url("journal.json"), saveDelay: 0)
        journal.record(original: fx.url("keep.txt"), trashed: keep)
        journal.record(original: fx.url("gone.txt"), trashed: gone)
        journal.record(original: fx.url("x.txt"), trashed: elsewhere)
        journal.prune(folder: fx.trash, existing: [keep.path])
        let paths = Set(journal.allRecords.map(\.trashedPath))
        #expect(paths == [keep.standardizedFileURL.path, elsewhere.standardizedFileURL.path])
    }

    @Test func coalescedWritesFlush() throws {
        let fx = try Fixture()
        let trashed = try fx.file(".fixture-trash/a.txt")
        let journal = TrashJournal(fileURL: fx.url("journal.json"), saveDelay: 60)
        journal.record(original: fx.url("a.txt"), trashed: trashed)
        #expect(!fx.exists("journal.json"))
        journal.flush()
        #expect(TrashJournal(fileURL: fx.url("journal.json"), saveDelay: 0).lookup(trashed) != nil)
    }

    @Test func recordAfterMoveKeepsOriginalFolder() throws {
        let fx = try Fixture()
        let journal = TrashJournal(fileURL: fx.url("journal.json"), saveDelay: 0)
        let source = try fx.file("Projects/notes.md")
        let target = fx.trash.appendingPathComponent("notes.md")
        try FileManager.default.moveItem(at: source, to: target)
        journal.record(original: source, trashed: target)
        #expect(journal.lookup(target)?.originalFolder == fx.url("Projects").standardizedFileURL.path)
    }
}

@Suite("Trash restore planning")
struct TrashRestoreTests {
    private func record(_ trashed: URL, _ original: URL) -> TrashRecord {
        TrashRecord(trashedPath: trashed.path, originalPath: original.path, dateDeleted: Date())
    }

    @Test func freeDestinationRestoresInPlace() throws {
        let fx = try Fixture()
        _ = try fx.folder("Docs")
        let trashed = try fx.file(".fixture-trash/1-a.txt")
        let plan = TrashRestorePlanner.plan([RestoreCandidate(trashedURL: trashed, isFolder: false, record: record(trashed, fx.url("Docs/a.txt")))],
                                            exists: FileOps.exists)
        #expect(plan == [.restore(from: trashed, to: fx.url("Docs/a.txt").standardizedFileURL, missingParents: [])])
    }

    @Test func conflictOffersKeepBothName() throws {
        let fx = try Fixture()
        try fx.file("Docs/Report.pdf")
        try fx.file("Docs/Report (2).pdf")
        let trashed = try fx.file(".fixture-trash/1-Report.pdf")
        let plan = TrashRestorePlanner.plan([RestoreCandidate(trashedURL: trashed, isFolder: false, record: record(trashed, fx.url("Docs/Report.pdf")))],
                                            exists: FileOps.exists)
        guard case .conflict(_, let to, let keepBoth, let parents) = plan.first else { Issue.record("expected a conflict"); return }
        #expect(to.lastPathComponent == "Report.pdf")
        #expect(keepBoth.lastPathComponent == "Report (3).pdf")
        #expect(parents.isEmpty)
    }

    @Test func folderKeepBothKeepsDotsInName() throws {
        let fx = try Fixture()
        _ = try fx.folder("Photos.2024")
        let trashed = try fx.folder(".fixture-trash/1-Photos.2024")
        let plan = TrashRestorePlanner.plan([RestoreCandidate(trashedURL: trashed, isFolder: true, record: record(trashed, fx.url("Photos.2024")))],
                                            exists: FileOps.exists)
        guard case .conflict(_, _, let keepBoth, _) = plan.first else { Issue.record("expected a conflict"); return }
        #expect(keepBoth.lastPathComponent == "Photos.2024 (2)")
    }

    @Test func twoItemsWithTheSameOriginConflictWithEachOther() throws {
        let fx = try Fixture()
        _ = try fx.folder("Docs")
        let first = try fx.file(".fixture-trash/1-a.txt")
        let second = try fx.file(".fixture-trash/2-A.txt")
        let plan = TrashRestorePlanner.plan([
            RestoreCandidate(trashedURL: first, isFolder: false, record: record(first, fx.url("Docs/a.txt"))),
            RestoreCandidate(trashedURL: second, isFolder: false, record: record(second, fx.url("Docs/A.txt"))),
        ], exists: FileOps.exists)
        guard case .restore = plan[0], case .conflict(_, _, let keepBoth, _) = plan[1] else { Issue.record("unexpected plan \(plan)"); return }
        #expect(keepBoth.lastPathComponent == "A (2).txt")
    }

    @Test func missingParentsAreListedOutermostFirst() throws {
        let fx = try Fixture()
        let trashed = try fx.file(".fixture-trash/1-a.txt")
        let plan = TrashRestorePlanner.plan([RestoreCandidate(trashedURL: trashed, isFolder: false, record: record(trashed, fx.url("Gone/Deeper/a.txt")))],
                                            exists: FileOps.exists)
        guard case .restore(_, _, let parents) = plan.first else { Issue.record("expected a restore"); return }
        #expect(parents.map(\.lastPathComponent) == ["Gone", "Deeper"])
    }

    @Test func unknownOriginIsNotRestorable() throws {
        let fx = try Fixture()
        let trashed = try fx.file(".fixture-trash/finder.txt")
        let plan = TrashRestorePlanner.plan([RestoreCandidate(trashedURL: trashed, isFolder: false, record: nil)], exists: FileOps.exists)
        #expect(plan == [.unknownOrigin(trashed)])
    }

    @Test func restorerRecreatesParentsAndClearsJournal() throws {
        let fx = try Fixture()
        let trashed = try fx.file(".fixture-trash/1-a.txt", "content")
        let journal = TrashJournal(fileURL: fx.url("journal.json"), saveDelay: 0)
        let original = fx.url("Gone/Deeper/a.txt")
        journal.record(original: original, trashed: trashed)
        let plan = TrashRestorePlanner.plan([RestoreCandidate(trashedURL: trashed, isFolder: false, record: journal.lookup(trashed))],
                                            exists: FileOps.exists)
        guard case .restore(let from, let to, let parents) = plan[0] else { Issue.record("expected a restore"); return }
        try TrashRestorer.restore(from: from, to: to, missingParents: parents, journal: journal)
        #expect(fx.read("Gone/Deeper/a.txt") == "content")
        #expect(!FileOps.exists(trashed))
        #expect(journal.allRecords.isEmpty)
    }

    @Test func restorerNeverOverwrites() throws {
        let fx = try Fixture()
        let trashed = try fx.file(".fixture-trash/1-a.txt", "trashed")
        try fx.file("a.txt", "newer")
        #expect(throws: TrashRestoreError.destinationTaken(fx.url("a.txt").path)) {
            try TrashRestorer.restore(from: trashed, to: fx.url("a.txt"), missingParents: [], journal: nil)
        }
        #expect(fx.read("a.txt") == "newer")
        #expect(FileOps.exists(trashed))
    }
}

@Suite("Trash display names")
struct TrashNamingTests {
    @Test func originalNamesWhenUnique() {
        let names = TrashNaming.displayNames([
            .init(onDisk: "1F2E-a.txt", original: "a.txt", group: "HD"),
            .init(onDisk: "b 2.txt", original: "b.txt", group: "HD"),
            .init(onDisk: "finder.txt", original: nil, group: "HD"),
        ])
        #expect(names == ["a.txt", "b.txt", "finder.txt"])
    }

    @Test func duplicateOriginalsFallBackToTrashNames() {
        let names = TrashNaming.displayNames([
            .init(onDisk: "a.txt", original: "a.txt", group: "HD"),
            .init(onDisk: "a 2.txt", original: "a.txt", group: "HD"),
        ])
        #expect(names == ["a.txt", "a 2.txt"])
    }

    @Test func originalCollidingWithUnknownItemFallsBack() {
        let names = TrashNaming.displayNames([
            .init(onDisk: "X-a.txt", original: "a.txt", group: "HD"),
            .init(onDisk: "a.txt", original: nil, group: "HD"),
        ])
        #expect(names == ["X-a.txt", "a.txt"])
    }

    @Test func sameNameInTwoTrashesIsDisambiguated() {
        let names = TrashNaming.displayNames([
            .init(onDisk: "a.txt", original: nil, group: "Macintosh HD"),
            .init(onDisk: "a.txt", original: nil, group: "USB"),
        ])
        #expect(names == ["a.txt", "a.txt (USB)"])
    }
}

@Suite("Cloud status (FE-190)")
struct CloudStatusTests {
    @Test func notUbiquitousIsUnknown() {
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: false, download: .current)) == .unknown)
        #expect(CloudStatusMapper.status(UbiquityInfo()) == .unknown)
    }

    @Test func downloadStates() {
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .current, isUploaded: true)) == .availableOnDevice)
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .downloaded)) == .availableOnDevice)
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .notDownloaded)) == .onlineOnly)
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .other("x"))) == .unknown)
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true)) == .unknown)
    }

    @Test func transfersAndPending() {
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .notDownloaded, isDownloading: true)) == .downloading)
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .current, isUploading: true, isUploaded: false)) == .uploading)
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .current, isUploading: false, isUploaded: false)) == .syncPending)
    }

    @Test func errorsAndConflictsWin() {
        let error = UbiquityInfo(isUbiquitous: true, download: .current, isDownloading: true, uploadError: "Quota exceeded", hasConflicts: true)
        #expect(CloudStatusMapper.status(error) == .error("Quota exceeded"))
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, download: .current, isDownloading: true, hasConflicts: true)) == .conflict)
    }

    @Test func titlesUseWindowsWording() {
        #expect(CloudStatus.availableOnDevice.title == "Available on this device")
        #expect(CloudStatus.onlineOnly.title == "Available when online")
        #expect(CloudStatus.onlineOnly.isLocal == false)
        #expect(CloudStatus.unknown.isLocal == nil)
    }

    @Test func providerNames() {
        #expect(CloudRoots.providerAndAccount(forCloudStorageFolder: "OneDrive-Personal") == ("OneDrive", "Personal"))
        #expect(CloudRoots.providerAndAccount(forCloudStorageFolder: "GoogleDrive-jane@example.com") == ("Google Drive", "jane@example.com"))
        #expect(CloudRoots.providerAndAccount(forCloudStorageFolder: "Box-Box") == ("Box", nil))
        #expect(CloudRoots.providerAndAccount(forCloudStorageFolder: "Dropbox") == ("Dropbox", nil))
        #expect(CloudRoots.providerAndAccount(forCloudStorageFolder: "OneDrive-Contoso Ltd") == ("OneDrive", "Contoso Ltd"))
        #expect(CloudRoots.providerAndAccount(forCloudStorageFolder: "AcmeSync-work") == ("AcmeSync", "work"))
    }

    @Test func detectsRootsInAFixtureHome() throws {
        let fx = try Fixture()
        _ = try fx.folder("Library/Mobile Documents/com~apple~CloudDocs")
        _ = try fx.folder("Library/CloudStorage/OneDrive-Personal")
        _ = try fx.folder("Library/CloudStorage/Dropbox")
        try fx.file("Library/CloudStorage/.hidden")
        let roots = CloudRoots.detect(home: fx.root)
        #expect(roots.map(\.displayName) == ["iCloud Drive", "Dropbox", "OneDrive – Personal"])
        #expect(roots.map(\.kind) == [.iCloud, .fileProvider, .fileProvider])
        let inside = fx.url("Library/CloudStorage/OneDrive-Personal/Docs/a.txt")
        #expect(CloudRoots.root(containing: inside, in: roots)?.provider == "OneDrive")
        #expect(CloudRoots.root(containing: fx.url("Library/CloudStorage/OneDrive-PersonalX"), in: roots) == nil)
    }

    @Test func testOverrides() {
        let statuses = CloudRoots.parseTestStatuses("a.txt=online, b.txt=available,c=syncing,d=bogus,e=error")
        #expect(statuses["a.txt"] == .onlineOnly)
        #expect(statuses["b.txt"] == .availableOnDevice)
        #expect(statuses["c"] == .downloading)
        #expect(statuses["d"] == nil)
        if case .error = statuses["e"] {} else { Issue.record("expected error") }
        #expect(CloudRoots.testRoots(environment: [:]).isEmpty)
        #expect(CloudRoots.testRoots(environment: ["ARBOR_TEST_CLOUD_ROOT": "/tmp/x"]).first?.displayName == "Test Cloud")
    }
}
