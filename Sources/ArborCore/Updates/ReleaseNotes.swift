import Foundation

/// The notes Sparkle's update window shows, made from one version's section of CHANGELOG.md (FE-259).
public enum ReleaseNotes {
    /// The lines under `## <version>` up to the next `## ` heading; nil when the version has none.
    public static func section(for version: String, in changelog: String) -> String? {
        var lines: [Substring] = []
        var inside = false
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if inside { break }
                inside = trimmed == "## \(version)"
                continue
            }
            if inside { lines.append(line) }
        }
        guard inside else { return nil }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `###` headings, `- ` bullets (indented lines continue them) and paragraphs; `code` spans become
    /// `<code>`. Everything else is text, escaped: links, emphasis and HTML in the changelog show as written.
    public static func html(fromMarkdown markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var item: [String]?
        var inList = false

        func flushItem() {
            if let text = item { out.append("<li>\(inline(text.joined(separator: " ")))</li>") }
            item = nil
        }
        func closeList() {
            flushItem()
            if inList { out.append("</ul>") }
            inList = false
        }
        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph = []
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushItem()
            } else if let heading = heading(line) {
                flushParagraph()
                closeList()
                out.append("<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                flushItem()
                if !inList { out.append("<ul>") }
                inList = true
                item = [String(line.dropFirst(2))]
            } else if item != nil, raw.first == " " || raw.first == "\t" {
                item?.append(line)
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flushParagraph()
        closeList()
        return out.joined(separator: "\n")
    }

    /// `###` is the changelog's group heading; deeper levels keep their own.
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (3...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    /// Escapes the text; text between a pair of backticks becomes `<code>`, and a lone backtick stays one.
    static func inline(_ text: String) -> String {
        let parts = text.components(separatedBy: "`")
        var html = ""
        for (index, part) in parts.enumerated() {
            let isCode = index % 2 == 1 && index < parts.count - 1
            if index % 2 == 1, !isCode { html += "`" }
            html += isCode ? "<code>\(escape(part))</code>" : escape(part)
        }
        return html
    }

    /// The five characters that matter in HTML text and attribute values.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
