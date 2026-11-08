import AppKit

/// Scripted VoiceOver check (FE-200): `axaudit:/path` appends every unnamed control and empty row
/// in every open window:
///
///     unlabeled: "Folder Options" AXButton (DialogButton)
///     axaudit: 3 windows, 214 controls, 0 problems
enum AccessibilityAudit {
    static func register() {
        DebugScript.registerStep("axaudit") { path, _ in
            AccessibilityDebug.append(report(), to: path)
            return 0.3
        }
    }

    /// Roles VoiceOver reads by name; an unnamed one is announced as just "button", "check box"…
    static let namedRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                          "AXTextField", "AXSlider", "AXImage", "AXDisclosureTriangle", "AXComboBox",
                                          "AXOutline", "AXTable", "AXList", "AXTabGroup", "AXIncrementor", "AXSearchField"]

    static func report() -> String {
        var findings: [String] = []
        var controls = 0
        let windows = NSApp.windows.filter { $0.contentView != nil && !$0.className.contains("Menu") && $0.className != "NSStatusBarWindow" && !$0.className.contains("ComboBox")
            && ($0.isVisible || AppDelegate.isHeadless) }
        for window in windows {
            let name = window.title.isEmpty ? String(describing: type(of: window)) : window.title
            var seen = Set<ObjectIdentifier>()
            func walk(_ element: Any, depth: Int) {
                guard depth < 40, let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
                if let view = object as? NSView, view.isHidden { return }
                let role = attribute(object, "AXRole") as? String ?? ""
                // Window buttons, scroll bars and disclosure triangles are named by the system from their subrole.
                let className = String(describing: type(of: object))
                let systemPart = className.hasPrefix("_NSTheme") || className.contains("Scroller") || role == "AXDisclosureTriangle"
                if namedRoles.contains(role), !systemPart {
                    controls += 1
                    if !hasName(object, role: role) {
                        let value = (attribute(object, "AXValue") as? String).map { " value=\"\($0)\"" } ?? ""
                        let parent = (attribute(object, "AXParent") as? NSObject).map { p in
                            " in \(attribute(p, "AXRole") as? String ?? "?")/\(type(of: p))"
                        } ?? ""
                        findings.append("unlabeled: \"\(name)\" \(role) (\(className))\(value)\(parent)")
                    }
                } else if role == "AXRow", (attribute(object, "AXChildren") as? [Any] ?? []).isEmpty {
                    findings.append("empty row: \"\(name)\" (\(type(of: object)))")
                }
                for child in attribute(object, "AXChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
            }
            for child in window.accessibilityChildren() ?? [] { walk(child, depth: 0) }
        }
        findings.append("axaudit: \(windows.count) windows, \(controls) controls, \(findings.count) problems")
        return findings.joined(separator: "\n") + "\n"
    }

    private static func hasName(_ object: NSObject, role: String) -> Bool {
        for key in ["AXDescription", "AXTitle"] {
            if let text = attribute(object, key) as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        for key in ["accessibilityLabel", "accessibilityTitle"] where object.responds(to: NSSelectorFromString(key)) {
            if let text = object.value(forKey: key) as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        if attribute(object, "AXTitleUIElement") != nil { return true }
        if role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField",
           let placeholder = attribute(object, "AXPlaceholderValue") as? String, !placeholder.isEmpty { return true }
        if role == "AXImage" { return false }
        // A button whose only content is text in a child (e.g. a link) is read by that text.
        let children = attribute(object, "AXChildren") as? [Any] ?? []
        return children.contains { child in
            guard let c = child as? NSObject else { return false }
            return (attribute(c, "AXRole") as? String) == "AXStaticText" && !((attribute(c, "AXValue") as? String) ?? "").isEmpty
        }
    }

    /// Attribute-based API, so it also works for AppKit's private row and cell proxies.
    static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter, with: name)?.takeUnretainedValue()
    }
}
