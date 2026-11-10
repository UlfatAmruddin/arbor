import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
@testable import ArborCore

/// Clears the Locked flag inside a fixture so it can be deleted.
private func unlockAll(_ root: URL) {
    let fm = FileManager.default
    _ = try? FileFlags.update(root, locked: false)
    for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator() {
        _ = try? FileFlags.update(url, locked: false)
    }
}

@Suite struct PropertyFormatTests {
    @Test func adaptiveSizesFollowExplorer() {
        #expect(PropertyFormat.adaptiveSize(0) == "0 bytes")
        #expect(PropertyFormat.adaptiveSize(512) == "512 bytes")
        #expect(PropertyFormat.adaptiveSize(999) == "999 bytes")
        #expect(PropertyFormat.adaptiveSize(1000) == "0.97 KB")
        #expect(PropertyFormat.adaptiveSize(1264) == "1.23 KB")
        #expect(PropertyFormat.adaptiveSize(4096) == "4.00 KB")
        #expect(PropertyFormat.adaptiveSize(14_900_000) == "14.2 MB")
        // Never four integer digits: 1015 KB becomes 0.99 MB.
        #expect(PropertyFormat.adaptiveSize(1_040_000) == "0.99 MB")
        // Truncated, not rounded: 1.999 KB stays 1.99 KB.
        #expect(PropertyFormat.adaptiveSize(2047) == "1.99 KB")
        #expect(PropertyFormat.adaptiveSize(500 * 1024 * 1024 * 1024) == "500 GB")
    }

    @Test func propertiesSizeAppendsExactBytes() {
        #expect(PropertyFormat.propertiesSize(1264) == "1.23 KB (1,264 bytes)")
        #expect(PropertyFormat.propertiesSize(12) == "12 bytes")
    }

    @Test func countsAndDurations() {
        #expect(PropertyFormat.filesAndFolders(files: 1, folders: 0) == "1 File, 0 Folders")
        #expect(PropertyFormat.filesAndFolders(files: 1200, folders: 1) == "1,200 Files, 1 Folder")
        #expect(PropertyFormat.duration(205) == "00:03:25")
        #expect(PropertyFormat.duration(3725.4) == "01:02:05")
    }

    @Test func longDateHasWeekdayAndSeconds() {
        let date = Date(timeIntervalSince1970: 1_794_046_893)   // 2026-11-07 10:21:33 UTC
        let text = PropertyFormat.longDate(date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.hasPrefix("Saturday, November 7, 2026, "))
        #expect(text.contains("10:21:33"))
    }

    @Test func dateRanges() {
        let utc = TimeZone(identifier: "UTC")!
        let en = Locale(identifier: "en_US")
        let a = Date(timeIntervalSince1970: 0), b = Date(timeIntervalSince1970: 86_400 * 3)
        #expect(PropertyFormat.dateRange([], locale: en, timeZone: utc) == nil)
        #expect(PropertyFormat.dateRange([a, a], locale: en, timeZone: utc)?.contains(" - ") == false)
        #expect(PropertyFormat.dateRange([b, a], locale: en, timeZone: utc)?.hasPrefix("1/1/70") == true)
    }
}

@Suite struct SelectionSummaryTests {
    @Test func mixedSelection() {
        let s = SelectionSummary([
            .init(isFolder: false, typeDescription: "Text Document", parentPath: "/a", size: 10),
            .init(isFolder: false, typeDescription: "PNG image", parentPath: "/a", size: 20),
            .init(isFolder: true, typeDescription: "Folder", parentPath: "/a"),
        ])
        #expect(s.countText == "2 Files, 1 Folder")
        #expect(s.typeText == "Multiple types")
        #expect(s.locationText == "All in /a")
        #expect(s.knownFileSize == 30)
        #expect(!s.sizeIsComplete)
        #expect(s.selectedText == "3 items selected")
    }

