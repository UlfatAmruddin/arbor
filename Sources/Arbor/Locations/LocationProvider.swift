import AppKit
import ArborCore

/// What a location shows: items in the standard item views (sorting, selection, rename… all work) or a custom page.
enum LocationContent {
    case items([FileItem])
    case custom(NSViewController)
}

/// What a page or provider can ask of the window that shows it.
protocol LocationHost: AnyObject {
    func navigate(to location: Location, select: [String])
    func openInNewTab(_ location: Location)
    func showStatusMessage(_ text: String?, isError: Bool)
    /// Re-runs the provider for the tab's current location.
    func reloadLocation()
}

struct LocationLoadContext {
    let showHidden: Bool
    weak var host: LocationHost?
}

/// Lets a load be abandoned when the user navigates elsewhere first.
final class LoadHandle {
    private(set) var isCancelled = false
    var onCancel: (() -> Void)?
    func cancel() {
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}

/// Supplies content for some locations (B2). Register in `register()`: `LocationRegistry.register(TrashProvider())`.
/// The latest registered provider that `handles` a location wins, so features replace core placeholders.
protocol LocationProvider: AnyObject {
    func handles(_ location: Location) -> Bool
    /// Loads async, calling `completion` on main. Return a handle if cancellable.
    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle?
    /// Starts watching; the returned token stops when released. Default: none.
    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject?
    func title(for location: Location) -> String
    func icon(for location: Location, size: CGFloat) -> NSImage
    /// The real folder that New and Paste write into, if any.
    func targetFolder(for location: Location) -> URL?
    /// Whether rename, delete and new-item commands apply to items shown here.
    func allowsItemEditing(in location: Location) -> Bool
    /// Text for the empty state ("This folder is empty.").
    func emptyText(for location: Location) -> String
    /// Extra status-bar text after the item count.
    func statusDetail(for location: Location) -> String?
}

extension LocationProvider {
    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? { nil }
    func title(for location: Location) -> String { location.displayName }
    func icon(for location: Location, size: CGFloat) -> NSImage { IconProvider.shared.icon(for: location, size: size) }
    func targetFolder(for location: Location) -> URL? { location.folderURL }
    func allowsItemEditing(in location: Location) -> Bool { location.folderURL != nil }
    func emptyText(for location: Location) -> String { L10n.tr("This folder is empty.") }
    /// Extra status-bar text after the item count (search progress and coverage). Default: none.
    func statusDetail(for location: Location) -> String? { nil }
}

/// Optional: a custom page that wants text in the status bar.
protocol LocationPageStatus {
    var statusSummary: String { get }
}

enum LocationRegistry {
    private static var providers: [LocationProvider] = []
    static let openHandlers = Handlers<FileItem, Location>(
        "LocationRegistry.openHandlers", "Turns an opened item into a location (archives, saved searches, aliases).",
        signature: "(item) -> Location?")
    private static let fallback = PlaceholderProvider(locations: { _ in true })

    static func register(_ provider: LocationProvider) { providers.append(provider) }

    static func provider(for location: Location) -> LocationProvider {
        providers.last { $0.handles(location) } ?? fallback
    }

    /// Turns an opened item into a location (e.g. .zip → `.archive`). First handler in run order wins;
    /// otherwise folders open as folders and files with their app.
    static func registerOpenHandler(_ id: String, order: ExtensionOrder = .normal, _ handler: @escaping (FileItem) -> Location?) {
        openHandlers.register(id, order: order, handler)
    }

    static func locationForOpening(_ item: FileItem) -> Location? {
        if let location = openHandlers.first(item) { return location }
        return item.isFolder ? .folder(item.url) : nil
    }
}
