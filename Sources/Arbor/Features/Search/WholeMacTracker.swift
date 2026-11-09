import Foundation
import ArborCore

/// The volumes a This Mac search runs against: the real machine, or only injected ones in scripted runs (FE-132).
struct WholeMacSource {
    /// Mount table only, so safe on the main thread.
    let volumes: () -> [VolumeSummary]
    /// Blocking: call off the main thread. Never called for a network volume.
    let inspect: (VolumeSummary) -> (name: String, state: SpotlightIndexState)
    let scanRoots: (_ requested: [URL], _ volumes: [VolumeSummary]) -> [URL]
    let runsSpotlight: Bool

    static var current: WholeMacSource {
        if let text = Automation.environment["ARBOR_TEST_SEARCH_VOLUMES"] { return injected(InjectedSearchVolume.parse(text)) }
        return AppDelegate.isHeadless ? injected([]) : machine
    }

    private static let machine = WholeMacSource(
        volumes: { VolumeCatalog.adjustments.apply(MountPoints.shared.browsableVolumes()) },
        inspect: { volume in
            let label = (try? volume.url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            return (label ?? volume.name, SpotlightSearch.readIndexState(volumePath: volume.url.path))
        },
        scanRoots: { requested, volumes in WholeMacCoverage.scannable(requested, volumes: volumes) },
        runsSpotlight: true)

    private static func injected(_ list: [InjectedSearchVolume]) -> WholeMacSource {
        WholeMacSource(volumes: { list.map(\.volume) },
                       inspect: { volume in (volume.name, list.first { $0.volume == volume }?.indexState ?? .unknown) },
                       scanRoots: { _, _ in list.compactMap(\.scanFolder) },
                       runsSpotlight: false)
    }
}

/// What one This Mac search did on each volume. Main-thread confined, like its session.
final class WholeMacTracker {
    private static let deniedLimit = 1000

    private let source: WholeMacSource
    private var volumes: [VolumeSummary]
    private var states: [String: SpotlightIndexState] = [:]
    private var findings: [String: SearchVolumeFindings] = [:]
    private var scanRoots: [URL] = []
    private var deniedByIndex = Set<String>()

    init(source: WholeMacSource = .current) {
        self.source = source
        volumes = WholeMacCoverage.ordered(source.volumes())
    }

    var runsSpotlight: Bool { source.runsSpotlight }

    func roots(from requested: [URL]) -> [URL] {
        scanRoots = source.scanRoots(requested, volumes)
        return scanRoots
    }

    /// Reads labels and index state off the main thread; `completion` gets the startup disk's state.
    func inspectVolumes(completion: @escaping (SpotlightIndexState) -> Void) {
        let source = self.source, listed = volumes
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var answers = [(name: String, state: SpotlightIndexState)?](repeating: nil, count: listed.count)
            let lock = NSLock()
            // All at once, so one stuck disk costs a single mdutil timeout rather than one per volume.
            DispatchQueue.concurrentPerform(iterations: listed.count) { index in
                guard listed[index].kind != .network else { return }
                let answer = source.inspect(listed[index])
                lock.withLock { answers[index] = answer }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (index, answer) in answers.enumerated() {
                    guard let answer else { continue }
                    self.volumes[index].name = answer.name
                    self.states[listed[index].url.path] = answer.state
                }
                completion(listed.first { $0.kind == .startup }.flatMap { self.states[$0.url.path] } ?? .unknown)
            }
        }
    }

    func scanFinished(root: URL, report: DirectSearchReport) {
        // The startup disk is only ever scanned as a fixture standing in for its index.
        guard let volume = WholeMacCoverage.volume(holding: root.path, in: volumes), volume.kind != .startup else { return }
        findings[volume.url.path, default: SearchVolumeFindings()].add(report)
    }

    func noteDenied(_ folders: [String]) {
        for folder in folders where deniedByIndex.count < Self.deniedLimit { deniedByIndex.insert(folder) }
    }

    /// Writes the per-volume explanation; call once, when the search ends.
    func fill(_ coverage: inout SearchCoverage, spotlightAnswered: Bool, searchedContents: Bool) {
        var merged = findings
        if coverage.phase == .stopped {
            for root in scanRoots {
                guard let volume = WholeMacCoverage.volume(holding: root.path, in: volumes), volume.kind != .startup,
                      merged[volume.url.path]?.scan ?? .notRun == .notRun else { continue }
                merged[volume.url.path, default: SearchVolumeFindings()].scan = .cutShort
            }
        }
        for folder in deniedByIndex.sorted() {
            coverage.addDenied(folder)
            if let volume = WholeMacCoverage.volume(holding: folder, in: volumes) {
                merged[volume.url.path, default: SearchVolumeFindings()].denied += 1
            }
        }
        coverage.locations = WholeMacCoverage.locations(volumes: volumes, indexStates: states, findings: merged,
                                                        spotlightAnswered: spotlightAnswered || !source.runsSpotlight)
        coverage.locationNotes = WholeMacCoverage.notes(searchedContents: searchedContents)
    }
}
