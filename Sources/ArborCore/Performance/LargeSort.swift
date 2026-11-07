import Foundation

/// Sorting for large listings (FE-228): exactly the order of `FileSorter.precedes`, computed faster.
///
/// Measured on a 100,000-entry folder (docs/PERFORMANCE.md): `String.localizedStandardCompare` bridges
/// both strings on every comparison, so sorting by name took ~400 ms on the main thread. Here names and
/// kinds are converted to `CFString` once and compared with the same Core Foundation call and options
/// `localizedStandardCompare` uses; listings above `parallelThreshold` are sorted in chunks on all cores
/// and merged. Orders that read extra Details columns (metadata lookups, main-thread state) stay
/// single-threaded.
enum LargeSort {
    static let threshold = 2_000
    static let parallelThreshold = 16_000

    static func sorted(_ items: [FileItem], by order: FileSortOrder, parallel: Bool = true) -> [FileItem] {
        // Folders are listed pre-sorted in the background (FolderProvider); one linear check then saves
        // the main thread the whole sort. An unsorted list fails the check at its first pair or so.
        if isSorted(items, by: order) { return items }
        let keys = Keys(items, order)
        var index = Array(0..<items.count)
        if parallel, items.count >= parallelThreshold, keys.isThreadSafe {
            parallelSort(&index) { keys.precedes($0, $1) }
        } else {
            index.sort { keys.precedes($0, $1) }
        }
        return index.map { items[$0] }
    }

    static func isSorted(_ items: [FileItem], by order: FileSortOrder) -> Bool {
        guard items.count > 1 else { return true }
        for i in 1..<items.count where FileSorter.precedes(items[i], items[i - 1], order) { return false }
        return true
    }

    /// The options `-[NSString localizedStandardCompare:]` passes to Core Foundation.
    static let standardFlags: CFStringCompareFlags = [.compareCaseInsensitive, .compareNonliteral, .compareNumerically,
                                                      .compareWidthInsensitive, .compareForcedOrdering]

    static func standardCompare(_ a: CFString, _ b: CFString, locale: CFLocale?) -> ComparisonResult {
        switch CFStringCompareWithOptionsAndLocale(a, b, CFRange(location: 0, length: CFStringGetLength(a)), standardFlags, locale) {
        case .compareLessThan: return .orderedAscending
        case .compareGreaterThan: return .orderedDescending
        default: return .orderedSame
        }
    }

    final class Keys: @unchecked Sendable {
        let items: [FileItem]
        let order: FileSortOrder
        let names: [CFString]
        let types: [CFString]
        let locale = CFLocaleCopyCurrent()
        /// True when no comparison reads `FileSorter.columnValues`.
        let isThreadSafe: Bool

        init(_ items: [FileItem], _ order: FileSortOrder) {
            self.items = items
            self.order = order
            names = items.map { NSString(string: $0.name) as CFString }
            let criteria = [order.column ?? ColumnID(order.key.rawValue)] + order.thenBy.map(\.column)
            types = criteria.contains(ColumnID(SortKey.type.rawValue))
                ? items.map { NSString(string: $0.typeDescription) as CFString } : []
            isThreadSafe = criteria.allSatisfy { SortKey(rawValue: $0.rawValue) != nil }
        }

        func precedes(_ a: Int, _ b: Int) -> Bool {
            let x = items[a], y = items[b]
            if order.foldersFirst, x.isFolder != y.isFolder { return x.isFolder }
            let primary: ComparisonResult
            if let column = order.column {
                primary = FileSorter.compareColumn(x, y, column, ascending: order.ascending)
            } else {
                primary = compare(a, b, order.key, ascending: order.ascending)
            }
            if primary != .orderedSame { return primary == .orderedAscending }
            for criterion in order.thenBy {
                let result: ComparisonResult
                if let key = SortKey(rawValue: criterion.column.rawValue) {
                    result = compare(a, b, key, ascending: criterion.ascending)
                } else {
                    result = FileSorter.compareColumn(x, y, criterion.column, ascending: criterion.ascending)
                }
                if result != .orderedSame { return result == .orderedAscending }
            }
            let byName = standardCompare(names[a], names[b], locale: locale)
            if byName != .orderedSame { return byName == .orderedAscending }
            if x.name != y.name { return x.name < y.name }
            return x.url.path < y.url.path
        }

        private func compare(_ a: Int, _ b: Int, _ key: SortKey, ascending: Bool) -> ComparisonResult {
            func directed(_ r: ComparisonResult) -> ComparisonResult { ascending ? r : r.reversed }
            switch key {
            case .name: return directed(standardCompare(names[a], names[b], locale: locale))
            case .type: return directed(standardCompare(types[a], types[b], locale: locale))
            case .dateModified: return FileSorter.compareOptional(items[a].modified, items[b].modified, directed)
            case .size: return FileSorter.compareOptional(items[a].size, items[b].size, directed)
            }
        }
    }

    /// Sorts chunks concurrently, then merges neighbouring runs level by level (also concurrently).
    /// `less` must be safe to call from several threads.
    static func parallelSort(_ index: inout [Int], _ less: @escaping (Int, Int) -> Bool) {
        let n = index.count
        let chunks = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        guard n > 1, chunks > 1 else { index.sort(by: less); return }
        let size = (n + chunks - 1) / chunks
        var runs: [Range<Int>] = stride(from: 0, to: n, by: size).map { $0..<min($0 + size, n) }
        var scratch = [Int](repeating: 0, count: n)
        var resultInScratch = false
        index.withUnsafeMutableBufferPointer { main in
            scratch.withUnsafeMutableBufferPointer { other in
                let mainBase = main.baseAddress!, otherBase = other.baseAddress!
                let sortRuns = runs
                DispatchQueue.concurrentPerform(iterations: sortRuns.count) { i in
                    let r = sortRuns[i]
                    var chunk = UnsafeMutableBufferPointer(start: mainBase + r.lowerBound, count: r.count)
                    chunk.sort(by: less)
                }
                var source = mainBase, target = otherBase
                while runs.count > 1 {
                    let level = runs
                    let pairs = (level.count + 1) / 2
                    let src = source, dst = target
                    DispatchQueue.concurrentPerform(iterations: pairs) { p in
                        let left = level[2 * p]
                        guard 2 * p + 1 < level.count else {
                            (dst + left.lowerBound).update(from: src + left.lowerBound, count: left.count)
                            return
                        }
                        merge(src, left, level[2 * p + 1], into: dst, less)
                    }
                    runs = (0..<pairs).map { p in
                        2 * p + 1 < level.count ? level[2 * p].lowerBound..<level[2 * p + 1].upperBound : level[2 * p]
                    }
                    swap(&source, &target)
                    resultInScratch.toggle()
                }
            }
        }
        if resultInScratch { index = scratch }
    }

    /// Stable merge of two adjacent sorted runs of `src` into the same positions of `dst`.
    private static func merge(_ src: UnsafeMutablePointer<Int>, _ left: Range<Int>, _ right: Range<Int>,
                              into dst: UnsafeMutablePointer<Int>, _ less: (Int, Int) -> Bool) {
        var i = left.lowerBound, j = right.lowerBound, k = left.lowerBound
        while i < left.upperBound, j < right.upperBound {
            if less(src[j], src[i]) { dst[k] = src[j]; j += 1 } else { dst[k] = src[i]; i += 1 }
            k += 1
        }
        while i < left.upperBound { dst[k] = src[i]; i += 1; k += 1 }
        while j < right.upperBound { dst[k] = src[j]; j += 1; k += 1 }
    }
}
