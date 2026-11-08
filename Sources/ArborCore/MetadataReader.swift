import Foundation
import CoreServices
import ImageIO
import AudioToolbox
import AVFoundation
import UniformTypeIdentifiers

/// Reads Details column values for one item (FE-036). Blocking: call off the main thread.
/// Spotlight first, then the file itself, so unindexed folders still work.
public enum MetadataReader {
    static let imageColumns: Set<ColumnID> = [.dimensions, .width, .height, .dateTaken, .cameraModel]
    static let audioColumns: Set<ColumnID> = [.trackNumber, .artists, .album, .genre, .year]
    static let timedColumns: Set<ColumnID> = [.length, .bitRate]

    public enum Kind: Equatable { case folder, image, audio, video, paged, other }

    public static func kind(of url: URL, isFolder: Bool) -> Kind {
        if isFolder { return .folder }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .compositeContent) { return .paged }
        return .other
    }

    /// Unsupported cells stay blank, like Explorer.
    public static func applies(_ column: ColumnID, to kind: Kind) -> Bool {
        switch column {
        case .dimensions, .width, .height: return kind == .image || kind == .video
        case .dateTaken, .cameraModel: return kind == .image
        case .length, .bitRate: return kind == .audio || kind == .video
        case .trackNumber, .artists, .album, .genre, .year: return kind == .audio
        case .pages: return kind == .paged
        case .title, .authors, .sizeOnDisk: return kind != .folder
        default: return true
        }
    }

    public static func read(_ url: URL, isFolder: Bool, columns: Set<ColumnID>) -> [ColumnID: ColumnValue] {
        var result: [ColumnID: ColumnValue] = [:]
        let kind = kind(of: url, isFolder: isFolder)
        var wanted = Set<ColumnID>()
        for column in columns {
            if applies(column, to: kind) { wanted.insert(column) } else { result[column] = .unsupported }
        }
        if wanted.isEmpty { return result }

        let fsKeys: Set<URLResourceKey> = [.creationDateKey, .contentAccessDateKey, .totalFileAllocatedSizeKey,
                                           .fileAllocatedSizeKey, .tagNamesKey, .contentModificationDateKey]
        let fs = try? url.resourceValues(forKeys: fsKeys)
        for column in wanted {
            switch column {
            case .dateCreated: result[column] = fs?.creationDate.map(ColumnValue.date) ?? .unknown
            case .dateAccessed: result[column] = fs?.contentAccessDate.map(ColumnValue.date) ?? .unknown
            case .sizeOnDisk:
                let n = fs?.totalFileAllocatedSize ?? fs?.fileAllocatedSize
                result[column] = n.map { .bytes(Int64($0)) } ?? .unknown
            case .tags:
                if let fs { result[column] = (fs.tagNames ?? []).isEmpty ? .empty : .list(fs.tagNames ?? []) } else { result[column] = .unknown }
            default: break
            }
        }
        let content = wanted.filter { result[$0] == nil }
        if content.isEmpty { return result }

        var found: [ColumnID: ColumnValue] = spotlight(url, content)
        let missing = content.filter { found[$0] == nil }
        if !missing.isEmpty {
            switch kind {
            case .image: found.merge(image(url), uniquingKeysWith: { a, _ in a })
            case .audio: found.merge(audio(url), uniquingKeysWith: { a, _ in a })
            case .video: found.merge(video(url), uniquingKeysWith: { a, _ in a })
            default: break
            }
        }
        for column in content {
            if let value = found[column] {
                result[column] = value
            } else if column == .itemDate {
                result[column] = (fs?.creationDate ?? fs?.contentModificationDate).map(ColumnValue.date) ?? .unknown
            } else {
                // Expected but unreadable values are unknown; optional properties the file lacks are empty.
                let expected: Set<ColumnID> = [.dimensions, .width, .height, .length]
                result[column] = expected.contains(column) ? .unknown : .empty
            }
        }
        return result
    }

    // MARK: Spotlight

    static func spotlight(_ url: URL, _ columns: Set<ColumnID>) -> [ColumnID: ColumnValue] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return [:] }
        func attr(_ key: CFString) -> Any? { MDItemCopyAttribute(item, key) }
        func number(_ key: CFString) -> Double? { (attr(key) as? NSNumber)?.doubleValue }
        func string(_ key: CFString) -> String? { (attr(key) as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func strings(_ key: CFString) -> [String]? { (attr(key) as? [String]).flatMap { $0.isEmpty ? nil : $0 } }

        var out: [ColumnID: ColumnValue] = [:]
        let w = number(kMDItemPixelWidth), h = number(kMDItemPixelHeight)
        for column in columns {
            switch column {
            case .dimensions: if let w = w.flatMap(Int.init(checked:)), let h = h.flatMap(Int.init(checked:)) { out[column] = .dimensions(width: w, height: h) }
            case .width: if let w { out[column] = .number(w) }
            case .height: if let h { out[column] = .number(h) }
            case .dateTaken, .itemDate: if let d = attr(kMDItemContentCreationDate) as? Date { out[column] = .date(d) }
            case .cameraModel: if let s = string(kMDItemAcquisitionModel) { out[column] = .text(s) }
            case .length: if let s = number(kMDItemDurationSeconds) { out[column] = .duration(s) }
            case .bitRate: if let b = number(kMDItemAudioBitRate) ?? number(kMDItemTotalBitRate) { out[column] = .bitRate(b) }
            case .title:
                // Unindexed files report their file name as the title.
                if let s = string(kMDItemTitle), s != url.lastPathComponent, s != url.deletingPathExtension().lastPathComponent {
                    out[column] = .text(s)
                }
            case .authors, .artists: if let a = strings(kMDItemAuthors) { out[column] = .list(a) }
            case .album: if let s = string(kMDItemAlbum) { out[column] = .text(s) }
            case .trackNumber: if let n = number(kMDItemAudioTrackNumber) { out[column] = .number(n) }
            case .genre: if let s = string(kMDItemMusicalGenre) { out[column] = .text(s) }
            case .year: if let n = number(kMDItemRecordingYear) { out[column] = .number(n) }
            case .pages: if let n = number(kMDItemNumberOfPages) { out[column] = .number(n) }
            case .comments: if let s = string(kMDItemFinderComment) { out[column] = .text(s) }
            default: break
            }
        }
        return out
    }

    // MARK: File fallbacks

    static func image(_ url: URL) -> [ColumnID: ColumnValue] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [ColumnID: ColumnValue] = [:]
        if let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            out[.dimensions] = .dimensions(width: w, height: h)
            out[.width] = .number(Double(w))
            out[.height] = .number(Double(h))
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: original) { out[.dateTaken] = .date(d); out[.itemDate] = .date(d) }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], let model = tiff[kCGImagePropertyTIFFModel] as? String {
            out[.cameraModel] = .text(model)
        }
        return out
    }

    static func audio(_ url: URL) -> [ColumnID: ColumnValue] {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return [:] }
        defer { AudioFileClose(file) }
        var out: [ColumnID: ColumnValue] = [:]
        var duration: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr, duration.isFinite, duration > 0 {
            out[.length] = .duration(duration)
        }
        var bitRate: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitRate) == noErr, bitRate > 0 {
            out[.bitRate] = .bitRate(Double(bitRate))
        }
        var info: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        if AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
           let dict = info?.takeRetainedValue() as? [String: Any] {
            func text(_ key: String) -> String? { (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            if let t = text(kAFInfoDictionary_Title) { out[.title] = .text(t) }
            if let a = text(kAFInfoDictionary_Artist) { out[.artists] = .list([a]); out[.authors] = .list([a]) }
            if let a = text(kAFInfoDictionary_Album) { out[.album] = .text(a) }
            if let g = text(kAFInfoDictionary_Genre) { out[.genre] = .text(g) }
            if let y = text(kAFInfoDictionary_Year).flatMap(year) { out[.year] = .number(y) }
            if let n = text(kAFInfoDictionary_TrackNumber).flatMap({ Double($0.split(separator: "/").first ?? "") }) {
                out[.trackNumber] = .number(n)
            }
        }
        return out
    }

    /// ID3 year text; Int, not Double, so "inf" and "nan" are rejected.
    static func year(_ text: String) -> Double? { Int(text.prefix(4)).map(Double.init) }

    /// Locked: the loading task can still be writing after the caller's wait times out.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ColumnID: ColumnValue] = [:]
        var values: [ColumnID: ColumnValue] { lock.withLock { stored } }
        func set(_ column: ColumnID, _ value: ColumnValue) { lock.withLock { stored[column] = value } }
    }

    /// AVFoundation is async-only; waits up to 5 s on this background thread.
    static func video(_ url: URL) -> [ColumnID: ColumnValue] {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { box.set(.length, .duration(d.seconds)) }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let w = Int(checked: Double(abs(size.width))), let h = Int(checked: Double(abs(size.height))) {
                box.set(.dimensions, .dimensions(width: w, height: h))
                box.set(.width, .number(Double(w)))
                box.set(.height, .number(Double(h)))
                if let rate = try? await track.load(.estimatedDataRate), rate.isFinite, rate > 0 { box.set(.bitRate, .bitRate(Double(rate))) }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return box.values
    }
}

