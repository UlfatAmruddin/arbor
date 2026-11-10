// Checks translated string tables and writes the pseudo-languages. Run through scripts/extract-strings.sh,
// which compiles this file with the ArborCore sources it needs.
import Foundation

@main
enum StringTables {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch (arguments.first, arguments.count) {
            case ("check", 2): exit(try check(URL(fileURLWithPath: arguments[1])) ? 0 : 1)
            case ("pseudo", 3): try pseudo(base: URL(fileURLWithPath: arguments[1]), into: URL(fileURLWithPath: arguments[2]))
            default: fail("usage: string-tables check <resources> | pseudo <English table> <resources>")
            }
        } catch {
            fail("\(error)")
        }
    }

    private static func check(_ resources: URL) throws -> Bool {
        var passed = true
        for report in try StringTableCheck.check(resources: resources) {
            report.errors.forEach { fputs("\(report.language).lproj: \($0)\n", stderr) }
            if !report.errors.isEmpty { passed = false }
            print("\(report.language).lproj: \(report.errors.count) errors, \(report.missing) strings not translated yet")
        }
        return passed
    }

    private static func pseudo(base: URL, into resources: URL) throws {
        let english = try StringTableCheck.parse(base)
        let plurals = try PluralTable.parse(base.deletingLastPathComponent().appendingPathComponent(PluralTable.tableName))
        for style in PseudoLocalization.Style.allCases {
            let folder = resources.appendingPathComponent("\(style.rawValue).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PseudoLocalization.table(from: english, style: style)
                .write(to: folder.appendingPathComponent(StringTableCheck.tableName), atomically: true, encoding: .utf8)
            try PluralTable.data(PseudoLocalization.plurals(from: plurals, style: style))
                .write(to: folder.appendingPathComponent(PluralTable.tableName))
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("\(message)\n", stderr)
        exit(2)
    }
}
