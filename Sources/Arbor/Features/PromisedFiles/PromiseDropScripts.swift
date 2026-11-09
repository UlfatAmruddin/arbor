import AppKit
import ArborCore

/// A stand-in for another app's promise, so scripts exercise the drop path without a real drag.
final class ScriptedPromise: FilePromiseSource {
    enum Mode: String {
        /// Delivers, without declaring a name first.
        case ok, unnamed
        /// A partial file and an error; success with no file; a location outside staging; a symbolic link.
        case fail, lie, escape, link
        /// A partial file, then silence.
        case stall
        /// Keeps writing for several seconds, so a script can cancel it.
        case slow
    }

    private let mode: Mode
    private let name: String

    init(mode: Mode, name: String) {
        self.mode = mode
        self.name = name
    }

    var promisedNames: [String] { mode == .unnamed ? [] : [name] }

    func receive(into folder: URL, reader: @escaping @Sendable (URL, Error?) -> Void) {
        let mode = self.mode
        let target = folder.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async {
            let partial = Data("partial".utf8)
            switch mode {
            case .ok, .unnamed:
                try? Data("delivered".utf8).write(to: target)
                reader(target, nil)
            case .fail:
                try? partial.write(to: target)
                reader(target, NSError(domain: "scripted", code: 1, userInfo: [NSLocalizedDescriptionKey: "The attachment could not be fetched."]))
            case .lie:
                reader(target, nil)
            case .escape:
                let outside = folder.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent)
                try? partial.write(to: outside)
                reader(outside, nil)
            case .link:
                try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
                reader(target, nil)
            case .stall:
                try? partial.write(to: target)
            case .slow:
                FileManager.default.createFile(atPath: target.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: target) else { return }
                defer { try? handle.close() }
                let chunk = Data(repeating: 7, count: 64 * 1024)
                for _ in 0..<40 {
                    // The folder disappears when the drop is cancelled; stop then, as a provider's failed write would.
                    guard (try? handle.write(contentsOf: chunk)) != nil, FileManager.default.fileExists(atPath: target.path) else { return }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                reader(target, nil)
            }
        }
    }
}

enum PromiseDropScripts {
    static func register() {
        // promisedrop:<mode>:<name>:/folder — what dropping that promise on the folder does.
        DebugScript.registerStep("promisedrop") { arg, window in
            let parts = arg.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let mode = ScriptedPromise.Mode(rawValue: parts[0]) else { return 0.1 }
            PromiseDrop.receive([ScriptedPromise(mode: mode, name: parts[1])], into: URL(fileURLWithPath: parts[2]), window: window?.window)
            return 0.1
        }
        // The status bar's Cancel button.
        DebugScript.registerStep("promisecancel") { _, _ in
            OperationCenter.shared.cancelAll()
            return 0.1
        }
        // promisewait: holds the script until no reception or job is running.
        DebugScript.registerWaitStep("promisewait") { _, _, elapsed in
            !OperationCenter.shared.hasActiveJobs || elapsed > 60
        }
        DebugScript.registerLogger("promised-files.log") { _ in
            let staging = PromiseDrop.lastStaging.map { FileManager.default.fileExists(atPath: $0.path) ? "present" : "gone" } ?? "none"
            return "promised: staging=\(staging) report=\(PromiseDrop.lastReport ?? "none") job=\(OperationCenter.shared.statusLine?.text ?? "none")"
        }
    }
}
