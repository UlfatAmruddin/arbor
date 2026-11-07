import AppKit
import ArborCore

/// Drag-and-drop extension points for items that aren't plain files on disk (archive members) and
/// drops that carry file promises instead of URLs. Item views call these (Details, icon layouts);
/// opening and extra columns use `InteractionHooks` and `DetailsColumns`.
///
///     ItemHooks.registerDragWriter { item in isMine(item) ? MyPromise(item) : nil }
///     ItemHooks.registerDropHandler(types: [...], operation: { info, dest in .copy }, accept: { info, dest, window in true })
enum ItemHooks {
    // MARK: Dragging out

    private static var dragWriters: [(FileItem) -> NSPasteboardWriting?] = []

    static func registerDragWriter(_ writer: @escaping (FileItem) -> NSPasteboardWriting?) { dragWriters.append(writer) }

    /// A custom pasteboard writer (a file promise, say) for an item, or nil for the item's file URL.
    static func dragWriter(for item: FileItem) -> NSPasteboardWriting? {
        for writer in dragWriters.reversed() { if let w = writer(item) { return w } }
        return nil
    }

    // MARK: Dropping in (drops that carry no file URLs, such as file promises)

    struct DropHandler {
        let types: [NSPasteboard.PasteboardType]
        let operation: (NSDraggingInfo, URL) -> NSDragOperation?
        let accept: (NSDraggingInfo, URL, NSWindow?) -> Bool
    }

    private static var dropHandlers: [DropHandler] = []

    static func registerDropHandler(_ handler: DropHandler) { dropHandlers.append(handler) }

    /// Extra pasteboard types item views should register for.
    static var dropTypes: [NSPasteboard.PasteboardType] { dropHandlers.flatMap(\.types) }

    /// The drag operation a handler offers for a drop with no file URLs, or nil to use the normal rules.
    static func dropOperation(_ info: NSDraggingInfo, destination: URL?) -> NSDragOperation? {
        guard let destination, DropPolicy.fileURLs(from: info).isEmpty else { return nil }
        for handler in dropHandlers.reversed() { if let op = handler.operation(info, destination) { return op } }
        return nil
    }

    /// True if a handler took the drop.
    static func acceptDrop(_ info: NSDraggingInfo, destination: URL?, window: NSWindow?) -> Bool {
        guard let destination, DropPolicy.fileURLs(from: info).isEmpty else { return false }
        return dropHandlers.reversed().contains { $0.operation(info, destination) != nil && $0.accept(info, destination, window) }
    }
}
