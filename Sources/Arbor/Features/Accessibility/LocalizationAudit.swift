import AppKit
import ArborCore

/// Scripted localization check (FE-204). Run with `ARBOR_PSEUDO_LOC=1`: `l10naudit:/path` appends every piece
/// of visible text in every open window (labels, buttons, placeholders, pop-up and segment titles, table
/// headers, tab labels, tooltips, accessibility labels and help) that did not come from the string table, and
/// every label or button whose text doesn't fit its frame. Names of files, folders and volumes are skipped:
/// they are never translated.
///
///     plain: NSTextField "Size on disk:"
///     clipped: NSButton "[Ŕéšţöŕé ðéƒáüļţš·····]" needs 182 has 150
///     l10naudit: 2 windows, 148 strings, 1 plain, 0 clipped
enum LocalizationAudit {
    static func register() {
        DebugScript.registerStep("l10naudit") { path, controller in
            AccessibilityDebug.append(report(controller), to: path)
            return 0.3
        }
    }

    static func report(_ controller: BrowserWindowController?) -> String {
        var names = Set<String>()
        if let controller {
            // Names and type descriptions come from the file system and Launch Services (already in the
            // user's language).
            controller.visibleItems.forEach { names.insert($0.name); names.insert($0.typeDescription) }
            controller.location.folderURL?.pathComponents.forEach { names.insert($0) }
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for url in [home, URL(fileURLWithPath: "/Applications")] + ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []) {
            names.insert(url.lastPathComponent)
            names.insert(fm.displayName(atPath: url.path))
        }
        if let computer = Host.current().localizedName { names.insert(computer) }
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? [])
            .forEach { url in
                names.insert(url.lastPathComponent)
                if let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName { names.insert(name) }
            }
        FileManager.default.homeDirectoryForCurrentUser.pathComponents.forEach { names.insert($0) }
        names.insert(NSFullUserName())

        var audit = Audit(names: names)
        let windows = NSApp.windows.filter { window in
            window.contentView != nil && !(window.className.contains("Menu")) && (window.isVisible || AppDelegate.isHeadless)
                && window.className != "NSStatusBarWindow"
        }
        for window in windows {
            if !window.title.isEmpty { audit.check(window.title, source: "window title") }
            if let content = window.contentView { audit.walk(content) }
        }
        var lines = audit.findings
        lines.append("l10naudit: \(windows.count) windows, \(audit.seen) strings, \(audit.plainCount) plain, \(audit.clippedCount) clipped")
        return lines.joined(separator: "\n") + "\n"
    }

    struct Audit {
        let names: Set<String>
        var findings: [String] = []
        var seen = 0
        var plainCount = 0
        var clippedCount = 0
        private var reported = Set<String>()

        init(names: Set<String>) { self.names = names }

        mutating func walk(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.01 || AppDelegate.isHeadless else { return }
            let kind = String(describing: type(of: view))
            if let field = view as? NSTextField {
                if field.isEditable {
                    check(field.placeholderString, source: kind + " placeholder")
                } else {
                    check(field.stringValue, source: kind)
                    checkClipping(field, text: field.stringValue, kind: kind)
                }
            } else if let popUp = view as? NSPopUpButton {
                popUp.itemArray.forEach { check($0.title, source: kind + " item") }
            } else if let button = view as? NSButton {
                if button.imagePosition != .imageOnly {
                    check(button.title, source: kind)
                    checkClipping(button, text: button.title, kind: kind)
                }
            } else if let segments = view as? NSSegmentedControl {
                (0..<segments.segmentCount).forEach { check(segments.label(forSegment: $0), source: kind + " segment") }
            } else if let tabs = view as? NSTabView {
                tabs.tabViewItems.forEach { check($0.label, source: kind + " tab") }
            }
            if let table = view as? NSTableView, table.headerView != nil {
                table.tableColumns.filter { !$0.isHidden }.forEach { check($0.headerCell.stringValue, source: kind + " header") }
            }
            check(view.toolTip, source: kind + " tooltip")
            if view.isAccessibilityElement() {
                check(view.accessibilityLabel(), source: kind + " label")
                check(view.accessibilityHelp(), source: kind + " help")
            }
            view.subviews.forEach { walk($0) }
        }

        mutating func check(_ text: String?, source: String) {
            guard let text, !text.isEmpty else { return }
            seen += 1
            guard Self.hasPlainText(text, names: names), reported.insert(source + text).inserted else { return }
            plainCount += 1
            findings.append("plain: \(source) \"\(text.replacingOccurrences(of: "\n", with: "\\n"))\"")
        }

        mutating func checkClipping(_ control: NSControl, text: String, kind: String) {
            guard !text.isEmpty, let cell = control.cell, control.bounds.width > 0 else { return }
            // Paths, names and table cells shorten with an ellipsis by design (DEC-013); that isn't clipping.
            if control is NSTextField, [.byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail].contains(cell.lineBreakMode) { return }
            let wraps = cell.wraps || (control as? NSTextField)?.maximumNumberOfLines != 1 && cell.lineBreakMode == .byWordWrapping
            if wraps {
                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: control.bounds.width, height: .greatestFiniteMagnitude)).height
                if needed > control.bounds.height + 1.5 { clipped(kind, text, "height \(Int(needed))", "\(Int(control.bounds.height))") }
            } else {
                let needed = cell.cellSize.width
                if needed > control.bounds.width + 1.5 { clipped(kind, text, "\(Int(needed))", "\(Int(control.bounds.width))") }
            }
        }

        private mutating func clipped(_ kind: String, _ text: String, _ needs: String, _ has: String) {
            guard reported.insert("clip" + kind + text).inserted else { return }
            clippedCount += 1
            findings.append("clipped: \(kind) \"\(text.replacingOccurrences(of: "\n", with: "\\n"))\" needs \(needs) has \(has)")
        }

        /// Text with Latin letters outside pseudo-localized segments, that isn't a name, path or number.
        static func hasPlainText(_ text: String, names: Set<String>) -> Bool {
            var rest = text
            // Remove "[…·]" segments (pseudo-localized text) and quoted names (“…”).
            for pattern in [#"\[[^\[\]]*·\]"#, #"“[^”]*”"#, #""[^"]*""#] {
                rest = rest.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            }
            for name in names.sorted(by: { $0.count > $1.count }) where name.count > 1 {
                rest = rest.replacingOccurrences(of: name, with: " ")
            }
            // Dates and times are formatted by the system in the user's language.
            if let detector = Self.dates {
                for match in detector.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)).reversed() {
                    if let range = Range(match.range, in: rest) { rest.replaceSubrange(range, with: " ") }
                }
            }
            for word in rest.split(whereSeparator: { $0.isWhitespace }) {
                let token = String(word)
                if token.contains("/") || token.contains("\\") || token.contains("@") { continue }   // paths, addresses
                if token.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) == nil { continue }
                if Self.allowed.contains(token.trimmingCharacters(in: .punctuationCharacters)) { continue }
                return true
            }
            return false
        }

        private static let dates = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

        /// Units, file-system, format and product names that stay as they are in every language.
        static let allowed: Set<String> = ["KB", "MB", "GB", "TB", "PB", "APFS", "HFS", "ExFAT", "FAT32", "SMB", "AFP", "NFS", "WebDAV",
                                           "Arbor", "macOS", "iCloud", "AirDrop", "ZIP", "TAR", "ACL", "POSIX", "AM", "PM", "px",
                                           "gzip", "xz", "BZip2", "LZMA", "LZMA2", "TextEdit"]
    }
}
