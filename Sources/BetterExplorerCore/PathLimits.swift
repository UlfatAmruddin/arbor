import Foundation

/// The limits every path-based call and folder walker must respect (FE-225).
public enum PathLimits {
    /// The kernel refuses a path of `PATH_MAX` bytes or more, terminator included.
    public static let maxPathBytes = Int(PATH_MAX) - 1

    /// Walkers hold one descriptor per level, and every running job shares the app's soft limit of 256.
    public static let maxFolderDepth = 128

    /// A job thread's stack: walking to `maxFolderDepth` overflows the 512 KB a thread gets by default.
    public static let jobStackBytes = 8 << 20

    /// Measures the decomposed form, which FileManager sends to the kernel even when `URL.path` is shorter.
    public static func fits(_ url: URL) -> Bool {
        url.path.decomposedStringWithCanonicalMapping.utf8.count <= maxPathBytes
    }
}
