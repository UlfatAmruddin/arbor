import AppKit
import ArborCore

extension BrowserWindowController {
    // MARK: - Change observation (preferences, Quick access, clipboard, jobs, volumes)

    func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] note in
            self?.prefsChanged(note.userInfo?["key"] as? String)
        })
        observers.append(nc.addObserver(forName: QuickAccess.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildNavPane()
            self?.updateChrome()
        })
        observers.append(nc.addObserver(forName: FileClipboard.changed, object: nil, queue: .main) { [weak self] _ in
            self?.itemView?.reloadRows()
            self?.updateChrome()
        })
        observers.append(nc.addObserver(forName: OperationCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.statusBar.setJob(OperationCenter.shared.statusLine)
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.volumesChanged(note)
            })
        }
    }

    private func prefsChanged(_ key: String?) {
        switch key {
        case "showHidden":
            rebuildNavPane()
            tabs.filter { $0 !== activeTab }.forEach { $0.items = nil }
            reload()
        case "showExtensions", "compactView", "itemCheckBoxes":
            itemView?.reloadRows()
        case "sidePane":
            showSidePane(Prefs.sidePane)
            updateChrome()
        case "navigationPaneVisible":
            navPane.view.isHidden = !Prefs.navigationPaneVisible
            updateChrome()
        default:
            break
        }
        split.adjustSubviews()
    }

    private func rebuildNavPane() {
        navPane.rebuild()
        navPane.reveal(location)
    }

    private func volumesChanged(_ note: Notification) {
        // Coalesced: one disk image mount posts several notifications; each rebuild reads volume names on main.
        navPaneRebuild?.cancel()
        let rebuild = DispatchWorkItem { [weak self] in self?.rebuildNavPane() }
        navPaneRebuild = rebuild
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: rebuild)
        guard note.name == NSWorkspace.didUnmountNotification,
              let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        for tab in tabs {
            guard let url = tab.location.folderURL, FileOps.isSameOrInside(url, volume) else { continue }
            if Self.volumeUnmountHandler.handle((self, tab, volume)) { continue }
            if tab === activeTab { statusBar.setMessage(L10n.format("“%@” was disconnected.", "\(displayName(of: volume))"), isError: true) }
            request(.visit(.thisMac, select: [], selectURLs: []), tab: tab)
        }
    }

    /// A tab's volume was unmounted; return true if handled (network tabs show "disconnected", not This Mac).
    static let volumeUnmountHandler = Handlers<(BrowserWindowController, TabState, URL), Void>(
        "BrowserWindowController.volumeUnmountHandler", "A tab's volume was unmounted; true = handled (tab stays).",
        signature: "(window, tab, volume) -> handled")
}
