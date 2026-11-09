import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Rewrites an image's properties (FE-152): lossless copy, verified, swapped in atomically, original kept in the Trash.
public enum EmbeddedMetadataEditor {
    /// A swap that can be reversed: `url` holds `current`, and `kept` (in the Trash) holds what it replaced.
    public struct Revert: Sendable, Equatable {
        public let url: URL
        public let current: FileStamp
        public let kept: URL
        public let keptStamp: FileStamp
    }

    /// (staged original, where it came from) -> where it ended up. Replaceable in tests; the default is the Trash.
    public typealias Disposer = (_ staged: URL, _ original: URL) throws -> URL
    public static let trashDisposer: Disposer = { staged, original in try SystemTrash.trash(staged, recordedAs: original) }

    /// The exchange happened and couldn't be undone cleanly, so the first entry may be the only copy of something.
    private struct UndoFailed: Error {}

    /// Blocking. `edits` from `EmbeddedEdits.make`; empty edits are refused by the caller.
    /// `afterSwap` runs between the exchange and its proof, where tests stage another app getting in.
    @discardableResult
    public static func save(_ edits: [EmbeddedField: String], over snapshot: EmbeddedSnapshot,
                            dispose: Disposer = trashDisposer, afterSwap: () -> Void = {}) throws -> Revert {
        guard snapshot.blocked == nil else { throw snapshot.blocked ?? .unsupportedFile }
        guard edits.keys.allSatisfy(snapshot.editable.contains) else { throw EmbeddedFailure.notEditable }

        let held = try HeldOriginal(snapshot)
        defer { close(held.descriptor) }
        guard let source = CGImageSourceCreateWithData(held.bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == snapshot.typeIdentifier else { throw EmbeddedFailure.changedSinceRead }
        try EmbeddedReader.checkPixelBudget(source)

        let staging = try stagingFolder(for: snapshot.url)
        var keepStaging = false
        defer { if !keepStaging { try? FileManager.default.removeItem(at: staging) } }
        let staged = staging.appendingPathComponent(snapshot.url.lastPathComponent)
        try writeCopy(of: source, with: edits, to: staged, typeIdentifier: snapshot.typeIdentifier)
        try EmbeddedMetadataVerifier.verify(original: held.bytes, written: staged, edits: edits, type: snapshot.typeIdentifier)
        try carryFileAttributes(from: held, to: staged)

        guard let replacement = FileStamp(staged) else { throw EmbeddedFailure.writeFailed }
        do {
            try exchange(staged, holding: replacement, with: snapshot.url, holding: snapshot.stamp, refusal: .changedSinceRead, afterSwap: afterSwap)
        } catch is UndoFailed {
            guard (try? dispose(staged, snapshot.url)) != nil else {
                keepStaging = true
                throw EmbeddedFailure.interrupted(keptAt: staged.path)
            }
            throw EmbeddedFailure.interrupted(keptAt: nil)
        }
        let kept: URL
        do {
            kept = try dispose(staged, snapshot.url)
        } catch {
            // Without the Trash copy Undo couldn't work, and the rule is that a replaced file stays recoverable.
            guard swapBack(staged, holding: replacement, with: snapshot.url) else {
                keepStaging = true
                throw EmbeddedFailure.interrupted(keptAt: staged.path)
            }
            throw EmbeddedFailure.trashFailed
        }
        guard let keptStamp = FileStamp(kept) else { throw EmbeddedFailure.interrupted(keptAt: nil) }
        return Revert(url: snapshot.url, current: replacement, kept: kept, keptStamp: keptStamp)
    }

    /// Undo and Redo: puts the other version back, refusing if either file changed since. Returns the opposite step.
    public static func revert(_ step: Revert) throws -> Revert {
        do {
            try exchange(step.kept, holding: step.keptStamp, with: step.url, holding: step.current, refusal: .changedSinceSaved)
        } catch is UndoFailed {
            throw EmbeddedFailure.changedSinceSaved
        }
        return Revert(url: step.url, current: step.keptStamp, kept: step.kept, keptStamp: step.current)
    }

    /// Swaps two entries atomically, then proves each held what was expected; the swap is undone if not.
    private static func exchange(_ a: URL, holding expectedA: FileStamp, with b: URL, holding expectedB: FileStamp,
                                 refusal: EmbeddedFailure, afterSwap: () -> Void = {}) throws {
        guard FileStamp(a)?.sameState(as: expectedA) == true, FileStamp(b)?.sameState(as: expectedB) == true else { throw refusal }
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            if code == ENOTSUP || code == EINVAL { throw EmbeddedFailure.volumeCannotSwap }
            throw code == ENOENT ? refusal : EmbeddedFailure.writeFailed
        }
        afterSwap()
        guard FileStamp(b)?.sameState(as: expectedA) == true, FileStamp(a)?.sameState(as: expectedB) == true else {
            guard swapBack(a, holding: expectedA, with: b) else { throw UndoFailed() }
            throw refusal
        }
    }

