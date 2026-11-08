import Foundation
import Testing
@testable import ArborCore

@Suite("Automation gate for ARBOR_* hooks")
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

    @Test func filterKeepsOnlyArborVariables() {
        let env = ["ARBOR_SCRIPT": "quit", "ARBOR_HEADLESS": "1", "HOME": "/Users/x", "PATH": "/bin", "XARBOR_SCRIPT": "x", "arbor_script": "x"]
        #expect(Automation.filter(env, enabled: true) == ["ARBOR_SCRIPT": "quit", "ARBOR_HEADLESS": "1"])
    }

    @Test func filterIsEmptyWhenDisabled() {
        #expect(Automation.filter(["ARBOR_SCRIPT": "quit", "ARBOR_TEST_TRASH": "/tmp/t"], enabled: false).isEmpty)
    }

    @Test func liveEnvironmentIsReadThroughTheGate() {
        // The test runner is not a release, so the gate is open and reads live values.
        #expect(Automation.isEnabled)
        setenv("ARBOR_AUTOMATION_PROBE", "on", 1)
        defer { unsetenv("ARBOR_AUTOMATION_PROBE") }
        #expect(Automation.environment["ARBOR_AUTOMATION_PROBE"] == "on")
        #expect(Automation.environment["PATH"] == nil)
    }

    @Test func noSourceReadsTheEnvironmentDirectly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        // ArchiveTool hands the whole environment to child tools; it reads no ARBOR_* hook.
        let allowed = ["ArborCore/Automation.swift", "ArborCore/Archives/ArchiveTool.swift"]
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
        #expect(offenders.isEmpty, "read ARBOR_* through Automation.environment: \(offenders)")
    }
}
