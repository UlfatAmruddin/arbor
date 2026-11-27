import Foundation
import Testing

/// The published documents must keep up with the requirements and with what the app actually does.
@Suite("Status list and privacy statements (FE-234, FE-222)")
struct StatusDocumentTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Cells of a Markdown table row, trimmed; nil for any other line.
    static func cells(_ line: String) -> [String]? {
        guard line.hasPrefix("|") else { return nil }
        return line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func requirementNumber(_ cell: String) -> Int? {
        cell.hasPrefix("FE-") ? Int(cell.dropFirst(3)) : nil
    }

    static let statuses = ["implemented", "partial", "macOS boundary", "not done"]

    @Test func everySpecRequirementHasExactlyOneStatusRow() throws {
        let spec = try Self.text("docs/SPEC.md").components(separatedBy: "\n")
            .compactMap { Self.cells($0)?.first.flatMap(Self.requirementNumber) }
        let status = try Self.text("docs/FEATURE-STATUS.md").components(separatedBy: "\n")
            .compactMap { Self.cells($0)?.first.flatMap(Self.requirementNumber) }
        #expect(spec.count > 200, "read the requirement tables")
        #expect(Set(status).count == status.count, "no requirement is listed twice")
        #expect(Set(status) == Set(spec), "missing: \(Set(spec).subtracting(status).sorted()), extra: \(Set(status).subtracting(spec).sorted())")
    }

    @Test func summaryCountsAndHighestIDMatchTheRows() throws {
        let lines = try Self.text("docs/FEATURE-STATUS.md").components(separatedBy: "\n")
        var section = ""
        var rows: [(area: String, id: Int, status: String)] = []
        var summary: [String: Int] = [:]
        var areas: [String: [Int]] = [:]
        for line in lines {
            if line.hasPrefix("## ") { section = String(line.dropFirst(3)); continue }
            guard let cells = Self.cells(line), cells.count >= 2 else { continue }
            if let id = Self.requirementNumber(cells[0]), cells.count >= 3 {
                rows.append((section, id, cells[2]))
            } else if section == "Summary", let count = Int(cells[1]) {
                if cells.count == 2 { summary[cells[0]] = count } else { areas[cells[0]] = cells.dropFirst().compactMap { Int($0) } }
            }
        }
        for row in rows { #expect(Self.statuses.contains(row.status), "FE-\(row.id): unknown status \(row.status)") }
        for status in Self.statuses {
            #expect(summary[status] == rows.filter { $0.status == status }.count, "summary count for \(status)")
        }
        let total = lines.compactMap(Self.cells).first { $0.first == "**total**" }?.last
        #expect(total == "**\(rows.count)**", "summary total")
        let sections = Set(rows.map(\.area))
        #expect(Set(areas.keys) == sections, "one summary row per area")
        for area in sections {
            let counts = Self.statuses.map { status in rows.filter { $0.area == area && $0.status == status }.count }
            #expect(areas[area] == counts, "summary row for \(area)")
        }
        let highest = try #require(rows.map(\.id).max())
        #expect(lines.contains { $0.contains("IDs run to FE-\(highest) ") }, "the introduction names FE-\(highest) as the highest ID")
    }

    /// Release builds check for updates (FE-259), so no privacy statement may claim there is no request at all.
    @Test func privacyStatementsNameTheUpdateCheck() throws {
        let readme = try Self.text("README.md")
        let start = try #require(readme.range(of: "\n## Privacy\n"))
        let privacy = readme[start.upperBound...].components(separatedBy: "\n## ").first ?? ""
        #expect(privacy.contains("docs/features/updates.md"), "README's Privacy section links the update check")
        #expect(try Self.text("SECURITY.md").contains("docs/features/updates.md"), "SECURITY.md's scope names the update check")
        let row = try Self.text("docs/FEATURE-STATUS.md").components(separatedBy: "\n").first { $0.hasPrefix("| FE-222 |") }
        #expect(row?.contains("features/updates.md") == true, "the FE-222 note links the update check")
        for statement in [privacy, try Self.text("SECURITY.md")] {
            #expect(!statement.contains("no network connections of its own"))
        }
    }
}
