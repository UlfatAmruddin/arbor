import AppKit
import ArborCore

/// Script steps for the headless checks (TESTING.md). Services themselves need a logged-in GUI; see docs/features/qa-core.md.
enum ServicesDebug {
    private static var lastError = "-"

    static func register() {
        // serviceopen:/a|/b — delivers these paths to the provider on a private pasteboard; empty sends nothing.
        DebugScript.registerStep("serviceopen") { paths, _ in
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls(paths) as [NSURL])
            var message: NSString = "-"
            ServicesProvider.shared.openInArbor(pasteboard, userData: nil, error: &message)
            lastError = message as String
            return 1.5
        }

        // servicestale:/a — the same route with a deadline that has already passed.
        DebugScript.registerStep("servicestale") { paths, _ in
            (NSApp.delegate as? AppDelegate)?.openExternal(urls(paths), staleAfter: 0)
            return 1.0
        }

        // serviceclick:<row> — the Details list's right-click path up to the menu.
        DebugScript.registerStep("serviceclick") { row, window in
            guard let table = (window?.itemView as? DetailsViewController)?.table, let row = Int(row), let host = table.window else { return nil }
            let point = table.convert(NSPoint(x: table.rect(ofRow: row).midX, y: table.rect(ofRow: row).midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
            _ = table.menu(for: event)
            return 0.3
        }

        // serviceprobe:/path — what AppKit would be told: the requestor's answers, the URLs written, per-menu permission.
        DebugScript.registerStep("serviceprobe") { path, window in
            guard let window else { return nil }
            ConsistencyDebug.append(probe(window), to: path)
            return 0.2
        }

        DebugScript.registerLogger("services.log") { _ in "service error: \(lastError)" }
    }

    private static func urls(_ paths: String) -> [URL] {
        paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
    }

    private static func probe(_ window: BrowserWindowController) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func written(_ type: NSPasteboard.PasteboardType) -> String {
            guard window.writeSelection(to: pasteboard, types: [type]) else { return "" }
            return (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).map(\.lastPathComponent).joined(separator: " | ")
        }
        let tree = (window.navPane.outline.item(atRow: 0) as? NavNode).flatMap { window.navigationPaneMenu(for: $0) }
        let header = (window.itemView as? DetailsViewController)?.table.headerView?.menu
        return ["requestor file: \(window.validRequestor(forSendType: .fileURL, returnType: nil) != nil)",
                "requestor text: \(window.validRequestor(forSendType: .string, returnType: nil) != nil)",
                "requestor returning: \(window.validRequestor(forSendType: .fileURL, returnType: .fileURL) != nil)",
                "written: \(written(.fileURL))",
                "written legacy: \(written(ServicesSelection.legacyFilenames))",
                "plugins item: \(window.contextMenu(for: .itemContextMenu).allowsContextMenuPlugIns)",
                "plugins background: \(window.contextMenu(for: .backgroundContextMenu).allowsContextMenuPlugIns)",
                "plugins tree: \(tree?.allowsContextMenuPlugIns.description ?? "none")",
                "plugins tab: \(window.tabStripMenu(for: 0)?.allowsContextMenuPlugIns.description ?? "none")",
                "plugins header: \(header?.allowsContextMenuPlugIns.description ?? "none")",
                "services menu: \(NSApp.servicesMenu != nil)",
                "---", ""].joined(separator: "\n")
    }
}
