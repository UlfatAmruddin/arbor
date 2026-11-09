import Foundation
import Testing
@testable import ArborCore

@Suite("Address hand-offs (FE-213)")
struct AddressHandoffTests {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private func shell(_ name: String) -> ShellAddress.Outcome? { ShellAddress.outcome(for: "shell:" + name, homeDirectory: home) }

    @Test(arguments: [
        ("control", AddressHandoffTarget.systemSettings), ("control.exe", .systemSettings), ("cmd", .terminal), ("cmd.exe", .terminal),
        ("powershell", .terminal), ("powershell.exe", .terminal), ("pwsh", .terminal), ("pwsh.exe", .terminal), ("wt", .terminal),
        ("wt.exe", .terminal), ("taskmgr", .activityMonitor), ("taskmgr.exe", .activityMonitor),
    ]) func everyCommandWord(_ word: String, _ target: AddressHandoffTarget) {
        #expect(ShellAddress.commandOutcome(for: word) == .handoff(target))
        #expect(ShellAddress.commandOutcome(for: word.uppercased()) == .handoff(target))
        #expect(ShellAddress.commandOutcome(for: "  \"\(word)\"  ") == .handoff(target))
    }

    @Test(arguments: [
        ("controlpanelfolder", AddressHandoffTarget.systemSettings), ("printersfolder", .printersAndScanners), ("connectionsfolder", .network),
        ("startup", .loginItems), ("common startup", .loginItems), ("fonts", .fontBook),
    ]) func everyShellName(_ name: String, _ target: AddressHandoffTarget) {
        #expect(shell(name) == .handoff(target))
        #expect(shell(name.uppercased()) == .handoff(target))
    }

    /// The two tests above must grow with the table.
    @Test func theTableIsFullyCovered() {
        #expect(AddressHandoffTarget.table.flatMap(\.words).count == 12)
        #expect(AddressHandoffTarget.table.flatMap(\.shellNames).count == 6)
        #expect(Set(AddressHandoffTarget.table.map(\.target)) == Set(AddressHandoffTarget.allCases))
    }

    @Test func noNameIsListedTwice() {
        let words = AddressHandoffTarget.table.flatMap(\.words)
        #expect(Set(words).count == words.count)
        let names = AddressHandoffTarget.table.flatMap(\.shellNames)
        #expect(Set(names).count == names.count)
    }

    @Test(arguments: ["cmd /c zqzq", "control zqzq", "powershell -File zqzq.ps1", "pwsh -c zqzq", "wt new-tab zqzq", "taskmgr /zqzq",
                      "\"cmd /c zqzq\"", "cmd\tzqzq", "cmd\nzqzq", "cmd.exe /c zqzq", "CONTROL zqzq"]) func extraTextIsRefusedAndNotRepeated(_ text: String) {
        guard case .refused(let message)? = ShellAddress.commandOutcome(for: text) else {
            Issue.record("\(text) should be refused")
            return
        }
        #expect(message.contains("doesn't pass typed text"))
        #expect(!message.contains("zqzq"))
    }

    @Test func extraTextAfterAShellNameIsNotThatName() {
        #expect(shell("fonts extra") == .unknown("fonts extra"))
        #expect(shell("controlpanelfolder /x") == .unknown("controlpanelfolder /x"))
    }

    @Test(arguments: ["notepad", "calc", "mspaint", "regedit", "explorer", "setup.exe", "notepad foo"]) func wordsWithNoMacToolKeepTheirMessage(_ word: String) {
        guard case .refused(let message)? = ShellAddress.commandOutcome(for: word) else {
            Issue.record("\(word) should be refused")
            return
        }
        #expect(message.contains("doesn't run commands"))
    }

    @Test(arguments: ["commander", "controls", "cmd-nope", "cmdx", "/Users/me/cmd", "~/cmd", "./wt", "sub\\wt", "open -a Calculator", ""])
    func otherTextIsNotACommand(_ text: String) {
        #expect(ShellAddress.commandOutcome(for: text) == nil)
    }

    @Test func routesAreConstantsOfTheExpectedKind() throws {
        for target in AddressHandoffTarget.allCases {
            switch target.route {
            case .application(let identifier): #expect(identifier.hasPrefix("com.apple."))
            case .settingsPane(let url):
                #expect(url.scheme == "x-apple.systempreferences")
                #expect(!url.isFileURL)
            case .terminalAtCurrentFolder: #expect(target == .terminal)
            }
        }
        #expect(AddressHandoffTarget.systemSettings.route == .application(bundleIdentifier: "com.apple.systempreferences"))
        #expect(AddressHandoffTarget.fontBook.route == .application(bundleIdentifier: "com.apple.FontBook"))
        #expect(AddressHandoffTarget.activityMonitor.route == .application(bundleIdentifier: "com.apple.ActivityMonitor"))
    }

    @Test(arguments: [
        (AddressHandoffTarget.systemSettings, "System Settings"), (.printersAndScanners, "System Settings"), (.network, "System Settings"),
        (.loginItems, "System Settings"), (.fontBook, "Font Book"), (.terminal, "Terminal"), (.activityMonitor, "Activity Monitor"),
    ]) func thePromptNamesTheApp(_ target: AddressHandoffTarget, _ app: String) {
        let prompt = target.prompt(folder: nil)
        #expect(prompt.title == "Open \(app)?")
        #expect(prompt.confirmTitle == "Open \(app)")
        #expect(prompt.message.contains(app))
        #expect(prompt.message.contains("Nothing you typed"))
    }

    @Test(arguments: [(AddressHandoffTarget.printersAndScanners, "Printers & Scanners"), (.network, "Network"), (.loginItems, "Login Items")])
    func aPanePromptNamesThePane(_ target: AddressHandoffTarget, _ pane: String) {
        #expect(target.prompt(folder: nil).message.contains("at \(pane)."))
    }

    @Test func theTerminalPromptNamesTheFolderSafely() {
        let plain = AddressHandoffTarget.terminal.prompt(folder: URL(fileURLWithPath: "/Users/me/Work", isDirectory: true))
        #expect(plain.message.contains("in “/Users/me/Work”"))
        let hostile = AddressHandoffTarget.terminal.prompt(folder: URL(fileURLWithPath: "/a\n\u{202E}b", isDirectory: true))
        #expect(hostile.message.contains("/ab"))
        #expect(!hostile.message.contains("\n"))
    }

    @Test func aFolderIsNotNamedForOtherTargets() {
        #expect(!AddressHandoffTarget.fontBook.prompt(folder: URL(fileURLWithPath: "/Users/me/Work", isDirectory: true)).message.contains("/Users/me"))
    }

    @Test func terminalStartsOnlyInARealFolder() {
        #expect(AddressHandoffTarget.terminalRefusal(in: .folder(home)) == nil)
    }

    @Test func virtualPlacesSayWhyTerminalCantStart() {
        let archive = Location.archive(URL(fileURLWithPath: "/Users/me/a.zip"), innerPath: "x")
        #expect(AddressHandoffTarget.terminalRefusal(in: archive)?.contains("archive") == true)
        #expect(AddressHandoffTarget.terminalRefusal(in: .trash)?.contains("Trash") == true)
        #expect(AddressHandoffTarget.terminalRefusal(in: .network)?.contains("network place") == true)
        for place: Location in [.home, .thisMac, .gallery, .library("Documents"), .search(SearchRequest(query: "x"))] {
            #expect(AddressHandoffTarget.terminalRefusal(in: place)?.contains("real folder") == true)
        }
    }
}
