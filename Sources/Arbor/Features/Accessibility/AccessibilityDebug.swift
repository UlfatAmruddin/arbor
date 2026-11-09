import AppKit
import ArborCore

/// Script steps for keyboard, pointer and accessibility checks (TESTING.md):
///
///     axdump:/path          append the window's accessibility hierarchy (what VoiceOver sees)
///     key:shift+F10         send a key through the same path as the keyboard (monitor, then window)
///     keyrepeat:return      the same key, as the auto-repeat of a held key
///     focus:/path           append the focused region and view
///     mouse:3               mouse button 4 (Back; AppKit numbers it 3) or 4 (Forward)
///     swipe:back|forward    a completed trackpad swipe
///     compose:か            put marked (uncommitted) input-method text in the focused text field
///     announcements:/path   append VoiceOver announcements made so far
///     contextkey:/path      append the last menu the context-menu key opened
///     textsize:130          set View ▸ Text size
enum AccessibilityDebug {
    static func register() {
        DebugScript.registerStep("axdump") { path, c in
            guard let window = c?.window else { return 0.5 }
            append(AXDump.dump(window) + "---\n", to: path)
            return 0.5
        }
        DebugScript.registerStep("key") { spec, c in send(spec, to: c, isRepeat: false) }
        DebugScript.registerStep("keyrepeat") { spec, c in send(spec, to: c, isRepeat: true) }
        // `key:` reaches the browsing window; a sheet's own key equivalents need its window.
        DebugScript.registerStep("sheetkey") { spec, c in
            guard let sheet = c?.window?.attachedSheet, let event = keyEvent(spec, window: sheet) else {
                NSLog("DebugScript: no sheet or bad key %@", spec)
                return 0.5
            }
            sheet.sendEvent(event)
            return 0.6
        }
        DebugScript.registerStep("focus") { path, c in
            guard let c else { return 0.3 }
            let view = FocusRegions.focusedView(in: c.window)
            let region = FocusRegions.current(in: c)?.rawValue ?? "none"
            var detail = view.map { String(describing: type(of: $0)) } ?? "window"
            if let button = view as? ChromeButton { detail += " \"\(button.accessibilityLabel() ?? button.title)\"" }
            if let tab = view as? TabItemView { detail += " \"\(tab.item.title)\" index=\(tab.index + 1)" }
            if let outline = view as? NSOutlineView, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? NavNode {
                detail += " row=\"\(node.title)\" expanded=\(outline.isItemExpanded(node))"
            }
            if let grid = view as? ItemGridView {
                detail += " focus=\(grid.selection.focus.map { grid.items[$0].name } ?? "-") selected=\(grid.selectedItems.map(\.name).joined(separator: "|"))"
            }
            append("focus: region=\(region) view=\(detail) tab=\(c.activeIndex + 1) location=\(c.location.key)\n", to: path)
            return 0.3
        }
        DebugScript.registerStep("mouse") { arg, c in
            guard let c, let button = Int(arg), let window = c.window,
                  let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                   mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center) else { return 0.5 }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: cg), event.buttonNumber == button {
                if !PointerNavigation.handleButton(event) { NSLog("DebugScript: mouse button \(button) not handled") }
            } else {
                PointerNavigation.navigate(c, button: button)
            }
            return 1
        }
        DebugScript.registerStep("swipe") { arg, c in
            guard let c else { return 0.5 }
            PointerNavigation.go(arg == "forward" ? .forward : .back, in: c)
            return 1
        }
        DebugScript.registerStep("compose") { text, c in
            if let editor = c?.window?.firstResponder as? NSTextView {
                editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            } else if let input = listTextInput(c) {
                input.scriptCompose(text)   // type-to-select in the file list (FE-068)
            }
            return 0.4
        }
        // composecommit:かな — the input method commits text typed into the file list.
        DebugScript.registerStep("composecommit") { text, c in
            listTextInput(c)?.scriptCommit(text)
            return 0.4
        }
        DebugScript.registerStep("announcements") { path, _ in
            append("announcements: " + Announcer.recent.joined(separator: " | ") + "\n", to: path)
            return 0.2
        }
        DebugScript.registerStep("contextkey") { path, _ in
            if let shown = ContextMenuKey.lastShown {
                append("context menu (\(shown.view) at \(Int(shown.point.x)),\(Int(shown.point.y))): " + shown.titles.joined(separator: " | ") + "\n", to: path)
            } else {
                append("context menu: none\n", to: path)
            }
            ContextMenuKey.lastShown = nil
            return 0.2
        }
        DebugScript.registerStep("textsize") { arg, _ in
            if let level = Int(arg).flatMap(TextSizeLevel.init) { TextSize.level = level }
            return 0.8
        }
        DebugScript.registerLogger("accessibility.log") { c in
            "accessibility: focus=\(FocusRegions.current(in: c)?.rawValue ?? "none") textSize=\(TextSize.level.rawValue)"
                + " typeSelect=\(listTextInput(c)?.debugText ?? "-")"
                + ((c.window?.firstResponder as? FileTableView).map { " detailsFocus=\($0.focusRow.map(String.init) ?? "-")" } ?? "")
                + " contrast=\(Theme.increasedContrast) rtl=\(NSApp.userInterfaceLayoutDirection == .rightToLeft) pseudo=\(L10n.pseudo)"
        }
    }

    private static func send(_ spec: String, to c: BrowserWindowController?, isRepeat: Bool) -> TimeInterval {
        guard let window = c?.window, let event = keyEvent(spec, window: window, isRepeat: isRepeat) else {
            NSLog("DebugScript: bad key \(spec)")
            return 0.5
        }
        if !KeyboardRouter.handle(event) { window.sendEvent(event) }
        return 0.6
    }

    static func keyEvent(_ spec: String, window: NSWindow, isRepeat: Bool = false) -> NSEvent? {
        guard let key = KeyNames.parse(spec) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if key.modifiers.contains("command") { flags.insert(.command) }
        if key.modifiers.contains("option") { flags.insert(.option) }
        if key.modifiers.contains("shift") { flags.insert(.shift) }
        if key.modifiers.contains("control") { flags.insert(.control) }
        if key.characters.unicodeScalars.first.map({ (0xF700...0xF8FF).contains($0.value) }) == true { flags.insert(.function) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                charactersIgnoringModifiers: key.characters, isARepeat: isRepeat, keyCode: key.code)
    }

    /// The type-to-select input of the focused file list (Details or an icon layout).
    static func listTextInput(_ c: BrowserWindowController?) -> TypeSelectInput? {
        switch c?.window?.firstResponder {
        case let table as FileTableView: return table.typeSelect?.input
        case let grid as ItemGridView: return grid.typeSelectInputForScripts
        default: return nil
        }
    }

    static func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Indented `role[/subrole] "label" (title) = value` lines plus states; ignored containers are
