import Foundation
import Testing
@testable import BetterExplorerCore

@Suite("Automation gate for BETTER_EXPLORER_* hooks")
struct AutomationTests {
    @Test func unsignedAndAdHocBuildsKeepHooks() {
        #expect(Automation.allows(teamIdentifier: nil, appleSigned: false, markedDistribution: false))
    }

    @Test func developerIDBuildDropsHooks() {
        #expect(!Automation.allows(teamIdentifier: "ABCDE12345", appleSigned: false, markedDistribution: false))
    }

    @Test func appleSignedTestRunnerKeepsHooks() {
        #expect(Automation.allows(teamIdentifier: "59GAB85EFG", appleSigned: true, markedDistribution: false))
    }

    @Test func markedReleaseDropsHooksEvenWithoutTeamID() {
        #expect(!Automation.allows(teamIdentifier: nil, appleSigned: false, markedDistribution: true))
        #expect(!Automation.allows(teamIdentifier: "59GAB85EFG", appleSigned: true, markedDistribution: true))
    }

    @Test func filterKeepsOnlyBetterExplorerVariables() {
        let env = ["BETTER_EXPLORER_SCRIPT": "quit", "BETTER_EXPLORER_HEADLESS": "1", "HOME": "/Users/x", "PATH": "/bin", "XBETTER_EXPLORER_SCRIPT": "x", "better_explorer_script": "x"]
        #expect(Automation.filter(env, enabled: true) == ["BETTER_EXPLORER_SCRIPT": "quit", "BETTER_EXPLORER_HEADLESS": "1"])
    }

    @Test func filterIsEmptyWhenDisabled() {
        #expect(Automation.filter(["BETTER_EXPLORER_SCRIPT": "quit", "BETTER_EXPLORER_TEST_TRASH": "/tmp/t"], enabled: false).isEmpty)
    }

    @Test func liveEnvironmentIsReadThroughTheGate() {
        // The test runner is not a release, so the gate is open and reads live values.
        #expect(Automation.isEnabled)
        setenv("BETTER_EXPLORER_AUTOMATION_PROBE", "on", 1)
        defer { unsetenv("BETTER_EXPLORER_AUTOMATION_PROBE") }
        #expect(Automation.environment["BETTER_EXPLORER_AUTOMATION_PROBE"] == "on")
        #expect(Automation.environment["PATH"] == nil)
    }

    @Test func noSourceReadsTheEnvironmentDirectly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        // ArchiveTool hands the whole environment to child tools; it reads no BETTER_EXPLORER_* hook.
        let allowed = ["BetterExplorerCore/Automation.swift", "BetterExplorerCore/Archives/ArchiveTool.swift"]
        let files = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
        #expect(files.count > 100, "found the sources")
        var offenders: [String] = []
        for file in files where !allowed.contains(file) {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if ["processInfo.environment", "ProcessInfo().environment", "getenv("].contains(where: code.contains) { offenders.append("\(file):\(number + 1)") }
            }
        }
        #expect(offenders.isEmpty, "read BETTER_EXPLORER_* through Automation.environment: \(offenders)")
    }
}
