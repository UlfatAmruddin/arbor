import AppKit

/// Right-to-left layout for the chrome that positions its parts by hand (FE-204). Stack views, tables,
/// the tree and the status bar mirror themselves; the tab strip and the breadcrumb call these helpers
/// at the end of `layout()` so their parts run right to left too, with chevrons pointing left.
enum RightToLeft {
    static func isActive(_ view: NSView) -> Bool { view.userInterfaceLayoutDirection == .rightToLeft }

    /// Mirrors `views` inside `container`, and `nested` inside `contents` (a scroll view's document).
    static func mirror(_ container: NSView, _ views: [NSView], contents: NSView? = nil, _ nested: [[NSView]] = []) {
        guard isActive(container) else { return }
        for view in views { flip(view, in: container.bounds.width) }
        if let contents {
            for view in nested.joined() { flip(view, in: contents.bounds.width) }
        }
    }

    /// The breadcrumb: every part mirrored; separators point left (the path reads right to left).
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
