import Foundation
import Testing
@testable import ArborCore

/// Crafted metadata and sizes must format or sum without trapping.
@Suite struct MetadataSafetyTests {
    @Test func checkedIntRejectsNonFiniteAndOutOfRange() {
        #expect(Int(checked: 12.9) == 12)
        #expect(Int(checked: -3.5) == -3)
        #expect(Int(checked: .nan) == nil)
        #expect(Int(checked: .infinity) == nil)
        #expect(Int(checked: -.infinity) == nil)
        #expect(Int(checked: 0x1p63) == nil)
        #expect(Int(checked: -0x1p63) == Int.min)
        #expect(Int(checked: 1e99) == nil)
    }

    @Test func id3YearRejectsInfNanAndExponents() {
        #expect(MetadataReader.year("1999") == 1999)
        #expect(MetadataReader.year("2004-05-01") == 2004)
        #expect(MetadataReader.year("inf") == nil)
        #expect(MetadataReader.year("nan") == nil)
        #expect(MetadataReader.year("1e99") == nil)
    }

    @Test func columnTextSurvivesCraftedNumbers() {
        #expect(ColumnValues.text(.number(1999), column: .year) == "1999")
        #expect(ColumnValues.text(.number(.nan), column: .year) == "")
        #expect(ColumnValues.text(.number(.infinity), column: .year) == "")
        #expect(ColumnValues.text(.number(1e30), column: .year) == "")
        #expect(ColumnValues.text(.bitRate(320_000), column: .bitRate) == "320kbps")
        #expect(ColumnValues.text(.bitRate(.infinity), column: .bitRate) == "")
        #expect(ColumnValues.text(.bitRate(1e300), column: .bitRate) == "")
    }

    @Test func durationsSurviveCraftedValues() {
        #expect(ColumnValues.durationText(3725.4) == "01:02:05")
        for bad in [Double.nan, .infinity, -.infinity, 6.4e31, 6.4e301, -5] {
            #expect(ColumnValues.durationText(bad) == "—")
            #expect(PropertyFormat.duration(bad) == "")
        }
        #expect(SpotlightMetadata.format(NSNumber(value: Double.infinity), .duration) == "")
    }

    @Test func spotlightFormatsSurviveCraftedValues() {
        let huge: Any = NSNumber(value: 1e300)
        let nan: Any = "nan"
        for format in [SpotlightMetadata.Format.pixels, .iso, .dpi, .bytes, .rating, .bitRate] {
            #expect(SpotlightMetadata.format(huge, format) == nil)
            #expect(SpotlightMetadata.format(nan, format) == nil)
        }
        #expect(SpotlightMetadata.format(NSNumber(value: 1e-300), .exposure) == nil)
        #expect(SpotlightMetadata.format(nan, .hertz) == nil)
        #expect(SpotlightMetadata.format(NSNumber(value: 44_100), .hertz) == "44.1 kHz")
        #expect(SpotlightMetadata.format(NSNumber(value: 0.004), .exposure) == "1/250 sec.")
        let rows = SpotlightMetadata.rows(from: ["kMDItemPixelWidth": NSNumber(value: Double.infinity),
                                                 "kMDItemPixelHeight": NSNumber(value: 10)])
        #expect(!rows.contains { $0.label == L10n.tr("Dimensions") })
    }

    /// AIFF whose COMM sample rate is 2^-100, so CoreAudio estimates a duration near 1e31 seconds.
    @Test func crazyAiffDurationDoesNotTrap() throws {
        var comm = Data()
        func be<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        comm += be(Int16(1)) + be(UInt32(10)) + be(Int16(16))
        comm += be(UInt16(16383 - 100)) + be(UInt64(1) << 63)   // 80-bit extended 2^-100
        let samples = Data(count: 20)
        var ssnd = be(UInt32(0)) + be(UInt32(0)); ssnd += samples
        var body = Data("AIFF".utf8)
        body += Data("COMM".utf8) + be(UInt32(comm.count)) + comm
        body += Data("SSND".utf8) + be(UInt32(ssnd.count)) + ssnd
        let file = Data("FORM".utf8) + be(UInt32(body.count)) + body
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crafted-\(UUID().uuidString).aiff")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let values = MetadataReader.audio(url)
        guard case .duration(let s)? = values[.length] else { Issue.record("no duration read"); return }
        #expect(s > 1e12)
        #expect(ColumnValues.text(values[.length], column: .length) == "—")
    }

