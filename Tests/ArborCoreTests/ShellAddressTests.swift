import Foundation
import Testing
@testable import ArborCore

@Suite("Shell names (FE-213)")
struct ShellAddressTests {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private func outcome(_ text: String) -> ShellAddress.Outcome? { ShellAddress.outcome(for: text, homeDirectory: home) }

    private func folder(_ path: String) -> ShellAddress.Outcome { .place(.folder(URL(fileURLWithPath: path, isDirectory: true))) }

    @Test(arguments: [
        ("desktop", "/Users/me/Desktop"), ("downloads", "/Users/me/Downloads"), ("personal", "/Users/me/Documents"),
        ("documents", "/Users/me/Documents"), ("my pictures", "/Users/me/Pictures"), ("pictures", "/Users/me/Pictures"),
        ("my music", "/Users/me/Music"), ("music", "/Users/me/Music"), ("my video", "/Users/me/Movies"),
        ("videos", "/Users/me/Movies"), ("movies", "/Users/me/Movies"), ("profile", "/Users/me"),
        ("userprofiles", "/Users"), ("public", "/Users/Shared"), ("appsfolder", "/Applications"),
        ("appdata", "/Users/me/Library/Application Support"),
    ]) func namesThatAreFolders(_ name: String, _ path: String) {
        #expect(outcome("shell:" + name) == folder(path))
    }

    @Test func namesThatArePlaces() {
        #expect(outcome("shell:recent") == .recentFiles)
        #expect(outcome("shell:recyclebinfolder") == .place(.trash))
        #expect(outcome("shell:mycomputerfolder") == .place(.thisMac))
        #expect(outcome("shell:networkplacesfolder") == .place(.network))
        #expect(outcome("shell:libraries") == .place(.library(LibraryLogic.rootName)))
    }

    @Test func caseWhitespaceAndQuotesDontMatter() {
        let downloads = folder("/Users/me/Downloads")
        #expect(outcome("SHELL:DownLoads") == downloads)
        #expect(outcome("  shell:downloads  ") == downloads)
        #expect(outcome("shell: downloads") == downloads)
        #expect(outcome("\"shell:downloads\"") == downloads)
        #expect(outcome("'shell:downloads'") == downloads)
    }

    /// `URL(fileURLWithPath:)` without `isDirectory:` would stat the path on the main thread.
    @Test(arguments: ["desktop", "appdata", "userprofiles", "public", "appsfolder"])
    func folderURLsNeverDependOnTheDisk(_ name: String) throws {
        let missingHome = URL(fileURLWithPath: "/no/such/home", isDirectory: true)
        guard case .place(.folder(let url))? = ShellAddress.outcome(for: "shell:" + name, homeDirectory: missingHome) else {
            Issue.record("not a folder")
            return
        }
        #expect(url.hasDirectoryPath)
    }

    @Test(arguments: [
        ("start menu", "Start menu"), ("programs", "Applications"), ("common programs", "Applications"), ("sendto", "Send to"),
        ("windows", "no Mac counterpart"), ("system", "no Mac counterpart"), ("programfiles", "no Mac counterpart"),
    ]) func namesWithoutACounterpartExplainWhy(_ name: String, _ reason: String) {
        guard case .noCounterpart(let message)? = outcome("shell:" + name) else {
            Issue.record("\(name) should have no counterpart")
            return
        }
        #expect(message.contains(reason))
    }

    @Test func folderIDsAndEmptyNamesGetTheirOwnMessage() {
        guard case .noCounterpart(let id)? = outcome("shell:::{F874310E-B6B7-47DC-BC84-B9E6B38F5903}") else {
            Issue.record("expected a message")
            return
        }
        #expect(id.contains("folder IDs"))
        guard case .noCounterpart(let empty)? = outcome("shell:") else {
            Issue.record("expected a message")
            return
        }
        #expect(empty.contains("shell:downloads"))
    }

    @Test func unknownNamesAreEchoedBounded() {
        #expect(outcome("shell:nope") == .unknown("nope"))
        let long = String(repeating: "x", count: 500)
        #expect(outcome("shell:" + long) == .unknown(String(repeating: "x", count: 64) + "…"))
        #expect(ShellAddress.unknownNameMessage("nope").contains("nope"))
    }

    @Test(arguments: ["downloads", "~/shell:x", "/shell:downloads", "shelly:downloads", ""])
    func otherTextIsNotAShellAddress(_ text: String) {
        #expect(outcome(text) == nil)
    }

    @Test(arguments: ["cmd", "CMD", "cmd /c dir", "powershell -File x", "pwsh", "wt", "notepad", "calc", "mspaint", "regedit",
                      "control", "taskmgr", "explorer", "setup.exe", "Run.BAT", "a.cmd", "a.ps1", "a.msi", "\"cmd\""])
    func windowsCommands(_ text: String) {
        #expect(ShellAddress.isWindowsCommand(text))
    }

    @Test(arguments: ["open -a Calculator", "ls -la", "my cmd", "commander", "file.txt", "", "   ", "/Users/me/missing-setup.cmd",
                      "/Users/me/a b.exe", "sub/setup.exe", "./setup.exe", "~/setup.exe", "~setup.exe", ".\\setup.exe", "\"/Users/me/a.bat\""])
    func notWindowsCommands(_ text: String) {
        #expect(!ShellAddress.isWindowsCommand(text))
    }

    @Test func theCommandMessageIsBoundedAndTrueForAFolderToo() {
        let message = ShellAddress.commandMessage(for: "cmd " + String(repeating: "x", count: 500))
        #expect(message.contains("doesn't run commands"))
        #expect(message.count < 200)
        #expect(message.contains("…"))
    }

    @Test func aShortCommandIsEchoedWhole() {
        #expect(ShellAddress.commandMessage(for: "cmd /c dir").contains("“cmd /c dir”"))
    }
}