/// flattened like VoiceOver does, and lists cut after `perElement` children.
enum AXDump {
    static let perElement = 60
    static let maxLines = 6000

    static func dump(_ window: NSWindow) -> String {
        var lines: [String] = ["window \"\(window.title)\" role=\(window.accessibilityRole()?.rawValue ?? "-")"]
        let focused = window.accessibilityFocusedUIElement
        for child in unignored(window.accessibilityChildren() ?? []) { walk(child, depth: 1, focused: focused, into: &lines) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// By key, so it also works for AppKit's private row/cell proxies.
    private static func get(_ object: NSObject, _ key: String, getter: String? = nil) -> Any? {
        if object.responds(to: NSSelectorFromString(getter ?? key)) { return object.value(forKey: key) }
        // Table/outline rows and header proxies only answer the attribute-based API.
        let attributeGetter = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: attributeGetter) else { return nil }
        let names = ["accessibilityRole": "AXRole", "accessibilitySubrole": "AXSubrole", "accessibilityLabel": "AXDescription",
                     "accessibilityTitle": "AXTitle", "accessibilityValue": "AXValue", "accessibilityChildren": "AXChildren",
                     "accessibilitySelected": "AXSelected", "accessibilityFocused": "AXFocused", "accessibilityExpanded": "AXDisclosing",
                     "accessibilityHelp": "AXHelp", "accessibilityRoleDescription": "AXRoleDescription", "accessibilityEnabled": "AXEnabled"]
        guard let name = names[key] else { return nil }
        return object.perform(attributeGetter, with: name)?.takeUnretainedValue()
    }

    private static func flag(_ object: NSObject, _ key: String, getter: String) -> Bool {
        (get(object, key, getter: getter) as? NSNumber)?.boolValue ?? false
    }

    private static func string(_ object: NSObject, _ key: String) -> String? {
        let value = get(object, key)
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }

    private static func unignored(_ children: [Any]) -> [Any] {
        var result: [Any] = []
        for child in children {
            if let view = child as? NSView, !view.isAccessibilityElement() {
                if view.isHidden { continue }
                result += unignored(view.accessibilityChildren() ?? [])
            } else {
                result.append(child)
            }
        }
        return result
    }

    static let controlRoles: Set<String> = ["AXButton", "AXMenuButton", "AXRadioButton", "AXCheckBox", "AXTextField", "AXCell",
                                            "AXPopUpButton", "AXDisclosureTriangle", "AXRow", "AXSlider"]

    private static func walk(_ element: Any, depth: Int, focused: Any?, into lines: inout [String]) {
        guard lines.count < maxLines, depth < 40 else { return }
        if let view = element as? NSView, view.isHidden { return }
        guard let e = element as? NSObject else {
            lines.append(String(repeating: "  ", count: depth) + "(\(type(of: element)))")
            return
        }
        var line = String(repeating: "  ", count: depth)
        let roleText = string(e, "accessibilityRole")
        let role = roleText.map { NSAccessibility.Role(rawValue: $0) }
        line += roleText ?? "(\(type(of: e)))"
        if let sub = string(e, "accessibilitySubrole"), !sub.isEmpty { line += "/" + sub }
        if let label = string(e, "accessibilityLabel"), !label.isEmpty { line += " \"\(label)\"" }
        if let title = string(e, "accessibilityTitle"), !title.isEmpty { line += " (\(title))" }
        if let value = get(e, "accessibilityValue") {
            let text: String
            if let tab = value as? TabItemView { text = "tab \(tab.index + 1)" }
            else if let number = value as? NSNumber { text = number.stringValue }
            else if let string = value as? String { text = string }
            else if let attributed = value as? NSAttributedString { text = attributed.string }
            else { text = String(describing: type(of: value)) }
            if !text.isEmpty { line += " = " + String(text.prefix(70)) }
        }
        if let description = string(e, "accessibilityRoleDescription"), role == .cell { line += " [\(description)]" }
        if flag(e, "accessibilitySelected", getter: "isAccessibilitySelected") { line += " selected" }
        // What VoiceOver follows: the window's focused element (the focused row's cell, a grid item…).
        if focused.map({ ($0 as AnyObject) === e }) ?? false { line += " focused" }
        if controlRoles.contains(roleText ?? ""), e.responds(to: NSSelectorFromString("isAccessibilityEnabled")),
           !flag(e, "accessibilityEnabled", getter: "isAccessibilityEnabled") { line += " disabled" }
        if flag(e, "accessibilityExpanded", getter: "isAccessibilityExpanded") { line += " expanded" }
        if let actions = get(e, "accessibilityCustomActions") as? [NSAccessibilityCustomAction], !actions.isEmpty {
            line += " actions=" + actions.map { $0.name }.joined(separator: ",")
        }
        if let help = string(e, "accessibilityHelp"), !help.isEmpty, role != .cell { line += " help=\"\(help.prefix(50))\"" }
        lines.append(line)
        let children = unignored(get(e, "accessibilityChildren") as? [Any] ?? [])
        for child in children.prefix(perElement) { walk(child, depth: depth + 1, focused: focused, into: &lines) }
        if children.count > perElement {
            lines.append(String(repeating: "  ", count: depth + 1) + "… \(children.count - perElement) more")
        }
    }
}
