// The other app in a file promise drag, as a separate process. Used by the promisesinterop group of
// scripts/behavior-checks.sh, which compiles it (see docs/features/promised-files.md).
//
//   promise-peer offer <write|fail|die> <name>...
//       Puts one real NSFilePromiseProvider per name on the system's drag pasteboard, prints "ready" and
//       stays until killed (at most 120 seconds). write: delivers real content. fail: a partial file and
//       an error. die: a partial file, then the process ends.
//   promise-peer take <folder>
//       Receives whatever the drag pasteboard promises into <folder> with NSFilePromiseReceiver.
//
// AppKit delivers only for the drag pasteboard. Nothing here can start a drag, because that needs a pressed
// mouse button, so `take` sends the one message AppKit's drag manager would send at the end of a drop.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

final class Offer: NSObject, NSFilePromiseProviderDelegate {
    private static let chunkCount = 64
    private static let chunk = Data(repeating: 0x41, count: 64 * 1024)

    let mode: String
    let name: String

    init(mode: String, name: String) {
        self.mode = mode
        self.name = name
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        print("asked for the name of \(name)")
        return name
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        print("writing \(name) to \(url.deletingLastPathComponent().path)")
        do {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data("written by process \(getpid())\n".utf8))
            try handle.write(contentsOf: Self.chunk)
            if mode == "die" {
                print("dying")
                _exit(9)
            }
            if mode == "fail" {
                completionHandler(NSError(domain: "promise-peer", code: 1, userInfo: [NSLocalizedDescriptionKey: "The attachment could not be fetched."]))
                return
            }
            for _ in 1..<Self.chunkCount { try handle.write(contentsOf: Self.chunk) }
            print("finished \(name)")
            completionHandler(nil)
        } catch {
            print("failed \(name): \(error.localizedDescription)")
            completionHandler(error)
        }
    }
}

func offer(mode: String, names: [String]) {
    let offers = names.map { Offer(mode: mode, name: $0) }
    let pasteboard = NSPasteboard(name: .drag)
    pasteboard.clearContents()
    let written = pasteboard.writeObjects(offers.map { NSFilePromiseProvider(fileType: "public.data", delegate: $0) })
    print(written ? "ready" : "could not write to the pasteboard")
    withExtendedLifetime(offers) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { exit(0) }
        NSApplication.shared.run()
    }
}

func take(into folder: URL) {
    let endOfDrop = NSSelectorFromString("draggingEnded:")
    let pasteboard = NSPasteboard(name: .drag)
    let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    guard !receivers.isEmpty, receivers.allSatisfy({ $0.responds(to: endOfDrop) }) else {
        print("nothing to take: \(receivers.count) promises")
        exit(4)
    }
    var remaining = receivers.count
    var failed = false
    for receiver in receivers {
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
            if let error {
                failed = true
                print("error: \(error.localizedDescription)")
            } else {
                print("delivered \(url.lastPathComponent)")
            }
            remaining -= 1
            if remaining == 0 { exit(failed ? 5 : 0) }
        }
        receiver.perform(endOfDrop, with: nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("timed out")
        exit(3)
    }
    NSApplication.shared.run()
}

let arguments = Array(CommandLine.arguments.dropFirst())
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
switch arguments.first {
case "offer" where arguments.count >= 3 && ["write", "fail", "die"].contains(arguments[1]):
    offer(mode: arguments[1], names: Array(arguments[2...]))
case "take" where arguments.count == 2:
    take(into: URL(fileURLWithPath: arguments[1]))
default:
    print("usage: promise-peer offer <write|fail|die> <name>... | promise-peer take <folder>")
    exit(2)
}
