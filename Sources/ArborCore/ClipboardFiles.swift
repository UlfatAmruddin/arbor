import Foundation

/// What may be taken from the pasteboard as files (FE-101). Anything may have put it there, so it is
/// all or nothing: pasting part of what was copied would look like success.
public enum ClipboardFiles {
    /// Far above a real selection, low enough that reading the list can't stall the window for long.
    public static let maxItems = 100_000
    /// Longer than any path the system accepts, even with every byte percent-encoded.
    static let maxURLBytes = 64 * 1024

    public enum Refusal: Equatable, Sendable {
        case tooManyItems(Int)
        case notLocalFiles
        case wholeDisk

        public var message: String {
            switch self {
            case .tooManyItems(let count):
                return L10n.format("The clipboard holds %@. Arbor can paste up to %@ at once, so nothing was pasted.",
                                   StatusText.items(count), StatusText.items(ClipboardFiles.maxItems))
            case .notLocalFiles:
                return L10n.tr("The clipboard holds something other than files on this Mac, so nothing was pasted.")
            case .wholeDisk:
                return L10n.tr("The clipboard includes a whole disk. Arbor doesn't paste disks, so nothing was pasted.")
            }
        }
    }

    public enum Contents: Equatable, Sendable {
        case nothing
        case files([URL])
        case refused(Refusal)
    }

    /// `urls` is called only once `itemCount` is acceptable, so an oversized list is never read.
    public static func read(itemCount: Int, urls: () -> [URL],
                            isVolumeRoot: (URL) -> Bool = Location.isVolumeRoot) -> Contents {
        guard itemCount > 0 else { return .nothing }
        guard itemCount <= maxItems else { return .refused(.tooManyItems(itemCount)) }
        let found = urls()
        // Items that aren't URLs at all are simply missing from `found`.
        guard found.count == itemCount else { return .refused(.notLocalFiles) }
        var seen = Set<String>()
        var files: [URL] = []
        for url in found {
            guard url.absoluteString.utf8.count <= maxURLBytes,
                  let local = ExternalOpen.validatedFileURL(url)?.standardizedFileURL else { return .refused(.notLocalFiles) }
            // A move of a mount point would copy the disk and then empty it.
            guard !isVolumeRoot(local) else { return .refused(.wholeDisk) }
            if seen.insert(local.path).inserted { files.append(local) }
        }
        return .files(files)
    }

    /// For apps that take only text: full paths, one per line, without the quotes of Copy as Path.
    public static func plainText(for urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }
}

extension TransferReport {
    /// Every source really left: a skip, a cancel or a problem means the clipboard still names something useful.
    public var movedEverything: Bool {
        guard kind == .move, !wasCancelled, !results.isEmpty, details.isEmpty else { return false }
        return results.allSatisfy { result in
            switch result.outcome {
            case .succeeded, .merged: return true
            default: return false
            }
        }
    }
}
