import Foundation
import ArborCore

/// One background run: Spotlight for names, a few files for colours. Started and cancelled on the main thread.
final class FinderTagDiscovery {
    /// `isComplete` is false when the run can't vouch for tags it didn't see.
    typealias Completion = (_ job: FinderTagDiscovery, _ catalog: TagCatalog, _ isComplete: Bool) -> Void

    private let queue = DispatchQueue(label: "Arbor tag discovery", qos: .utility)
    private let cancellation = ScanCancellation()
    private let completion: Completion
    private var harvest: TagHarvest
    private var sawHits = false
    private var spotlight: SpotlightSearch?

    init?(seed: TagCatalog, completion: @escaping Completion) {
        harvest = TagHarvest(catalog: seed)
        self.completion = completion
        guard let predicate = TagCollectionQuery.allTaggedSpotlightQuery else { return nil }
        spotlight = SpotlightSearch(predicate: predicate, scope: nil, onHits: { [weak self] hits in
            self?.queue.async { self?.absorb(hits) }
        }, onFinish: { [weak self] outcome in
            self?.queue.async { self?.deliver(outcome) }   // after the last batch
        })
        guard spotlight != nil else { return nil }
    }

    func start() { spotlight?.start() }

    /// A read stuck on a slow disk can't be interrupted, but nothing queued behind it does any work.
    func cancel() {
        cancellation.cancel()
        spotlight?.cancel()
    }

    private func absorb(_ hits: [SpotlightSearch.Hit]) {
        for hit in hits {
            guard !cancellation.isCancelled else { return }
            sawHits = true
            guard harvest.add(FinderMetadata.finderTags(fromStored: hit.tags ?? [])) else { continue }
            harvest.addColors(FinderMetadata.finderTags(of: URL(fileURLWithPath: hit.path)))
        }
    }

    private func deliver(_ outcome: SpotlightSearch.Outcome) {
        guard !cancellation.isCancelled else { return }
        let catalog = harvest.catalog
        let isComplete = sawHits && outcome == .finished   // an empty answer also means Spotlight is off or refused the query
        DispatchQueue.main.async { [self] in completion(self, catalog, isComplete) }
    }
}
