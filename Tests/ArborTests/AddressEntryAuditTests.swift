import Foundation
import Testing

/// FE-213, SPEC §5.2: nothing typed in the address bar can start anything, so these files must not be able to.
@Suite("Address entry never executes typed text (FE-213)")
struct AddressEntryAuditTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let forbidden = ["Process(", "NSWorkspace", "SystemOpen", "NSAppleScript", "posix_spawn", "system("]

    private static var files: [URL] {
        let feature = root.appendingPathComponent("Sources/Arbor/Features/AddressEntry")
        let inFeature = (try? FileManager.default.contentsOfDirectory(at: feature, includingPropertiesForKeys: nil)) ?? []
        let core = ["PathCompletion.swift", "PathListingQueue.swift", "ShellAddress.swift"].map {
            root.appendingPathComponent("Sources/ArborCore").appendingPathComponent($0)
        }
        return inFeature.filter { $0.pathExtension == "swift" } + core
    }

    @Test func noFileHereCanStartAnything() throws {
        #expect(Self.files.count >= 8)
        var offenders: [String] = []
        for file in Self.files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for word in Self.forbidden where line.contains(word) { offenders.append("\(file.lastPathComponent): \(word)") }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
