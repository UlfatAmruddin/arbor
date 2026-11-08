import Foundation

/// Frees large values (100,000-row listings) off the main thread, where it took ~30 ms (docs/PERFORMANCE.md).
public enum BackgroundRelease {
    private static let queue = DispatchQueue(label: "Arbor background release", qos: .utility)

    /// Holds `value` briefly so the last release, if the caller drops it meanwhile, happens on the background queue.
    public static func drop<T>(_ value: T) {
        let box = Box(value)
        queue.asyncAfter(deadline: .now() + 0.05) { box.value = nil }
    }

    private final class Box<V>: @unchecked Sendable {
        var value: V?
        init(_ value: V) { self.value = value }
    }
}
