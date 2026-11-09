import Foundation
import Testing
@testable import ArborCore

@Suite("This Mac search coverage")
struct WholeMacCoverageTests {
    private let startup = VolumeSummary(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", kind: .startup)
    private let usb = VolumeSummary(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB", kind: .external)
    private let nas = VolumeSummary(url: URL(fileURLWithPath: "/Volumes/NAS"), name: "NAS", kind: .network)

    private func row(_ volume: VolumeSummary, _ state: SpotlightIndexState, findings: SearchVolumeFindings = SearchVolumeFindings(),
                     answered: Bool = true) -> SearchLocationCoverage {
        WholeMacCoverage.locations(volumes: [volume], indexStates: [volume.url.path: state], findings: [volume.url.path: findings],
                                   spotlightAnswered: answered)[0]
    }

    private func findings(_ scan: SearchVolumeFindings.Scan, denied: Int = 0, unreadable: Int = 0) -> SearchVolumeFindings {
        var value = SearchVolumeFindings()
        value.scan = scan
        value.denied = denied
        value.unreadable = unreadable
        return value
    }

    @Test func networkVolumesAreAlwaysLeftOutWithTheReason() {
        let result = row(nas, .enabled, findings: findings(.finished))
        #expect(result.status == .excluded)
        #expect(result.reason.contains("Network volumes"))
    }

    @Test func indexingOffLeavesAnUnscannedVolumeOut() {
        let result = row(startup, .disabled)
        #expect(result.status == .excluded)
        #expect(result.reason.contains("Spotlight indexing is off"))
    }

    @Test func aScannedVolumeCountsEvenWithIndexingOff() {
        #expect(row(usb, .disabled, findings: findings(.finished)) ==
                SearchLocationCoverage(name: "USB", status: .included, reason: "Scanned folder by folder."))
        #expect(row(usb, .enabled, findings: findings(.finished)).reason.contains("plus the Spotlight index"))
    }

    @Test func theIndexAloneNeedsAnAnswer() {
        #expect(row(startup, .enabled).status == .included)
        #expect(row(startup, .enabled, answered: false).status == .partial)
        #expect(row(startup, .unknown).status == .partial)
    }

    @Test func deniedAndUnreadableFoldersMakeAVolumePartial() {
        let one = row(usb, .disabled, findings: findings(.finished, denied: 1))
        #expect(one.status == .partial)
        #expect(one.reason == "Scanned folder by folder. macOS denied access to 1 folder.")
        let many = row(usb, .disabled, findings: findings(.finished, denied: 3, unreadable: 2))
        #expect(many.reason.contains("macOS denied access to 3 folders."))
        #expect(many.reason.contains("2 folders couldn't be read."))
        #expect(row(startup, .enabled, findings: findings(.notRun, denied: 2)).status == .partial)
    }

    @Test func aScanCutShortIsNeverCalledComplete() {
        let result = row(usb, .disabled, findings: findings(.cutShort))
        #expect(result.status == .partial)
        var report = DirectSearchReport()
        report.cancelled = true
        var value = SearchVolumeFindings()
        value.add(report)
        #expect(value.scan == .cutShort)
        report.cancelled = false
        report.deniedCount = 4
        var finished = SearchVolumeFindings()
        finished.add(report)
        #expect(finished.scan == .finished && finished.denied == 4)
    }

    @Test func volumesAreOrderedAndCapped() {
        let many = (0..<50).map { VolumeSummary(url: URL(fileURLWithPath: "/Volumes/V\($0)"), name: "V\($0)", kind: .external) }
        #expect(WholeMacCoverage.ordered(many + [startup]).first == startup)
        #expect(WholeMacCoverage.ordered(many).count == WholeMacCoverage.volumeLimit)
        #expect(WholeMacCoverage.ordered([nas, usb, startup]).map(\.name) == ["Macintosh HD", "USB", "NAS"])
    }

    @Test func aVolumeLabelCannotForgeLines() {
        let odd = VolumeSummary(url: URL(fileURLWithPath: "/Volumes/x"), name: "a\nb\u{202E}c", kind: .external)
        #expect(row(odd, .enabled).name == "a b c")
    }

    @Test func aPathBelongsToItsLongestMount() {
        let volumes = [startup, usb, nas]
        #expect(WholeMacCoverage.volume(holding: "/Volumes/USB/a/b", in: volumes) == usb)
        #expect(WholeMacCoverage.volume(holding: "/Users/me/a", in: volumes) == startup)
        #expect(WholeMacCoverage.volume(holding: "/Volumes/USB2/a", in: volumes) == startup)
    }

    @Test func networkFoldersAreNeverScanned() {
        let urls = [usb.url, nas.url, nas.url.appendingPathComponent("share")]
        #expect(WholeMacCoverage.scannable(urls, volumes: [startup, usb, nas]) == [usb.url])
    }

    @Test func theExplanationListsEveryGroupAndTheStatusNamesWhatWasLeftOut() {
        var coverage = SearchCoverage()
        coverage.phase = .finished
        coverage.indexOnly = true
        coverage.locations = [SearchLocationCoverage(name: "Macintosh HD", status: .included, reason: "Searched through the Spotlight index."),
                              SearchLocationCoverage(name: "USB", status: .partial, reason: "Scanned folder by folder. macOS denied access to 1 folder."),
                              SearchLocationCoverage(name: "NAS", status: .excluded, reason: "Network volumes aren't searched.")]
        coverage.locationNotes = WholeMacCoverage.notes(searchedContents: false)
        #expect(coverage.statusLine == "Search incomplete: “NAS” wasn't searched (+1 more)")
        let lines = coverage.details
        #expect(lines.contains("Included:"))
        #expect(lines.contains("    Macintosh HD: Searched through the Spotlight index."))
        #expect(lines.contains("Partly included:"))
        #expect(lines.contains("Left out:"))
        #expect(lines.contains("    NAS: Network volumes aren't searched."))
        #expect(lines.contains { $0.contains("System Settings ▸ Spotlight") })
        #expect(lines.contains { $0.contains("Only names were searched") })
        #expect(!coverage.isComplete)
    }

    @Test func severalLeftOutVolumesAreSummarized() {
        var coverage = SearchCoverage()
        coverage.phase = .finished
        coverage.locations = (1...4).map { SearchLocationCoverage(name: "V\($0)", status: .excluded, reason: "r") }
        #expect(coverage.statusLine == "Search incomplete: 4 volumes weren't searched (V1, V2, V3, …)")
    }

    @Test func contentsNoteOnlyWhenContentsWerentSearched() {
        #expect(WholeMacCoverage.notes(searchedContents: true).allSatisfy { !$0.contains("Only names") })
    }

    @Test func injectedVolumesParseAndMalformedOnesAreDropped() {
        let list = InjectedSearchVolume.parse("HD|startup|enabled|/tmp/fixture/hd;Old|startup|disabled|/tmp/fixture/old;Bad|nope|enabled|/x;NAS|network|unknown|/tmp/fixture/nas;Card|external|disabled|;short")
        #expect(list.map(\.volume.name) == ["HD", "Old", "NAS", "Card"])
        #expect(list[0].scanFolder?.path == "/tmp/fixture/hd")
        #expect(list[1].scanFolder == nil, "a startup disk with indexing off is never scanned")
        #expect(list[2].scanFolder == nil, "a network volume is never scanned")
        #expect(list[3].scanFolder == nil, "no folder, nothing to read")
        #expect(list[3].volume.url.path == "/Volumes/Card")
        #expect(InjectedSearchVolume.parse("").isEmpty)
        let flood = (0..<100).map { "V\($0)|external|enabled|" }.joined(separator: ";")
        #expect(InjectedSearchVolume.parse(flood).count == WholeMacCoverage.volumeLimit)
    }

    @Test func theMountTableSuppliesOnlyBrowsableVolumes() {
        let mounts = MountPoints(read: {
            ["/": MountEntry(path: "/", isLocal: true, fileSystemType: "apfs"),
             "/System/Volumes/Data": MountEntry(path: "/System/Volumes/Data", isLocal: true, fileSystemType: "apfs", isBrowsable: false),
             "/dev": MountEntry(path: "/dev", isLocal: true, fileSystemType: "devfs"),
             "/Volumes/USB": MountEntry(path: "/Volumes/USB", isLocal: true, fileSystemType: "exfat"),
             "/Volumes/NAS": MountEntry(path: "/Volumes/NAS", isLocal: false, fileSystemType: "smbfs")]
        })
        let volumes = WholeMacCoverage.ordered(mounts.browsableVolumes())
        #expect(volumes.map(\.url.path) == ["/", "/Volumes/USB", "/Volumes/NAS"])
        #expect(volumes.map(\.kind) == [.startup, .external, .network])
    }
}