    @Test func sizeTotalsSaturate() {
        #expect(Int64.max.saturatingAdd(1) == .max)
        #expect(Int64.min.saturatingAdd(-1) == .min)
        #expect(Int64(5).saturatingAdd(7) == 12)
        #expect([Int64.max, .max, 3].saturatingSum() == .max)
        #expect([Int64](repeating: 1 << 55, count: 257).saturatingSum() == .max)

        var a = SizeTotals(); a.size = .max; a.sizeOnDisk = .max - 1
        var b = SizeTotals(); b.size = 10; b.sizeOnDisk = 10
        let sum = a + b
        #expect(sum.size == .max && sum.sizeOnDisk == .max)

        let big = (0..<2).map { FileItem(url: URL(fileURLWithPath: "/tmp/big\($0)"), name: "big\($0)", isFolder: false, size: .max) }
        let summary = StatusText.summary(visible: 2, total: 2, query: "", selected: big)
        #expect(summary.contains(StatusText.bytes(.max)))
        _ = StatusText.explorerSummary(visible: 2, total: 2, query: "", selected: big)

        let entries = [SelectionSummary.Entry(isFolder: false, typeDescription: "File", parentPath: "/", size: .max),
                       SelectionSummary.Entry(isFolder: false, typeDescription: "File", parentPath: "/", size: .max)]
        #expect(SelectionSummary(entries).knownFileSize == .max)

        let claimed = [ArchiveEntry(rawPath: "a.bin", kind: .file, size: .max), ArchiveEntry(rawPath: "b.bin", kind: .file, size: .max)]
        // Declared sizes are capped per entry, so the total is bounded rather than saturated.
        #expect(ExtractionPlanner.plan(entries: claimed, roots: [""]).totalBytes == 2 * ArchiveEntry.maxDeclaredSize)
    }

    @Test func archiveIndexTotalSaturatesAndIgnoresNegativeSizes() {
        let huge = [ArchiveEntry(rawPath: "a.bin", kind: .file, size: .max), ArchiveEntry(rawPath: "b.bin", kind: .file, size: .max)]
        #expect(ArchiveIndex(entries: huge).totalSize == 2 * ArchiveEntry.maxDeclaredSize)
        let negative = [ArchiveEntry(rawPath: "a.bin", kind: .file, size: .min), ArchiveEntry(rawPath: "b.bin", kind: .file, size: .min),
                        ArchiveEntry(rawPath: "c.bin", kind: .file, size: 7)]
        #expect(ArchiveIndex(entries: negative).totalSize == 7)
    }

    @Test func transferTotalsSaturate() {
        let near = TransferTotals(items: 1, bytes: .max - 1)
        let sum = near + near
        #expect(sum.items == 2 && sum.bytes == .max)
    }

    @Test func speedTextSurvivesHugeRates() {
        _ = TransferRateEstimator.describeSpeed(1.8e19)
        _ = TransferRateEstimator.describeSpeed(.infinity)
        _ = TransferRateEstimator.describeSpeed(.nan)
        _ = TransferRateEstimator.describeSpeed(-5)
        var rate = TransferRateEstimator(window: 4, minimumElapsed: 0)
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: .max, at: 0.5)
        let speed = rate.bytesPerSecond(at: 0.5) ?? 0
        #expect(speed > 0x1p63)
        #expect(TransferRateEstimator.describeSpeed(speed).hasSuffix("/s"))
    }
}