    @Test func uniformSelection() {
        let s = SelectionSummary([
            .init(isFolder: false, typeDescription: "Text Document", parentPath: "/a", size: 1),
            .init(isFolder: false, typeDescription: "Text Document", parentPath: "/b", size: 2),
        ])
        #expect(s.typeText == "All of type Text Document")
        #expect(s.locationText == "Multiple locations")
        #expect(s.sizeIsComplete)
    }

    @Test func triStateAndMixedValues() {
        #expect(TriState([true, true]) == .on)
        #expect(TriState([false]) == .off)
        #expect(TriState([true, false]) == .mixed)
        #expect(TriState([]) == .off)
        #expect(MixedValue([1, 1]).value == 1)
        #expect(MixedValue([1, 2]) == .mixed)
        #expect(MixedValue<Int>([]) == .none)
    }
}

@Suite struct PermissionTests {
    @Test func symbolicAndOctal() {
        #expect(PosixPermissions(mode: 0o644).symbolic == "rw-r--r--")
        #expect(PosixPermissions(mode: 0o755).octal == "0755")
        #expect(PosixPermissions(mode: 0o4755).symbolic == "rwsr-xr-x")
        #expect(PosixPermissions(mode: 0o1777).symbolic == "rwxrwxrwt")
        #expect(PosixPermissions(mode: 0o1776).symbolic == "rwxrwxrwT")
    }

    @Test func rolesReadAndWrite() {
        var p = PosixPermissions(mode: 0o640)
        #expect(p[.owner] == PermissionBits(read: true, write: true, execute: false))
        #expect(p[.group] == PermissionBits(read: true, write: false, execute: false))
        #expect(p[.everyone] == PermissionBits(read: false, write: false, execute: false))
        p[.everyone] = PermissionBits(read: true, write: false, execute: true)
        #expect(p.mode == 0o645)
        p[.owner].execute = true
        #expect(p.octal == "0745")
    }

    @Test func finderStyleSummaries() {
        #expect(PermissionBits(read: true, write: true, execute: false).summary(isFolder: false) == "Read & Write")
        #expect(PermissionBits(read: true, write: false, execute: true).summary(isFolder: false) == "Read only, Execute")
        #expect(PermissionBits(read: false, write: true, execute: true).summary(isFolder: true) == "Write only (Drop Box)")
        #expect(PermissionBits(read: false, write: false, execute: false).summary(isFolder: true) == "No Access")
        #expect(PermissionBits(read: true, write: false, execute: false).summary(isFolder: true) == "Read only (can't open)")
    }

    @Test func parsesACLText() {
        let text = """
        !#acl 1
        group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete
        user:11111111-2222-3333-4444-555555555555:ana:501:allow,file_inherit,directory_inherit:read,write,append
        bogus line
        """
        let entries = ACLEntry.parse(text)
        #expect(entries.count == 2)
        #expect(entries[0] == ACLEntry(kind: .group, name: "everyone", allow: false, permissions: ["delete"]))
        #expect(entries[1].name == "ana")
        #expect(entries[1].allow)
        #expect(entries[1].flags == ["file_inherit", "directory_inherit"])
        #expect(entries[1].permissionSummary.hasPrefix("Read data / List folder, Write data"))
    }

    @Test func readsRealACLAndOwnership() throws {
        let fx = try Fixture()
        let file = try fx.file("acl.txt")
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone deny delete", file.path]
        try chmod.run()
        chmod.waitUntilExit()
        defer {
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clear.arguments = ["-N", file.path]
            try? clear.run()
            clear.waitUntilExit()
        }
        let security = try ItemSecurity.read(file)
        #expect(security.acl.contains { $0.name == "everyone" && !$0.allow && $0.permissions == ["delete"] })
        #expect(security.ownerID == getuid())
        #expect(security.currentUserCanChangePermissions)
        #expect(security.access.read && security.access.write)
    }