    /// Undoes a finished exchange, but only over our own file. False leaves `a` holding something that isn't ours to delete.
    private static func swapBack(_ a: URL, holding ours: FileStamp, with b: URL) -> Bool {
        guard FileStamp(b)?.sameState(as: ours) == true, renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else { return false }
        return FileStamp(a)?.sameState(as: ours) == true
    }

    /// Same volume, private to this edit: nothing half-written is ever beside the original.
    private static func stagingFolder(for url: URL) throws -> URL {
        do {
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            guard FileOps.sameVolume(folder, url) else {
                try? FileManager.default.removeItem(at: folder)
                throw EmbeddedFailure.writeFailed
            }
            return folder
        } catch { throw EmbeddedFailure.writeFailed }
    }

    private static func writeCopy(of source: CGImageSource, with edits: [EmbeddedField: String], to staged: URL, typeIdentifier: String) throws {
        guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, typeIdentifier as CFString, CGImageSourceGetCount(source), nil) else {
            throw EmbeddedFailure.writeFailed
        }
        let metadata = CGImageMetadataCreateMutable()
        guard edits.allSatisfy({ set($0.key, to: $0.value, in: metadata) }) else { throw EmbeddedFailure.writeFailed }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else { throw EmbeddedFailure.writeFailed }
    }

    /// Through ImageIO's own mapping, so the XMP, IPTC and Exif copies agree; an empty title or rating 0 clears it.
    private static func set(_ field: EmbeddedField, to value: String, in metadata: CGMutableImageMetadata) -> Bool {
        func put(_ dictionary: CFString, _ key: CFString, _ item: CFTypeRef) -> Bool {
            CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, item)
        }
        switch field {
        case .title: return put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName, value as CFString)
        case .description: return put(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, value as CFString)
        case .rating: return put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCStarRating, NSNumber(value: Int(value) ?? 0))
        case .dateTaken:
            return put(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, value.isEmpty ? kCFNull : value as CFString)
        }
    }

    /// Permissions, owner, access list, flags, tags and comments stay; the modification date honestly moves.
    private static func carryFileAttributes(from held: HeldOriginal, to staged: URL) throws {
        let descriptor = open(staged.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EmbeddedFailure.writeFailed }
        defer { close(descriptor) }
        guard fcopyfile(held.descriptor, descriptor, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR)) == 0, futimes(descriptor, nil) == 0 else {
            throw EmbeddedFailure.writeFailed
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == held.info.st_uid, info.st_gid == held.info.st_gid,
              info.st_mode & 0o7777 == held.info.st_mode & 0o7777 else { throw EmbeddedFailure.writeFailed }
        var values = URLResourceValues()
        values.creationDate = Date(timeIntervalSince1970: TimeInterval(held.info.st_birthtimespec.tv_sec) + TimeInterval(held.info.st_birthtimespec.tv_nsec) / 1e9)
        var target = staged
        try? target.setResourceValues(values)
    }

    /// The original opened without following links and read whole, so what is verified is exactly what was stamped.
    private struct HeldOriginal {
        let descriptor: Int32
        let info: stat
        let bytes: Data

        init(_ snapshot: EmbeddedSnapshot) throws {
            let fd = open(snapshot.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw EmbeddedFailure.changedSinceRead }
            var ready = false
            defer { if !ready { close(fd) } }
            var first = stat()
            guard fstat(fd, &first) == 0, (first.st_mode & S_IFMT) == S_IFREG, snapshot.stamp.sameState(as: FileStamp(first)) else {
                throw EmbeddedFailure.changedSinceRead
            }
            guard first.st_nlink == 1 else { throw EmbeddedFailure.hardLinked }
            guard first.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else { throw EmbeddedFailure.locked }
            guard Int64(first.st_size) <= EmbeddedLimits.maxFileBytes else { throw EmbeddedFailure.tooLarge }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let data = try? handle.read(upToCount: Int(first.st_size)), Int64(data.count) == Int64(first.st_size),
                  (try? handle.read(upToCount: 1))?.isEmpty ?? true else { throw EmbeddedFailure.changedSinceRead }
            var last = stat()
            guard fstat(fd, &last) == 0, snapshot.stamp.sameState(as: FileStamp(last)) else { throw EmbeddedFailure.changedSinceRead }
            descriptor = fd
            info = first
            bytes = data
            ready = true
        }
    }
}
