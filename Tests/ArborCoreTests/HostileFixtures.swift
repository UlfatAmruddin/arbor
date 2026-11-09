import Foundation
import Testing
@testable import ArborCore

/// Names a file manager must carry unchanged: never parsed, trimmed, normalized or run.
enum OddNames {
    static let ascii255 = String(repeating: "a", count: 255)
    /// 85 characters of three bytes each.
    static let cjk255 = String(repeating: "\u{6F22}", count: 85)
    /// 254 bytes as stored, 381 once a URL decomposes it: over NAME_MAX only if bytes were what counted.
    static let precomposedOverNameMaxDecomposed = String(repeating: "\u{E9}", count: 127)

    static let all: [String] = [
        ".dotfile", "..twodots", "...", "....", ".a.b.c",
        " leading space", "trailing space ", "   ", "trailing dot.", "ends with dots...",
        "-rf", "--help", "-", "~", "~user",
        "$(touch pwned)", "`touch pwned`", "a;b", "a&b", "a|b", "a>b", "a<b", "*", "?", "[x]", "{a,b}", "!bang", "#hash",
        "%d%s%n", "\"quoted\"", "'single'", "back\\slash", "co:lon", "%2F", "a%2Fb", "new\nline", "tab\there",
        "CON", "caf\u{E9}.txt", "cafe\u{301}.txt", "\u{1112}\u{1161}\u{11AB}", "\u{D55C}",
        "\u{1F469}\u{200D}\u{1F4BB} work", "a\u{202E}gnp.exe", "zero\u{200B}width",
        ascii255, cjk255, precomposedOverNameMaxDecomposed,
    ]
}

/// A tree built through descriptors, so it can pass PATH_MAX. Never chdir: tests run in parallel.
final class DeepTree {
    /// Resolved: symbolic links in the temporary folder's path count toward the limit.
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
    }

    deinit { ScratchVolume.run("/bin/rm", ["-rf", "--", root.path]) }   // FileManager gives up on these trees

    /// Bytes a job drops by standardizing the root (/private/var to /var); the kernel expands them again.
    var standardizingSlack: Int { root.path.utf8.count - root.standardizedFileURL.path.utf8.count }

    func url(_ components: [String]) -> URL {
        URL(fileURLWithPath: ([root.path] + components).joined(separator: "/"))
    }

    /// Folder names that bring `root/…` to exactly `length` bytes; a name never exceeds `nameLength`.
    func components(reaching length: Int, nameLength: Int = 200) -> [String] {
        var remaining = length - root.path.utf8.count
        var names: [String] = []
        while remaining > 0 {
            var take = min(nameLength + 1, remaining)
            if remaining - take == 1 { take -= 1 }   // a lone byte would be just the slash
            names.append(String(repeating: "d", count: take - 1))
            remaining -= take
        }
        return names
    }

    /// Creates the folders in `components`, reusing existing ones, and returns the URL of the last.
    @discardableResult
    func folder(_ components: [String]) throws -> URL {
        close(try descend(components))
        return url(components)
    }

    /// Creates the file at the end of `components`, along with its folders.
    @discardableResult
    func file(_ components: [String], _ contents: String = "x") throws -> URL {
        let parent = try descend(Array(components.dropLast()))
        defer { close(parent) }
        let file = openat(parent, components[components.count - 1], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw POSIXError(errno) }
        defer { close(file) }
        _ = contents.withCString { write(file, $0, strlen($0)) }
        return url(components)
    }

    /// A descriptor of the folder at `components`, created as needed; the caller closes it.
    private func descend(_ components: [String]) throws -> Int32 {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(errno) }
        for name in components {
            let made = mkdirat(fd, name, 0o755) == 0 || errno == EEXIST
            let next = made ? openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1
            let error = errno
            close(fd)
            guard next >= 0 else { throw POSIXError(error) }
            fd = next
        }
        return fd
    }
}

extension POSIXError {
    init(_ code: Int32) { self.init(POSIXErrorCode(rawValue: code) ?? .EIO) }
}

/// Every entry below a folder, read through descriptors so depth and length don't matter.
struct TreeManifest: Equatable {
    struct Entry: Equatable {
        let mode: UInt16
        let size: Int64
        let digest: Int?
        let link: String?
    }

    private(set) var entries: [String: Entry] = [:]

    subscript(path: String) -> Entry? { entries[path] }
    var paths: Set<String> { Set(entries.keys) }

    /// Volume bookkeeping that a file system adds by itself.
    private static let ignored: Set<String> = [".DS_Store", ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems"]

    init(of root: URL) {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        walk(fd, prefix: "")
    }

    private mutating func walk(_ folder: Int32, prefix: String) {
        for name in FileOps.entryNames(of: folder) ?? [] where !Self.ignored.contains(name) {
            let path = prefix + name
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            entries[path] = Entry(mode: kind, size: kind == S_IFREG ? Int64(info.st_size) : 0,
                                  digest: kind == S_IFREG ? Self.digest(name, in: folder) : nil,
                                  link: kind == S_IFLNK ? Self.link(name, in: folder) : nil)
            guard kind == S_IFDIR else { continue }
            let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            defer { close(child) }
            walk(child, prefix: path + "/")
        }
    }

    private static func digest(_ name: String, in folder: Int32) -> Int? {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = Hasher()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: buffer.withUnsafeBytes { $0 }[..<count]))
        }
        return hasher.finalize()
    }

    private static func link(_ name: String, in folder: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(folder, name, &buffer, Int(PATH_MAX))
        return count >= 0 ? String(cString: buffer) : nil
    }
}

/// Runs a job, cancelling it if it hangs: a test time limit can't free a thread blocked on the job's semaphore.
func finishing(_ transfer: FileTransfer, within seconds: TimeInterval = 30,
               _ run: () async -> TransferReport) async -> TransferReport {
    let expired = Flag()
    let timer = DispatchWorkItem {
        _ = expired.trip()
        transfer.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    let report = await run()
    timer.cancel()
    #expect(!expired.isSet, "the job didn't finish within \(seconds) seconds")
    return report
}

/// Skips every failure, for tests that check the report rather than the prompt.
let answerSkip: FileTransfer.FailureResolver = { _ in FailureDecision(.skip) }

extension FormattedVolume {
    /// Like `make`, but on CI a missing image is a failure, so a safety suite can't pass by doing nothing.
    static func required(_ fileSystem: String, megabytes: Int = 20, mountedAt mountPoint: URL? = nil) async -> FormattedVolume? {
        let volume = await make(fileSystem, megabytes: megabytes, mountedAt: mountPoint)
        if volume == nil, ProcessInfo.processInfo.environment["CI"] != nil {
            Issue.record("hdiutil couldn't provide a \(fileSystem) image")
        }
        return volume
    }

    /// Forced, as when a cable is pulled; the empty mount-point folder stays. Safe to repeat.
    func detach() async {
        await runTool(["detach", "-force", "-quiet", mount.path])
    }

    func attach() async {
        await runTool(["attach", "-nobrowse", "-noautoopen", "-quiet", "-mountpoint", mount.path, image.path])
    }

    /// On a GCD thread: hdiutil must not tie up the threads other tests' async work uses.
    private func runTool(_ arguments: [String]) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                ScratchVolume.run("/usr/bin/hdiutil", arguments)
                done.resume()
            }
        }
    }
}
