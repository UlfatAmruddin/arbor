import Foundation
import CryptoKit

/// "Verify after copying" result (FE-130; spec §9.2: verification is its own state).
public struct VerificationResult: Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public var path: String
        public var reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public var filesChecked = 0
    public var bytesChecked: Int64 = 0
    public var failures: [Failure] = []
    public var cancelled = false

    public init() {}
    public var isVerified: Bool { !cancelled && failures.isEmpty }
}

/// Checks copies against originals: size, then streamed SHA-256. The copy is read with `F_NOCACHE`
/// so bytes come from disk, not the page cache. Extra items in the copy (merges) are not failures;
/// skipped or failed items are excluded.
public enum CopyVerifier {
    public static let chunkSize = 1 << 20

    public static func verify(_ pairs: [(source: URL, copy: URL)], excluding excluded: Set<URL> = [],
                              control: TransferControl? = nil, chunkSize: Int = CopyVerifier.chunkSize,
                              progress: (_ bytesChecked: Int64) -> Void = { _ in }) -> VerificationResult {
        var result = VerificationResult()
        let skip = Set(excluded.map(\.standardizedFileURL.path))
        func cancelled() -> Bool {
            guard let control else { return false }
            if !control.checkpoint() { result.cancelled = true }
            return result.cancelled
        }
        func fail(_ url: URL, _ reason: String) {
            if result.failures.count < 10_000 { result.failures.append(.init(path: url.path, reason: reason)) }
        }
        func walk(_ source: URL, _ copy: URL) {
            if cancelled() || skip.contains(source.standardizedFileURL.path) { return }
            var s = stat(), c = stat()
            guard lstat(source.path, &s) == 0 else { return fail(source, "The original can't be read anymore.") }
            guard lstat(copy.path, &c) == 0 else { return fail(source, "The copy is missing.") }
            let sType = s.st_mode & S_IFMT, cType = c.st_mode & S_IFMT
            guard sType == cType else { return fail(source, "The copy is a different kind of item.") }
            switch sType {
            case S_IFDIR:
                let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
                for name in names where name != ".DS_Store" {
                    walk(source.appendingPathComponent(name), copy.appendingPathComponent(name))
                    if result.cancelled { return }
                }
            case S_IFLNK:
                result.filesChecked += 1
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
                    != (try? FileManager.default.destinationOfSymbolicLink(atPath: copy.path)) {
                    fail(source, "The copied link points somewhere else.")
                }
            case S_IFREG:
                result.filesChecked += 1
                guard s.st_size == c.st_size else {
                    return fail(source, "The sizes differ (\(s.st_size) bytes, copy \(c.st_size) bytes).")
                }
                switch compare(source, copy, control: control, chunkSize: chunkSize, progress: { delta in
                    result.bytesChecked += delta
                    progress(result.bytesChecked)
                }) {
                case .same: break
                case .different: fail(source, "The contents differ (SHA-256 doesn't match).")
                case .unreadable(let why): fail(source, why)
                case .cancelled: result.cancelled = true
                }
            default:
                break   // special files are never copied
            }
        }
        for pair in pairs {
            walk(pair.source, pair.copy)
            if result.cancelled { break }
        }
        return result
    }

    public enum Comparison: Equatable { case same, different, unreadable(String), cancelled }

    public static func compare(_ a: URL, _ b: URL, control: TransferControl? = nil, chunkSize: Int = CopyVerifier.chunkSize,
                               progress: (Int64) -> Void = { _ in }) -> Comparison {
        guard let ha = try? FileHandle(forReadingFrom: a) else { return .unreadable("The original couldn't be read.") }
        guard let hb = try? FileHandle(forReadingFrom: b) else { try? ha.close(); return .unreadable("The copy couldn't be read.") }
        defer { try? ha.close(); try? hb.close() }
        _ = fcntl(hb.fileDescriptor, F_NOCACHE, 1)
        var sa = SHA256(), sb = SHA256()
        while true {
            if let control, !control.checkpoint() { return .cancelled }
            let da: Data, db: Data
            do {
                da = try ha.read(upToCount: chunkSize) ?? Data()
                db = try hb.read(upToCount: chunkSize) ?? Data()
            } catch {
                return .unreadable("Reading failed: \(error.localizedDescription)")
            }
            if da.isEmpty && db.isEmpty { break }
            sa.update(data: da)
            sb.update(data: db)
            progress(Int64(da.count))
            if da.count != db.count { return .different }
        }
        return sa.finalize() == sb.finalize() ? .same : .different
    }

    /// Lowercase hex, streamed.
    public static func sha256Hex(_ url: URL, chunkSize: Int = CopyVerifier.chunkSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Fresh copies and merged folders, minus nested items that were skipped or failed.
    public static func pairs(for report: TransferReport) -> (pairs: [(source: URL, copy: URL)], excluded: Set<URL>) {
        guard report.kind == .copy else { return ([], []) }
        var pairs: [(source: URL, copy: URL)] = []
        for result in report.results {
            switch result.outcome {
            case .succeeded(let url), .merged(let url): pairs.append((result.source, url))
            default: break
            }
        }
        let excluded = Set(report.details.filter {
            switch $0.outcome {
            case .skipped, .failed, .partial, .cancelled: return true
            default: return false
            }
        }.map(\.source))
        return (pairs, excluded)
    }
}
