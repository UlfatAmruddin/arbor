import Darwin
import Foundation

/// The "custom icon" flag Finder keeps in an item's FinderInfo (`com.apple.FinderInfo` extended attribute,
/// 32 bytes; the Finder flags are a big-endian UInt16 at offset 8, kHasCustomIcon = 0x0400). Reading it is one
/// small `getxattr` call: cheap enough for the rows on screen, done off the main thread (DEC-performance-3).
public enum FinderInfo {
    public static let attributeName = "com.apple.FinderInfo"
    public static let hasCustomIconFlag: UInt16 = 0x0400

    /// Whether 32 bytes of FinderInfo carry the custom-icon flag.
    public static func hasCustomIcon(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 10 else { return false }
        let flags = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return flags & hasCustomIconFlag != 0
    }

    /// Reads the flag from a file (links are not followed). Missing attribute or file: false.
    public static func hasCustomIcon(atPath path: String) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 32)
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(path, attributeName, raw.baseAddress, 32, 0, XATTR_NOFOLLOW)
        }
        return read >= 10 && hasCustomIcon(Array(buffer.prefix(read)))
    }
}
