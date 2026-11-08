import AppKit
import ArborCore

/// Read-only Previous Versions copies, removed when the app showing them quits (or at once if opening fails).
enum VersionCopies {
    /// Copy folders by the pid of the app showing them (main thread).
    private static var shown: [pid_t: [URL]] = [:]
    private static var installed = false

    /// Opens `file` (inside its own `folder` in `TemporaryFiles.versionsFolder`) in its default app.
    static func open(_ file: URL, in folder: URL) {
        SystemOpen.open(file) { app, _ in
            DispatchQueue.main.async { opened(folder, in: app) }
        }
    }

    /// Notes which app shows the copy in `folder`; nil (not opened) removes it.
    static func opened(_ folder: URL, in app: NSRunningApplication?) {
        install()
        guard let app, !app.isTerminated else { return remove([folder]) }
        shown[app.processIdentifier, default: []].append(folder)
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let folders = shown.removeValue(forKey: app.processIdentifier) else { return }
            remove(folders)
        }
    }

    private static func remove(_ folders: [URL]) {
        DispatchQueue.global(qos: .utility).async { folders.forEach(TemporaryFiles.removeTree) }
    }
}