    @Test func effectiveAccessIsTestedNotInferred() throws {
        let fx = try Fixture()
        let file = try fx.file("ro.txt")
        try ItemSecurity.setPermissions(PosixPermissions(mode: 0o444), on: file)
        var access = EffectiveAccess.test(file)
        #expect(access.read && !access.write)
        try ItemSecurity.setPermissions(PosixPermissions(mode: 0o644), on: file)
        // The mode allows writing, but the Locked flag still blocks it; access(2) reports that.
        try FileFlags.update(file, locked: true)
        defer { unlockAll(fx.root) }
        access = EffectiveAccess.test(file)
        #expect(access.read)
        #expect(!access.write)
    }
}

@Suite struct FlagTests {
    @Test func flagMathPreservesOtherBits() {
        let f = FileFlags(raw: 0x40)   // some other flag
        let locked = f.with(locked: true, hidden: nil)
        #expect(locked.isLocked && !locked.isHidden && locked.raw & 0x40 != 0)
        let both = locked.with(hidden: true)
        #expect(both.isHidden && both.isLocked)
        #expect(both.with(locked: false).raw == 0x40 | FileFlags.hiddenBit)
    }

    @Test func lockAndHideRealFile() throws {
        let fx = try Fixture()
        let file = try fx.file("f.txt")
        defer { unlockAll(fx.root) }
        #expect(try FileFlags.update(file, locked: true, hidden: true))
        #expect(try FileFlags.read(file).isLocked)
        #expect(try file.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        #expect(throws: (any Error).self) { try "changed".write(to: file, atomically: false, encoding: .utf8) }
        #expect(try FileFlags.update(file, locked: false) == true)
        #expect(try FileFlags.update(file, locked: false) == false)
    }
}

@Suite struct SizeScannerTests {
    @Test func countsRecursivelyAndAllocatesBlocks() throws {
        let fx = try Fixture()
        try fx.file("top/a.txt", String(repeating: "a", count: 1000))
        try fx.file("top/sub/b.txt", String(repeating: "b", count: 10))
        try fx.folder("top/sub/empty")
        try FileManager.default.createSymbolicLink(at: fx.url("top/link"), withDestinationURL: fx.url("top/sub"))
        let totals = SizeScanner.scan([fx.url("top")], cancel: ScanCancellation())
        #expect(totals.files == 3)          // a.txt, b.txt and the link itself (not followed)
        #expect(totals.folders == 2)        // sub, sub/empty
        #expect(totals.size >= 1010)
        #expect(totals.sizeOnDisk >= totals.size - 100)
        #expect(totals.sizeOnDisk % 512 == 0)
    }

    @Test func singleFileSizes() throws {
        let fx = try Fixture()
        let file = try fx.file("one.txt", "hello")
        let totals = SizeScanner.scan([file], cancel: ScanCancellation())
        #expect(totals.size == 5)
        #expect(totals.sizeOnDisk >= 5)
        #expect(totals.files == 0 && totals.folders == 0)
    }

    @Test func cancelStopsEarly() throws {
        let fx = try Fixture()
        for i in 0..<50 { try fx.file("many/\(i).txt") }
        let cancel = ScanCancellation()
        cancel.cancel()
        #expect(SizeScanner.scan([fx.url("many")], cancel: cancel).files == 0)
    }

    @Test func progressIsReported() throws {
        let fx = try Fixture()
        for i in 0..<200 { try fx.file("p/\(i).txt") }
        let counter = Counter()
        _ = SizeScanner.scan([fx.url("p")], cancel: ScanCancellation(), interval: 0) { _ in counter.increment() }
        #expect(counter.count > 0)
    }
}

@Suite struct FinderMetadataTests {
    @Test func parsesTagText() {
        #expect(FinderMetadata.parseTags(" Red; Work, work ;; Taxes 2026 ") == ["Red", "Work", "Taxes 2026"])
        #expect(FinderMetadata.tagText(["A", "B"]) == "A; B")
    }

