import Foundation
import Testing
@testable import ArborCore

/// What a volume can't do is said up front, or asked about, never found out afterwards (FE-231).
@Suite("Volume capability matrix (FE-231)")
struct VolumeCapabilityMatrixTests {
    private func report(_ typeName: String, readOnly: Bool = false) -> VolumeCapabilityReport {
        VolumeCapabilityReport(format: FileSystemCapabilities(typeName: typeName, isReadOnly: readOnly))
    }

    @Test(arguments: ["apfs", "hfs", "exfat", "msdos", "ntfs", "smbfs", "afpfs", "nfs", "webdav", "unknownfs"])
    func aMissingTrashOrWriteAccessHasANote(typeName: String) {
        var noTrash = report(typeName)
        noTrash.supportsTrash = false
        #expect(noTrash.notes.contains { $0.contains("Trash") }, "\(typeName): \(noTrash.notes)")
        let readOnly = report(typeName, readOnly: true)
        #expect(readOnly.readOnlyExplanation?.isEmpty == false, "\(typeName)")
        #expect(!readOnly.notes.isEmpty, "\(typeName)")
    }

    @Test func formatLimitsAreSpelledOut() {
        #expect(report("msdos").notes.contains { $0.contains("4 GB") })
        for typeName in ["msdos", "exfat"] { #expect(report(typeName).notes.contains { $0.contains("permissions") }, "\(typeName)") }
    }

    @Test func anUnknownCapabilityReadsUnknownRatherThanNo() {
        #expect(report("unknownfs").rows.first { $0.label == "Supports the Trash:" }?.value == "Unknown")
    }

    @Test func aMetadataLossReachesTheResolverInsteadOfBeingDropped() async throws {
        let fx = try Fixture()
        let file = try fx.file("src/tagged.txt", "tagged")
        try fx.folder("dst")
        #expect(setxattr(file.path, "com.example.note", "x", 1, 0, 0) == 0)
        let job = FileTransfer(kind: .move, sources: [file], destination: fx.url("dst"), sameVolume: { _, _ in false })
        job.capabilityCheck = { _ in VolumeCapabilities(nativeExtendedAttributes: false, accessControlLists: false, formatName: "ExFAT") }
        let asked = Counter()
        job.metadataLossResolver = { _ in asked.increment(); return MetadataLossDecision(.skip) }
        let report = await job.run(resolveConflict: neverAsked)
        #expect(asked.count == 1)
        if case .skipped = report.results[0].outcome {} else { Issue.record("\(report.results[0].outcome)") }
        #expect(fx.read("src/tagged.txt") == "tagged", "skipping keeps the original")
        #expect(fx.names("dst").isEmpty)
    }

    @Test func aFailedTrashNamesTheRealCause() throws {
        let fx = try Fixture()
        let locked = try fx.file("box/locked.txt")
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        defer { chflags(locked.path, 0) }
        #expect(failure(for: locked, trash: fx.trash).reason.contains("locked"))
        #expect(!failure(for: locked, trash: fx.trash).canDeletePermanently)
        let missing = failure(for: fx.url("box/missing.txt"), trash: fx.trash)
        #expect(missing.reason == L10n.tr("The item no longer exists."))
        #expect(!missing.canDeletePermanently)

        let unknown = NSError(domain: "elsewhere", code: 1)
        #expect(SystemTrash.failure(unknown, for: fx.url("box")).reason.contains("may not support the Trash"))
        #expect(SystemTrash.failure(unknown, for: fx.url("box")).canDeletePermanently)
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
        #expect(SystemTrash.failure(readOnly, for: fx.url("box")).reason.contains("read-only"))
        #expect(!SystemTrash.failure(readOnly, for: fx.url("box")).canDeletePermanently)
    }

    @Test func aPathTooLongForTheTrashIsNotReportedAsMissing() throws {
        let fx = try Fixture()
        let onDisk = try fx.file("box/a.txt")
        // What FileManager.trashItem really answers past PATH_MAX.
        let realError = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -43)])
        let tooLong = URL(fileURLWithPath: "/" + String(repeating: "d/", count: PathLimits.maxPathBytes))
        #expect(SystemTrash.failure(realError, for: tooLong).reason == L10n.tr("The path to this item is too long for the Trash."))
        #expect(SystemTrash.failure(realError, for: tooLong).canDeletePermanently)
        #expect(SystemTrash.failure(realError, for: onDisk).reason.contains("may not support the Trash"), "it's still there")
    }

    @Test func aPermissionProblemIsNotBlamedOnTheLocation() throws {
        guard geteuid() != 0 else { return }
        let fx = try Fixture()
        let file = try fx.file("box/a.txt")
        chmod(fx.url("box").path, 0o555)
        defer { chmod(fx.url("box").path, 0o755) }
        #expect(failure(for: file, trash: fx.trash).reason.contains("permission"))
        #expect(failure(for: file, trash: fx.trash).canDeletePermanently)
    }

    private func failure(for url: URL, trash: URL) -> TrashFailure {
        do {
            try SystemTrash.trash(url, into: trash)
            return TrashFailure(reason: "trashed", canDeletePermanently: false)
        } catch {
            return SystemTrash.failure(error, for: url)
        }
    }
}
