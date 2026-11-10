import Foundation
import Darwin

/// One kind of file whose embedded properties can be rewritten (FE-152). A new kind is one new type listed in `EmbeddedFormats.all`.
protocol EmbeddedFormat: Sendable {
    var typeIdentifiers: Set<String> { get }
    /// Larger files stay read-only.
    var maxFileBytes: Int64 { get }
    /// What the file holds and which fields it can take; nil when it isn't this format.
    func inspect(_ url: URL, info: stat) -> EmbeddedInspection?
    /// Writes a copy of `held` with `edits` applied to `staged`, which must not exist yet.
    func produce(_ edits: [EmbeddedField: String], from held: EmbeddedHeldFile, type: String, to staged: URL) throws
    /// Throws unless `written` provably holds everything `held` did, changed only by `edits`.
    func verify(_ edits: [EmbeddedField: String], original held: EmbeddedHeldFile, written: URL, type: String) throws
}

/// What a format found in one file.
struct EmbeddedInspection {
    let typeIdentifier: String
    let support: EmbeddedSupport
    let fields: [EmbeddedField: EmbeddedReader.Raw]
    /// The file costs too much to rewrite; reported ahead of the file's own state.
    var budgetBlock: EmbeddedFailure?
    /// The file holds something a rewrite can't keep; reported after the file's own state.
    var contentBlock: EmbeddedFailure?
}

enum EmbeddedFormats {
    static let all: [any EmbeddedFormat] = [ImageEmbeddedFormat(), ID3Format(), FLACFormat(), M4AFormat()]

    static func format(forType identifier: String) -> (any EmbeddedFormat)? {
        all.first { $0.typeIdentifiers.contains(identifier) }
    }

    static func inspect(_ url: URL, info: stat) -> (format: any EmbeddedFormat, found: EmbeddedInspection)? {
        for format in all {
            if let found = format.inspect(url, info: info) { return (format, found) }
        }
        return nil
    }
}

/// The original opened without following links, so what is read is exactly what was stamped.
final class EmbeddedHeldFile {
    let descriptor: Int32
    let info: stat
    private let stamp: FileStamp
    private var whole: Data?

    init(_ snapshot: EmbeddedSnapshot, limit: Int64) throws {
        let fd = open(snapshot.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw EmbeddedFailure.changedSinceRead }
        var first = stat()
        var failure: EmbeddedFailure?
        if fstat(fd, &first) != 0 || (first.st_mode & S_IFMT) != S_IFREG || !snapshot.stamp.sameState(as: FileStamp(first)) {
            failure = .changedSinceRead
        } else if first.st_nlink != 1 {
            failure = .hardLinked
        } else if first.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 {
            failure = .locked
        } else if Int64(first.st_size) > limit {
            failure = .tooLarge
        }
        if let failure {
            close(fd)
            throw failure
        }
        descriptor = fd
        info = first
        stamp = snapshot.stamp
    }

    deinit { close(descriptor) }

    /// Read once and bounded by the format's limit, for formats that hand a whole file to a framework.
    func wholeBytes() throws -> Data {
        if let whole { return whole }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(info.st_size)), Int64(data.count) == Int64(info.st_size),
              (try? handle.read(upToCount: 1))?.isEmpty ?? true else { throw EmbeddedFailure.changedSinceRead }
        var last = stat()
        guard fstat(descriptor, &last) == 0, stamp.sameState(as: FileStamp(last)) else { throw EmbeddedFailure.changedSinceRead }
        whole = data
        return data
    }
}