    @Test func tagsAndCommentsRoundTripWithoutTouchingContent() throws {
        let fx = try Fixture()
        let file = try fx.file("doc.txt", "content")
        try FinderMetadata.setTags(["Work", "Blue"], on: file)
        #expect(Set(FinderMetadata.tags(of: file)) == ["Work", "Blue"])
        try FinderMetadata.setComment("Quarterly numbers", on: file)
        #expect(FinderMetadata.comment(of: file) == "Quarterly numbers")
        #expect(fx.read("doc.txt") == "content")
        try FinderMetadata.setComment("", on: file)
        #expect(FinderMetadata.comment(of: file) == "")
        try FinderMetadata.setTags([], on: file)
        #expect(FinderMetadata.tags(of: file).isEmpty)
    }
}

@Suite struct PropertyEditTests {
    @Test func appliesOnlyChangedFieldsInSafeOrder() throws {
        let fx = try Fixture()
        let file = try fx.file("old.txt", "x")
        defer { unlockAll(fx.root) }
        let original = try EditableState.read(file)
        var edited = original
        edited.name = "new.txt"
        edited.locked = true
        edited.hidden = true
        edited.tags = ["Work"]
        let plan = PropertyChangePlan(url: file, original: original, edited: edited)
        #expect(Set(plan.changedFields) == [.name, .locked, .hidden, .tags])
        let result = try plan.apply()
        #expect(result.lastPathComponent == "new.txt")
        let now = try EditableState.read(result)
        #expect(now.locked && now.hidden && now.tags == ["Work"])
    }

    @Test func editsALockedItemAndRelocksIt() throws {
        let fx = try Fixture()
        let file = try fx.file("locked.txt")
        defer { unlockAll(fx.root) }
        try FileFlags.update(file, locked: true)
        let original = try EditableState.read(file)
        var edited = original
        edited.comment = "note"
        edited.name = "renamed.txt"
        let url = try PropertyChangePlan(url: file, original: original, edited: edited).apply()
        let now = try EditableState.read(url)
        #expect(now.locked)
        #expect(now.comment == "note")
        #expect(url.lastPathComponent == "renamed.txt")
    }

    @Test func detectsExternalChanges() throws {
        let original = EditableState(name: "a.txt", locked: false, hidden: false, mode: 0o644)
        var edited = original
        edited.hidden = true
        edited.name = "b.txt"
        let plan = PropertyChangePlan(url: URL(fileURLWithPath: "/tmp/a.txt"), original: original, edited: edited)
        var current = original
        current.locked = true          // changed elsewhere, but not edited here: no conflict
        #expect(plan.conflicts(with: current).isEmpty)
        current.hidden = true          // changed elsewhere to the same value the user chose: no conflict
        #expect(plan.conflicts(with: current).isEmpty)
        current.name = "c.txt"         // edited here AND changed elsewhere to something else: conflict
        #expect(plan.conflicts(with: current) == [.name])
    }

    @Test func failedRenameKeepsItemLocked() throws {
        let fx = try Fixture()
        let file = try fx.file("a.txt")
        try fx.file("b.txt")
        defer { unlockAll(fx.root) }
        try FileFlags.update(file, locked: true)
        let original = try EditableState.read(file)
        var edited = original
        edited.name = "b.txt"   // taken: rename must fail without overwriting
        #expect(throws: PropertyApplyError.self) { try PropertyChangePlan(url: file, original: original, edited: edited).apply() }
        #expect(try FileFlags.read(file).isLocked)
        #expect(fx.read("b.txt") == "x")
    }
}

@Suite struct FolderTemplateTests {
    @Test func inheritsOnlyWhenAppliedToSubfolders() throws {
        let suite = "arbor-tests-templates-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FolderTemplateStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/photos")
        store.set(.init(template: .pictures, appliesToSubfolders: false), for: root)
        #expect(store.effectiveTemplate(for: root) == .pictures)
        #expect(store.effectiveTemplate(for: root.appendingPathComponent("2026")) == nil)
        store.set(.init(template: .pictures, appliesToSubfolders: true), for: URL(fileURLWithPath: "/tmp/photos/"))
        #expect(store.effectiveTemplate(for: root.appendingPathComponent("2026/trip")) == .pictures)
        store.set(.init(template: .music, appliesToSubfolders: false), for: root.appendingPathComponent("2026"))
        #expect(store.effectiveTemplate(for: root.appendingPathComponent("2026")) == .music)
        store.set(nil, for: root)
        #expect(store.choice(for: root) == nil)
        #expect(defaults.dictionary(forKey: FolderTemplateStore.key)?.keys.contains("/tmp/photos/2026") == true)
    }
}

