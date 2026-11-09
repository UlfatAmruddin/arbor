import Foundation

/// One volume's line in a This Mac search's explanation (FE-132).
public struct SearchLocationCoverage: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case included, partial, excluded }

    public var name: String
    public var status: Status
    public var reason: String

    public init(name: String, status: Status, reason: String) {
        self.name = name
        self.status = status
        self.reason = reason
    }
}

/// What a search found out about one volume while it ran.
public struct SearchVolumeFindings: Equatable, Sendable {
    public enum Scan: Equatable, Sendable { case notRun, finished, cutShort }

    public var scan = Scan.notRun
    public var denied = 0
    public var unreadable = 0

    public init() {}

    public mutating func add(_ report: DirectSearchReport) {
        scan = report.cancelled || report.limitReached ? .cutShort : .finished
        denied += report.deniedCount
        unreadable += report.unreadableCount
    }
}

/// Decides, for each volume, what a This Mac search covered and why (FE-132). Pure, so every answer is unit-tested.
public enum WholeMacCoverage {
    /// Caps the explanation, and the index checks behind it, on a Mac with an unusual number of mounts.
    public static let volumeLimit = 32

    public static func ordered(_ volumes: [VolumeSummary]) -> [VolumeSummary] {
        let sorted = volumes.sorted { a, b in
            a.kind.sortRank != b.kind.sortRank ? a.kind.sortRank < b.kind.sortRank
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Array(sorted.prefix(volumeLimit))
    }

    /// The volume whose mount point is the longest prefix of `path`.
    public static func volume(holding path: String, in volumes: [VolumeSummary]) -> VolumeSummary? {
        volumes.filter { ScopedSearch.isInside(URL(fileURLWithPath: path), $0.url) }
            .max { $0.url.path.utf8.count < $1.url.path.utf8.count }
    }

    /// Requested scan folders, minus anything on a network volume: the mount table can be newer than the page that asked.
    public static func scannable(_ requested: [URL], volumes: [VolumeSummary]) -> [URL] {
        requested.filter { volume(holding: $0.path, in: volumes)?.kind != .network }
    }

    public static func locations(volumes: [VolumeSummary], indexStates: [String: SpotlightIndexState],
                                 findings: [String: SearchVolumeFindings], spotlightAnswered: Bool) -> [SearchLocationCoverage] {
        ordered(volumes).map { volume in
            let path = volume.url.path
            let (status, reason) = verdict(kind: volume.kind, state: indexStates[path] ?? .unknown,
                                           findings: findings[path] ?? SearchVolumeFindings(), spotlightAnswered: spotlightAnswered)
            return SearchLocationCoverage(name: oneLine(volume.name), status: status, reason: reason)
        }
    }

    /// What every This Mac search leaves out, whichever volumes are mounted.
    public static func notes(searchedContents: Bool) -> [String] {
        var notes = [L10n.tr("Folders excluded in System Settings ▸ Spotlight aren't searched, and macOS doesn't tell apps which ones they are."),
                     L10n.tr("System files and the contents of apps and other packages may be left out."),
                     L10n.tr("Files inside compressed archives aren't searched from This Mac.")]
        if !searchedContents { notes.append(L10n.tr("Only names were searched. To search inside files, turn on Search options ▸ Advanced options ▸ File contents.")) }
        return notes
    }

    private static func verdict(kind: VolumeSummary.Kind, state: SpotlightIndexState, findings: SearchVolumeFindings,
                                spotlightAnswered: Bool) -> (SearchLocationCoverage.Status, String) {
        if kind == .network {
            return (.excluded, L10n.tr("Network volumes aren't searched from This Mac, so a slow server can't stall the search. Open the volume and search there."))
        }
        var status = SearchLocationCoverage.Status.included
        var sentences: [String]
        switch findings.scan {
        case .finished:
            sentences = [state == .enabled ? L10n.tr("Scanned folder by folder, plus the Spotlight index.") : L10n.tr("Scanned folder by folder.")]
        case .cutShort:
            status = .partial
            sentences = [L10n.tr("Scanned only in part: the search stopped before it finished this volume.")]
        case .notRun:
            switch state {
            case .disabled:
                return (.excluded, L10n.tr("Spotlight indexing is off on this volume. Open a folder on it and search there to scan it directly."))
            case .unknown:
                status = .partial
                sentences = [L10n.tr("Arbor couldn't tell whether Spotlight indexes this volume, so some of its files may be missing.")]
            case .enabled:
                status = spotlightAnswered ? .included : .partial
                sentences = [spotlightAnswered ? L10n.tr("Searched through the Spotlight index.") : L10n.tr("Spotlight didn't finish answering for this volume.")]
            }
        }
        if findings.denied > 0 {
            status = .partial
            sentences.append(findings.denied == 1 ? L10n.tr("macOS denied access to 1 folder.")
                                                  : L10n.format("macOS denied access to %@ folders.", findings.denied.formatted()))
        }
        if findings.unreadable > 0 {
            status = .partial
            sentences.append(findings.unreadable == 1 ? L10n.tr("1 folder couldn't be read.")
                                                      : L10n.format("%@ folders couldn't be read.", findings.unreadable.formatted()))
        }
        return (status, sentences.joined(separator: " "))
    }

    /// A volume label is outside text: line breaks and direction overrides would forge lines of the explanation.
    private static func oneLine(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { isForbidden($0) ? " " : $0 }))
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
}

/// A volume from `ARBOR_TEST_SEARCH_VOLUMES`, so scripted runs never reach real disks or the real index.
public struct InjectedSearchVolume: Equatable, Sendable {
    public var volume: VolumeSummary
    public var indexState: SpotlightIndexState
    /// Stands in for the volume's contents; without one, nothing is read for this volume.
    public var folder: URL?

    public init(volume: VolumeSummary, indexState: SpotlightIndexState, folder: URL?) {
        self.volume = volume
        self.indexState = indexState
        self.folder = folder
    }

    /// The folder a search of this volume really scans. The index has no fixture of its own, so the
    /// startup disk's folder stands in for its Spotlight answers, and only while indexing is on.
    public var scanFolder: URL? {
        switch volume.kind {
        case .network: return nil
        case .startup: return indexState == .enabled ? folder : nil
        default: return folder
        }
    }

    /// `name|kind|enabled, disabled or unknown|fixture folder` entries separated by `;`. Malformed entries are dropped.
    public static func parse(_ text: String) -> [InjectedSearchVolume] {
        let entries = text.split(separator: ";").compactMap { entry -> InjectedSearchVolume? in
            let fields = entry.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty, let kind = VolumeSummary.Kind(rawValue: fields[1]),
                  let state = SpotlightIndexState(rawValue: fields[2]) else { return nil }
            let folder = fields[3].isEmpty ? nil : URL(fileURLWithPath: fields[3]).standardizedFileURL
            let url = folder ?? URL(fileURLWithPath: "/Volumes").appendingPathComponent(fields[0])
            return InjectedSearchVolume(volume: VolumeSummary(url: url, name: fields[0], kind: kind), indexState: state, folder: folder)
        }
        return Array(entries.prefix(WholeMacCoverage.volumeLimit))
    }
}
