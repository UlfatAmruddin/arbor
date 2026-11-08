import Darwin
import Foundation

/// Finder's custom-icon flag: big-endian UInt16 flags at offset 8 of the 32-byte FinderInfo xattr.
/// One small `getxattr`, cheap enough for on-screen rows, done off the main thread (DEC-performance-3).
public enum FinderInfo {
    public static let attributeName = "com.apple.FinderInfo"
    public static let hasCustomIconFlag: UInt16 = 0x0400

    public static func hasCustomIcon(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 10 else { return false }
        let flags = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return flags & hasCustomIconFlag != 0
    }

    /// Doesn't follow links; false when the file or attribute is missing.
    public static func hasCustomIcon(atPath path: String) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 32)
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(path, attributeName, raw.baseAddress, 32, 0, XATTR_NOFOLLOW)
        }
        return read >= 10 && hasCustomIcon(Array(buffer.prefix(read)))
    }
}