@Suite struct PropertiesMetadataTests {
    @Test func formatsValuesLikeExplorer() {
        #expect(SpotlightMetadata.format(NSNumber(value: 2.8), .fStop) == "f/2.8")
        #expect(SpotlightMetadata.format(NSNumber(value: 0.008), .exposure) == "1/125 sec.")
        #expect(SpotlightMetadata.format(NSNumber(value: 256), .bitRate) == "256kbps")
        #expect(SpotlightMetadata.format(NSNumber(value: 320_000), .bitRate) == "320kbps")
        #expect(SpotlightMetadata.format(NSNumber(value: 44_100), .hertz) == "44.1 kHz")
        #expect(SpotlightMetadata.format(NSNumber(value: 4), .rating) == "★★★★☆")
        #expect(SpotlightMetadata.format(["Ana", "Lee"], .list) == "Ana; Lee")
        #expect(SpotlightMetadata.format(NSNumber(value: 205), .duration) == "00:03:25")
        #expect(SpotlightMetadata.format(NSNumber(value: 100), .iso) == "ISO-100")
        #expect(SpotlightMetadata.format(NSNumber(value: 1600), .iso) == "ISO-1600")
        #expect(SpotlightMetadata.format(NSNumber(value: 1920), .pixels) == "1920 pixels")
        #expect(SpotlightMetadata.format(NSNumber(value: 1200), .dpi) == "1200 dpi")
        #expect(SpotlightMetadata.format(NSNumber(value: 0.001), .exposure) == "1/1000 sec.")
        #expect(SpotlightMetadata.format(NSNumber(value: 1411), .bitRate) == "1411kbps")
    }

    @Test func groupsRowsInExplorerOrder() {
        let rows = SpotlightMetadata.rows(from: [
            "kMDItemPixelWidth": NSNumber(value: 1920), "kMDItemPixelHeight": NSNumber(value: 1080),
            "kMDItemAuthors": ["Ana"], "kMDItemTitle": "Trip", "kMDItemAcquisitionModel": "Phone",
        ])
        #expect(rows.first == MetadataRow(group: "Description", label: "Title", value: "Trip"))
        #expect(rows.contains(MetadataRow(group: "Image", label: "Dimensions", value: "1920 x 1080")))
        let groups = rows.map(\.group)
        #expect(groups.firstIndex(of: "Origin")! < groups.firstIndex(of: "Image")!)
        #expect(groups.firstIndex(of: "Image")! < groups.firstIndex(of: "Camera")!)
    }

