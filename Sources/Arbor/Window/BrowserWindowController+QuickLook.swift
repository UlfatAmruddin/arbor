import AppKit
import Quartz
import ArborCore

extension BrowserWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    // MARK: - Quick Look (Space)

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            SystemOpen.showQuickLook(panel, previewing: selectedItems.map { PreviewHooks.url(for: $0) })
        }
    }

    func refreshQuickLook() {
        guard quickLookActive, let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        quickLookActive = true
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookActive = false
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = selectedItems
        return index < items.count ? PreviewHooks.url(for: items[index]) as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Pages (Gallery, Home) take the arrow keys in their own view, which keeps first responder.
        let pageView = activeTab.showsPage ? window?.firstResponder as? NSView : nil
        guard event.type == .keyDown, let view = pageView ?? itemView?.focusView else { return false }
        view.keyDown(with: event)
        return true
    }
}
