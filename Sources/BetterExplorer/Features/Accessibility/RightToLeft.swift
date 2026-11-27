import AppKit

/// Right-to-left mirroring for hand-laid-out chrome (FE-204); call at the end of `layout()`.
enum RightToLeft {
    static func isActive(_ view: NSView) -> Bool { view.userInterfaceLayoutDirection == .rightToLeft }

    /// Explorer's left and right mean start and end: right-aligned columns stay at the end of the line.
    static func resolved(_ alignment: NSTextAlignment) -> NSTextAlignment {
        guard NSApp.userInterfaceLayoutDirection == .rightToLeft else { return alignment }
        switch alignment {
        case .left: return .right
        case .right: return .left
        default: return alignment
        }
    }

    /// Rows of tabs laid out from the left, as a right-to-left layout places them.
    static func mirrored(_ rects: [NSRect], in view: NSView) -> [NSRect] {
        guard isActive(view) else { return rects }
        return rects.map { NSRect(x: view.bounds.width - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) }
    }

    /// For a path someone types or reads: the root stays on the left whatever the interface direction.
    static func holdLeftToRight(_ field: NSTextField) {
        guard isActive(field) else { return }
        field.baseWritingDirection = .leftToRight
    }

    /// Mirrors `views` inside `container`, and `nested` inside `contents` (a scroll view's document).
    static func mirror(_ container: NSView, _ views: [NSView], contents: NSView? = nil, _ nested: [[NSView]] = []) {
        guard isActive(container) else { return }
        for view in views { flip(view, in: container.bounds.width) }
        if let contents {
            for view in nested.joined() { flip(view, in: contents.bounds.width) }
        }
    }

    /// The breadcrumb: every part mirrored; separators point left.
    static func mirrorBreadcrumb(_ bar: NSView, chevrons: [ChromeButton]) {
        guard isActive(bar) else { return }
        for view in bar.subviews where !view.isHidden { flip(view, in: bar.bounds.width) }
        for chevron in chevrons where chevron.symbolName == "chevron.right" { chevron.symbolName = "chevron.left" }
    }

    private static func flip(_ view: NSView, in width: CGFloat) {
        var frame = view.frame
        frame.origin.x = width - frame.maxX
        view.frame = frame
    }

    /// Back and Forward arrows point the other way in a right-to-left layout.
    static func adjustArrows(_ c: BrowserWindowController) {
        guard isActive(c.navBar) else { return }
        c.navBar.back.symbolName = "arrow.right"
        c.navBar.forward.symbolName = "arrow.left"
    }
}