    /// A small JPEG with camera EXIF, GPS and orientation 6, written by ImageIO.
    private func makePhoto(_ url: URL) throws {
        let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Cam 1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func imageFallbackReadsHeader() throws {
        let fx = try Fixture()
        let photo = fx.url("photo.jpg")
        try makePhoto(photo)
        let values = SpotlightMetadata.imageValues(photo)
        #expect((values["kMDItemPixelWidth"] as? NSNumber)?.intValue == 8)
        #expect(values["kMDItemAcquisitionMake"] as? String == "Acme")
        #expect((values["kMDItemLatitude"] as? Double) == 51.5)
    }

    @Test func cleanCopyDropsPersonalDataKeepsImage() throws {
        let fx = try Fixture()
        let photo = fx.url("photo.jpg")
        try makePhoto(photo)
        let before = try Data(contentsOf: photo)
        let copy = try MetadataRemoval.createCleanCopy(of: photo)
        #expect(copy.lastPathComponent == "photo - Copy.jpg")
        #expect(try Data(contentsOf: photo) == before)          // original untouched
        let values = SpotlightMetadata.imageValues(copy)
        #expect((values["kMDItemPixelWidth"] as? NSNumber)?.intValue == 8)
        #expect(values["kMDItemAcquisitionMake"] == nil)
        #expect(values["kMDItemLatitude"] == nil)
        let source = CGImageSourceCreateWithURL(copy as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
        // A second copy never overwrites the first.
        #expect(try MetadataRemoval.createCleanCopy(of: photo).lastPathComponent == "photo - Copy (2).jpg")
        #expect(!MetadataRemoval.canRemove(from: fx.url("a.txt")))
    }
}

@Suite struct TimeMachineParsingTests {
    @Test func parsesDestinationsAndSnapshots() throws {
        let plist: [String: Any] = ["Destinations": [["Name": "Backup", "Kind": "Local", "MountPoint": "/Volumes/Backup"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(TimeMachineStatus.parseDestinations(data) == [.init(name: "Backup", kind: "Local", mountPoint: "/Volumes/Backup")])
        let empty = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        #expect(TimeMachineStatus.parseDestinations(empty).isEmpty)
        let dates = TimeMachineStatus.parseSnapshotDates("Snapshot dates for disk /:\n2026-11-06-090000\n2026-11-07-101530\n")
        #expect(dates.count == 2)
        #expect(dates[0] > dates[1])
    }

    @Test func runningTmutilNeverThrows() {
        // Works with or without Time Machine configured; never needs administrator rights.
        let status = TimeMachineStatus.read(volume: URL(fileURLWithPath: "/"), timeout: 10)
        #expect(status.available || !status.isConfigured)
    }
}

@Suite struct BundleAndVolumeTests {
    @Test func volumeTypes() {
        #expect(VolumeInfo.typeText(local: false, isInternal: nil, removable: false, ejectable: false) == "Network Drive")
        #expect(VolumeInfo.typeText(local: true, isInternal: true, removable: false, ejectable: false) == "Local Disk")
        #expect(VolumeInfo.typeText(local: true, isInternal: false, removable: false, ejectable: true) == "External Disk")
        #expect(VolumeInfo.typeText(local: true, isInternal: false, removable: true, ejectable: true) == "Removable Disk")
    }

    @Test func rootVolumeReads() throws {
        let info = try #require(VolumeInfo.read(URL(fileURLWithPath: "/")))
        #expect(info.capacity > 0)
        #expect(info.used <= info.capacity)
        #expect(info.usedFraction > 0 && info.usedFraction <= 1)
        #expect(info.availableForImportantUsage >= info.free)
    }

    @Test func systemAppSignatureIsValid() throws {
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        let info = CodeSignatureInfo.read(app)
        #expect(info.status == .valid)
        #expect(info.trust == .apple)
        #expect(info.isVerified)
        #expect(info.identifier == "com.apple.calculator")
        #expect(info.certificates.contains { $0.contains("Apple") })
        let bundle = try #require(BundleInfo.read(app))
        #expect(bundle.identifier == "com.apple.calculator")
        #expect(bundle.version != nil)
    }

    @Test func plainFileIsUnsigned() throws {
        let fx = try Fixture()
        let file = try fx.file("plain.txt")
        #expect(CodeSignatureInfo.read(file).status == .unsigned)
    }

    @Test func trustNeedsAnAppleAnchor() {
        typealias R = CodeSignatureInfo.Requirement
        func trust(adHoc: Bool = false, _ met: Set<R>) -> CodeSignatureInfo.Trust {
            CodeSignatureInfo.trust(isAdHoc: adHoc) { met.contains($0) }
        }
        // A self-signed chain meets none of the Apple-anchored requirements.
        #expect(trust([]) == .untrusted)
        // Leaf OIDs alone mean nothing without the Apple anchor.
        #expect(trust([.developerID, .appStore, .notarized]) == .untrusted)
        #expect(trust(adHoc: true, [.appleIssued, .apple]) == .adHoc)
        #expect(trust([.appleIssued, .apple]) == .apple)
        #expect(trust([.appleIssued, .appStore]) == .appStore)
        #expect(trust([.appleIssued, .developerID]) == .developerID(notarized: false))
        #expect(trust([.appleIssued, .developerID, .notarized]) == .developerID(notarized: true))
        #expect(trust([.appleIssued]) == .appleCertificate)
    }

    @Test func selfSignedIsNotPresentedAsOK() {
        let forged = "Developer ID Application: Example Corp (ABCDE12345)"
        let info = CodeSignatureInfo(status: .valid, identifier: "x", teamIdentifier: nil,
                                     certificates: [forged, "Apple Root CA"], isAdHoc: false, trust: .untrusted)
        #expect(!info.isVerified)
        #expect(!info.statusText.contains("OK"))
        #expect(info.statusText.contains("Unknown developer"))
        #expect(info.signerName != forged)
        #expect(info.signerName?.contains("unverified") == true)
        let dev = CodeSignatureInfo(status: .valid, certificates: [forged], isAdHoc: false, trust: .developerID(notarized: true))
        #expect(dev.isVerified && dev.signerName == forged && dev.statusText.contains("notarized"))
        let broken = CodeSignatureInfo(status: .invalid("bad"), certificates: [], isAdHoc: false, trust: .apple)
        #expect(!broken.isVerified)
    }

    @Test func selfStatedSigningTimeIsLabelled() {
        let date = Date(timeIntervalSince1970: 0)
        let plain = PropertyFormat.longDate(date)
        let claimed = CodeSignatureInfo(status: .valid, certificates: ["x"], signingDate: date, isAdHoc: false, trust: .untrusted)
        #expect(claimed.signingTimeText != plain)
        #expect(claimed.signingTimeText?.contains("stated by the signer") == true)
        var stamped = claimed
        stamped.signingDateIsTimestamped = true
        #expect(stamped.signingTimeText == plain)
        let adHoc = CodeSignatureInfo(status: .valid, certificates: [], signingDate: date, isAdHoc: true, trust: .adHoc)
        #expect(adHoc.signingTimeText?.contains("stated by the signer") == true)
        let dev = CodeSignatureInfo(status: .valid, certificates: ["x"], signingDate: date, isAdHoc: false, trust: .developerID(notarized: false))
        #expect(dev.signingTimeText == plain)
        let invalid = CodeSignatureInfo(status: .invalid("bad"), certificates: ["x"], signingDate: date, isAdHoc: false, trust: .apple)
        #expect(invalid.signingTimeText?.contains("stated by the signer") == true)
        #expect(CodeSignatureInfo(status: .unsigned, certificates: [], isAdHoc: false).signingTimeText == nil)
    }

    @Test func adHocSignatureIsNotVerified() throws {
        let fx = try Fixture()
        let tool = fx.root.appendingPathComponent("tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", tool.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        let info = CodeSignatureInfo.read(tool)
        #expect(info.status == .valid)
        #expect(info.trust == .adHoc)
        #expect(!info.isVerified)
        #expect(info.teamIdentifier == nil)
        #expect(!info.statusText.contains("OK"))
    }

    @Test func universalBinaryWithAdHocSliceIsNotVerified() throws {
        let fx = try Fixture()
        func run(_ tool: String, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            try #require(p.terminationStatus == 0)
        }
        let apple = fx.root.appendingPathComponent("apple").path
        let local = fx.root.appendingPathComponent("local").path
        let mixed = fx.root.appendingPathComponent("mixed")
        // Keep Apple's arm64e slice; re-sign the x86_64 slice ad hoc.
        try run("/usr/bin/lipo", ["/usr/bin/true", "-thin", "arm64e", "-output", apple])
        try run("/usr/bin/lipo", ["/usr/bin/true", "-thin", "x86_64", "-output", local])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", local])
        try run("/usr/bin/lipo", ["-create", apple, local, "-output", mixed.path])
        let info = CodeSignatureInfo.read(mixed)
        #expect(!info.isVerified)
        #expect(info.trust != .apple)
        #expect(!info.statusText.contains("OK"))
    }
}
