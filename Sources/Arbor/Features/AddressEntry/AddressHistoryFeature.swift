import AppKit
import ArborCore

/// Addresses remembered across launches (FE-006), for the ▾ list and completion. See docs/features/address-entry.md.
enum AddressHistoryFeature: ExplorerFeature {
    static let id = "address-history"

    /// Nil in a headless run without a state folder, so it can't read or write the real history.
    static let fileURL = FolderOptionsStorage.url("AddressHistory.json")
    static let store = AddressHistoryStore(fileURL: fileURL, queue: FolderOptionsStorage.writeQueue)

    static func register() {
        let center = NotificationCenter.default
        // A typed address that opened arrives here too; one that failed is never remembered.
        center.addObserver(forName: LocationEvents.didVisit, object: nil, queue: .main) { note in
            guard let location = note.userInfo?["location"] as? Location else { return }
            store.loadIfNeeded()
            store.record(location)
        }
        center.addObserver(forName: HomeStore.historyCleared, object: nil, queue: .main) { _ in store.clear() }
        AddressBar.recentLocations.provide("address-history.recent-locations") {
            store.loadIfNeeded()
            store.checkFolders()
            return store.list
        }
        // Saves are coalesced; scripted runs end with exit().
        atexit { AddressHistoryFeature.store.flush() }
    }
}
