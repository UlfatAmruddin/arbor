import Foundation

/// The Mac tools a Windows word or `shell:` name may open (FE-213); a closed set with no text in it, so nothing typed can reach a launch.
public enum AddressHandoffTarget: CaseIterable, Sendable {
    case systemSettings, printersAndScanners, network, loginItems, fontBook, terminal, activityMonitor

    /// How the app starts a target. Every value is a constant from this file.
    public enum Route: Equatable, Sendable {
        case application(bundleIdentifier: String)
        case settingsPane(URL)
        case terminalAtCurrentFolder
    }

    /// Exact matches only, so anything after a word is never mistaken for part of it.
    static let table: [(words: [String], shellNames: [String], target: AddressHandoffTarget)] = [
        (["control", "control.exe"], ["controlpanelfolder"], .systemSettings),
        ([], ["printersfolder"], .printersAndScanners),
        ([], ["connectionsfolder"], .network),
        ([], ["startup", "common startup"], .loginItems),
        ([], ["fonts"], .fontBook),
        (["cmd", "cmd.exe", "powershell", "powershell.exe", "pwsh", "pwsh.exe", "wt", "wt.exe"], [], .terminal),
        (["taskmgr", "taskmgr.exe"], [], .activityMonitor),
    ]

    public static func forWord(_ word: String) -> AddressHandoffTarget? {
        let key = word.lowercased()
        return table.first { $0.words.contains(key) }?.target
    }

    public static func forShellName(_ name: String) -> AddressHandoffTarget? {
        let key = name.lowercased()
        return table.first { $0.shellNames.contains(key) }?.target
    }

    public var route: Route {
        switch self {
        case .systemSettings: return .application(bundleIdentifier: "com.apple.systempreferences")
        case .printersAndScanners: return Self.pane("com.apple.Print-Scan-Settings.extension")
        case .network: return Self.pane("com.apple.Network-Settings.extension")
        case .loginItems: return Self.pane("com.apple.LoginItems-Settings.extension")
        case .fontBook: return .application(bundleIdentifier: "com.apple.FontBook")
        case .terminal: return .terminalAtCurrentFolder
        case .activityMonitor: return .application(bundleIdentifier: "com.apple.ActivityMonitor")
        }
    }

    private static func pane(_ id: String) -> Route { .settingsPane(URL(string: "x-apple.systempreferences:" + id)!) }

    public var appName: String {
        switch self {
        case .systemSettings, .printersAndScanners, .network, .loginItems: return L10n.tr("System Settings")
        case .fontBook: return L10n.tr("Font Book")
        case .terminal: return L10n.tr("Terminal")
        case .activityMonitor: return L10n.tr("Activity Monitor")
        }
    }

    private var paneName: String? {
        switch self {
        case .printersAndScanners: return L10n.tr("Printers & Scanners")
        case .network: return L10n.tr("Network")
        case .loginItems: return L10n.tr("Login Items")
        default: return nil
        }
    }

    /// `folder` is where Terminal will start; it comes from the window, never from the typed text.
    public func prompt(folder: URL?) -> AddressHandoffPrompt {
        let message: String
        if self == .terminal, let folder {
            message = L10n.format("Arbor will open %@ in “%@”. Nothing you typed is passed to it.", appName, UntrustedText.display(folder.path))
        } else if let paneName {
            message = L10n.format("Arbor will open %@ at %@. Nothing you typed is passed to it.", appName, paneName)
        } else {
            message = L10n.format("Arbor will open %@. Nothing you typed is passed to it.", appName)
        }
        return AddressHandoffPrompt(title: L10n.format("Open %@?", appName), message: message, confirmTitle: L10n.format("Open %@", appName))
    }

    /// Why Terminal can't start at `location`; nil for a real folder.
    public static func terminalRefusal(in location: Location) -> String? {
        switch location {
        case .folder: return nil
        case .archive: return L10n.tr("Terminal can't open inside an archive. Extract it to a folder first.")
        case .trash: return L10n.tr("Terminal can't open in the Trash, which isn't one folder on this Mac.")
        case .network, .server: return L10n.tr("Terminal can't open here, because this network place isn't a folder on this Mac. Open a connected share first.")
        case .home, .thisMac, .gallery, .search, .library: return L10n.tr("Terminal needs a real folder. Go to one first, then try again.")
        }
    }
}

/// The one question asked before a hand-off.
public struct AddressHandoffPrompt: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmTitle: String
}
