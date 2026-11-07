import AppKit
import ArborCore

/// Watches one folder for changes and coalesces bursts of events.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var throttle = EventThrottle()
    private(set) var url: URL?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        if url == self.url, source != nil { return }
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.url = url
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .extend], queue: .main)
        throttle.reset()
        src.setEventHandler { [weak self] in
            // Bursts become at most one reload a second, and the last change always reloads (EventThrottle).
            guard let self, let delay = self.throttle.event(at: ProcessInfo.processInfo.systemUptime) else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.throttle.fired(at: ProcessInfo.processInfo.systemUptime)
                onChange()
            }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        pending?.cancel()
        throttle.reset()
        source?.cancel()
        source = nil
        url = nil
    }

    deinit { stop() }
}

/// Decides copy versus move for a drag (FE-104, FE-105, FE-112).
enum DropPolicy {
    static func kind(sources: [URL], destination: URL, mask: NSDragOperation) -> TransferKind? {
        let dest = destination.standardizedFileURL
        guard !sources.isEmpty else { return nil }
        if sources.contains(where: { FileOps.isSameOrInside(dest, $0) }) { return nil }
        let canMove = mask.contains(.move) || mask.contains(.generic)
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return mask.contains(.copy) ? .copy : nil }
        if flags.contains(.command) { return canMove ? .move : nil }
        if sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == dest }) { return nil }
        if canMove, sources.allSatisfy({ FileOps.sameVolumeCached($0, dest) }) { return .move }   // asked on every hover move
        return mask.contains(.copy) ? .copy : nil
    }

    static func fileURLs(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

extension NSImage {
    static func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }
}

func displayName(of url: URL) -> String {
    FileManager.default.displayName(atPath: url.path)
}

extension NSAlert {
    static func show(_ message: String, _ info: String = "", style: NSAlert.Style = .warning, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = style
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
