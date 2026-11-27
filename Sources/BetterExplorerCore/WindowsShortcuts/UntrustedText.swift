import Foundation

/// Text from a file, made safe to put in a label or alert.
public enum UntrustedText {
    public static let maxDisplayLength = 1024

    /// Drops controls, line breaks, bidi overrides and zero-width marks, which can disguise what a label says.
    public static func display(_ text: String, limit: Int = maxDisplayLength) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: kept.append(scalar)
            }
        }
        let cleaned = String(kept)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }

    /// Keeps both ends, so a long path still shows its file name.
    public static func eliding(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let kept = limit - 1
        return text.prefix(kept - kept / 2) + "…" + text.suffix(kept / 2)
    }
}
