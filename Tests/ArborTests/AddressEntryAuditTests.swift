import Foundation
import Testing

/// FE-213, SPEC §5.2: nothing typed in the address bar can start anything, so these files must not be able to.
@Suite("Address entry never executes typed text (FE-213)")
struct AddressEntryAuditTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let forbidden = ["Process(", "NSWorkspace", "SystemOpen", "NSAppleScript", "posix_spawn", "system("]

    /// Not recursive: `Handoff/` holds the launcher, which `theLauncherTakesNoText` covers instead.
    private static var files: [URL] {
        let feature = root.appendingPathComponent("Sources/Arbor/Features/AddressEntry")
        let inFeature = (try? FileManager.default.contentsOfDirectory(at: feature, includingPropertiesForKeys: nil)) ?? []
        let core = ["PathCompletion.swift", "PathListingQueue.swift", "ShellAddress.swift", "AddressHandoff.swift"].map {
            root.appendingPathComponent("Sources/ArborCore").appendingPathComponent($0)
        }
        return inFeature.filter { $0.pathExtension == "swift" } + core
    }

    private static func code(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test func noFileHereCanStartAnything() throws {
        #expect(Self.files.count >= 8)
        var offenders: [String] = []
        for file in Self.files {
            for line in try Self.code(file) {
                for word in Self.forbidden where line.contains(word) { offenders.append("\(file.lastPathComponent): \(word)") }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// One entry point, whose only inputs are the closed target and the window.
    @Test func theLauncherTakesNoText() throws {
        let launcher = Self.root.appendingPathComponent("Sources/Arbor/Features/AddressEntry/Handoff/AddressHandoffLauncher.swift")
        let lines = try Self.code(launcher)
        #expect(lines.filter { $0.contains("func ") } == [
            "    static func launch(_ target: AddressHandoffTarget, in window: BrowserWindowController) -> Bool {",
        ])
        #expect(!lines.contains { $0.contains("String") })
        #expect(!lines.contains { $0.contains("Process(") || $0.contains("NSWorkspace") || $0.contains("NSAppleScript") })
    }

    /// No raw value here, and `CaseIterable` won't compile with a payload, so the target can hold nothing typed.
    @Test func theTargetCarriesNoText() throws {
        let core = Self.root.appendingPathComponent("Sources/ArborCore/AddressHandoff.swift")
        #expect(try Self.code(core).contains("public enum AddressHandoffTarget: CaseIterable, Sendable {"))
    }
}
