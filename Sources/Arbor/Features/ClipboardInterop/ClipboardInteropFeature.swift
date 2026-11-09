import AppKit
import ArborCore

/// Stand-ins for another app's clipboard, for scripted checks; a real Finder can't be driven headless (FE-101).
/// `foreignclipboard:/a|/b` writes file URLs for those paths, `foreignclipboardraw:file://x|https://y` writes the text
/// as given, and `log:` adds a `pasteboard:` line with the item count, the first item's types and its text.
enum ClipboardInteropFeature: ExplorerFeature {
    static let id = "clipboard-interop"

    static func register() {
        DebugScript.registerStep("foreignclipboard") { paths, _ in
            writeAsAnotherApp(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)).absoluteString })
            return 0.2
        }
        DebugScript.registerStep("foreignclipboardraw") { strings, _ in
            writeAsAnotherApp(strings.split(separator: "|").map(String.init))
            return 0.2
        }
        DebugScript.registerLogger("clipboard-interop.log") { _ in
            let clipboard = FileClipboard.shared
            let first = clipboard.pasteboard.pasteboardItems?.first
            let types = first?.types.map(\.rawValue).joined(separator: ",") ?? ""
            let text = (first?.string(forType: .string) ?? "").replacingOccurrences(of: "\n", with: " | ")
            return "pasteboard: items=\(clipboard.itemCount) types=[\(types)] text=[\(text)]"
        }
    }

    private static func writeAsAnotherApp(_ strings: [String]) {
        let clipboard = FileClipboard.shared
        clipboard.pasteboard.clearContents()
        clipboard.pasteboard.writeObjects(strings.map { string in
            let item = NSPasteboardItem()
            item.setString(string, forType: .fileURL)
            return item
        })
        clipboard.refresh()
    }
}