/// Bounded, thread-safe LRU of column values, filled off the main thread (spec §15.3).
/// Keyed by path + modification date so a replaced file is re-read; requests are cancellable per owner.
public final class ColumnValueStore: @unchecked Sendable {
    public static let shared = ColumnValueStore()

    struct Key: Hashable {
        let path: String
        let modified: TimeInterval
        init(_ item: FileItem) {
            path = item.url.path
            modified = item.modified?.timeIntervalSinceReferenceDate ?? 0
        }
    }

    private struct Entry {
        var values: [ColumnID: ColumnValue]
        var stamp: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Set<ColumnID>] = [:]
    private var clock: UInt64 = 0
    public let limit: Int
    private let queue: OperationQueue
    /// Replaceable in tests.
    var reader: (URL, Bool, Set<ColumnID>) -> [ColumnID: ColumnValue] = MetadataReader.read

    public init(limit: Int = 4000, concurrency: Int = 2) {
        self.limit = limit
        queue = OperationQueue()
        queue.name = "Arbor column metadata"
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .utility
    }

    /// nil while not yet read.
    public func value(_ item: FileItem, _ column: ColumnID) -> ColumnValue? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[Key(item)], let value = entry.values[column] else { return nil }
        clock += 1
        entry.stamp = clock
        entries[Key(item)] = entry
        return value
    }

    /// Not cached and not in flight.
    public func missing(_ item: FileItem, _ columns: Set<ColumnID>) -> Set<ColumnID> {
        lock.lock(); defer { lock.unlock() }
        let key = Key(item)
        let have = Set(entries[key]?.values.keys.map { $0 } ?? [])
        return columns.subtracting(have).subtracting(inFlight[key] ?? [])
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// `completion` runs on the main queue once per finished batch. Returns the number queued.
    @discardableResult
    public func request(_ items: [FileItem], columns: Set<ColumnID>, owner: String, batchSize: Int = 16,
                        completion: @escaping ([FileItem]) -> Void) -> Int {
        let columns = columns.filter(ColumnCatalog.needsLoading)
        guard !columns.isEmpty else { return 0 }
        var work: [(FileItem, Set<ColumnID>)] = []
        lock.lock()
        for item in items {
            let key = Key(item)
            let have = Set(entries[key]?.values.keys.map { $0 } ?? [])
            let need = columns.subtracting(have).subtracting(inFlight[key] ?? [])
            if need.isEmpty { continue }
            inFlight[key, default: []].formUnion(need)
            work.append((item, need))
        }
        lock.unlock()
        guard !work.isEmpty else { return 0 }
        var start = 0
        while start < work.count {
            let batch = Array(work[start..<min(start + batchSize, work.count)])
            start += batchSize
            let op = ReadOperation(batch: batch)
            op.name = owner
            op.work = { [weak self, weak op] in
                guard let self else { return }
                var done: [FileItem] = []
                for (item, need) in batch {
                    if op?.isCancelled == true { break }
                    let values = self.reader(item.url, item.isFolder, need)
                    var filled = values
                    for column in need where filled[column] == nil { filled[column] = .unknown }
                    self.store(item, filled)
                    done.append(item)
                }
                // Release reservations of items skipped by cancellation.
                self.release(batch.filter { pair in !done.contains(pair.0) })
                if !done.isEmpty { DispatchQueue.main.async { completion(done) } }
            }
            queue.addOperation(op)
        }
        return work.count
    }

    /// Running batches stop between items.
    public func cancel(owner: String) {
        for case let op as ReadOperation in queue.operations where op.name == owner && !op.isCancelled {
            op.cancel()
            // Never runs if not started, so give its items back.
            if !op.isExecuting { release(op.batch) }
        }
    }

    private final class ReadOperation: Operation, @unchecked Sendable {
        let batch: [(FileItem, Set<ColumnID>)]
        var work: (() -> Void)?
        init(batch: [(FileItem, Set<ColumnID>)]) { self.batch = batch }
        override func main() { work?() }
    }

    /// Tests and memory pressure.
    public func removeAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// Tests only.
    public func waitUntilIdle() { queue.waitUntilAllOperationsAreFinished() }

    private func store(_ item: FileItem, _ values: [ColumnID: ColumnValue]) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(item)
        clock += 1
        var entry = entries[key] ?? Entry(values: [:], stamp: clock)
        entry.values.merge(values, uniquingKeysWith: { _, new in new })
        entry.stamp = clock
        entries[key] = entry
        if var flight = inFlight[key] {
            flight.subtract(values.keys)
            inFlight[key] = flight.isEmpty ? nil : flight
        }
        if entries.count > limit { evict() }
    }

    private func release(_ batch: [(FileItem, Set<ColumnID>)]) {
        guard !batch.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for (item, need) in batch {
            let key = Key(item)
            if var flight = inFlight[key] {
                flight.subtract(need)
                inFlight[key] = flight.isEmpty ? nil : flight
            }
        }
    }

    /// Drops the least recently used quarter. Lock held.
    private func evict() {
        let drop = max(1, entries.count - limit * 3 / 4)
        let oldest = entries.sorted { $0.value.stamp < $1.value.stamp }.prefix(drop).map(\.key)
        for key in oldest { entries[key] = nil }
    }
}
