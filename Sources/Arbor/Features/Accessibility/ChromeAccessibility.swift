import AppKit
import ArborCore

/// Roles, labels and actions for the custom-drawn chrome (FE-200): the tab strip is a tab group whose
/// tabs are tab buttons with a "Close tab" action (the close button only exists on hover), the status
/// bar and side pane are labelled groups, the item views are labelled, and the Gallery grid exposes
/// its photos. Everything else (address bar, breadcrumb buttons and chevron menus, command bar toolbar,
/// navigation tree) already uses real controls or `ChromeButton`, whose role and state are set there.
enum ChromeAccessibility {
    static func install() {
        WindowHooks.didCreate.append { c in
            label(c)
            RightToLeft.adjustArrows(c)
        }
        WindowHooks.didDisplay.append { c, _ in label(c) }
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            guard (note.userInfo?["key"] as? String) == "sidePane" else { return }
            (NSApp.delegate as? AppDelegate)?.controllers.forEach(label)
        }
    }

    static func label(_ c: BrowserWindowController) {
        c.statusBar.setAccessibilityElement(true)
        c.statusBar.setAccessibilityRole(.group)
        c.statusBar.setAccessibilityLabel(L10n.tr("Status bar"))
        c.navBar.back.setAccessibilityHelp(c.navBar.back.toolTip)
        c.navBar.forward.setAccessibilityHelp(c.navBar.forward.toolTip)
        c.navBar.up.setAccessibilityHelp(c.navBar.up.toolTip)
        c.sidePane.setAccessibilityElement(!c.sidePane.isHidden)
        c.sidePane.setAccessibilityRole(.group)
        c.sidePane.setAccessibilityLabel(SidePaneRegistry.descriptor(c.sidePane.currentID).map { L10n.tr($0.title) })
        if let view = c.itemView?.focusView, view is NSTableView {
            view.setAccessibilityLabel(L10n.format("Items, %@", StatusText.items(c.visibleItems.count)))
        }
        c.searchBox.field.setAccessibilityLabel(L10n.tr("Search box"))
        c.searchBox.field.setAccessibilityHelp(c.searchBox.placeholder)
        // Decorative images (location icon, magnifier) are not separate elements.
        for image in FocusRegions.descendants(of: c.navBar, as: NSImageView.self) { image.setAccessibilityElement(false) }
    }
}

// MARK: - Address bar: breadcrumb in reading order (segment, its chevron, next segment…)

extension AddressBar {
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        return children.sorted { a, b in
            let x = { (e: Any) -> CGFloat in (e as? NSView).map { $0.isHidden ? .greatestFiniteMagnitude : $0.frame.minX } ?? 0 }
            return x(a) < x(b)
        }
    }
}

// MARK: - Tab strip

extension TabStripView {
    override func accessibilityTabs() -> [Any]? {
        FocusRegions.descendants(of: self, as: TabItemView.self).sorted { $0.index < $1.index }
    }

    /// The selected tab.
    override func accessibilityValue() -> Any? {
        FocusRegions.descendants(of: self, as: TabItemView.self).first(where: \.isSelected)
    }
}

extension TabItemView {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { NSAccessibility.Subrole(rawValue: "AXTabButton") }
    override func accessibilityHelp() -> String? { item.tooltip }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityIndex() -> Int { index }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: L10n.tr("Close tab")) { [weak self] in
            guard let self, let strip = self.strip else { return false }
            strip.delegate?.tabStripClose(self.index)
            return true
        }]
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = strip?.delegate?.tabStripMenu(for: index) else { return false }
        ContextMenuKey.present(menu, self, NSPoint(x: 12, y: bounds.maxY))
        return true
    }
}

// MARK: - Page tiles and section headers are usable, not "dimmed"

extension TileView {
    override func isAccessibilityEnabled() -> Bool { true }
}

extension SectionHeaderView {
    override func isAccessibilityEnabled() -> Bool { true }
}

extension NetworkTileView {
    override func isAccessibilityEnabled() -> Bool { true }
}

extension SectionHeader {
    override func isAccessibilityEnabled() -> Bool { true }
}

// MARK: - Navigation pane

extension NavSeparatorView {
    override func isAccessibilityElement() -> Bool { false }
}

// MARK: - Gallery

extension GalleryGridView {
    /// The photos on screen (plus a margin), each with its name, frame and selected state.
    override func accessibilityChildren() -> [Any]? {
        let visible = visibleRect.insetBy(dx: 0, dy: -400)
        return tiles.filter { $0.rect.intersects(visible) }.prefix(500).map { tile in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.cell)
            element.setAccessibilityRoleDescription(L10n.tr("Photo"))
            element.setAccessibilityLabel(tile.item.url.lastPathComponent)
            element.setAccessibilityParent(self)
            element.setAccessibilityEnabled(true)
            element.setAccessibilitySelected(selection.contains(tile.item.key))
            element.setAccessibilityFrameInParentSpace(tile.rect)
            return element
        }
    }
}
