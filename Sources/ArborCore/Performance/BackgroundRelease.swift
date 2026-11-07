import Foundation

/// Lets a large value (a 100,000-row listing) be freed on a background queue instead of the main
/// thread, where releasing its URLs and strings took ~30 ms per folder change (docs/PERFORMANCE.md).
public enum BackgroundRelease {
    private static let queue = DispatchQueue(label: "Arbor background release", qos: .utility)

    /// Holds `value` briefly on a background queue so that, if the caller drops its last reference in
    /// the meantime, the memory is freed there.
    public static func drop<T>(_ value: T) {
        let box = Box(value)
        queue.asyncAfter(deadline: .now() + 0.05) { box.value = nil }
    }

    private final class Box<V>: @unchecked Sendable {
        var value: V?
        init(_ value: V) { self.value = value }
    }
}
