# Memory and responsiveness

Code: `Sources/Arbor/Features/Performance/` (registered by `PerformanceFeature.register()` in `Features.swift`), logic in
`Sources/ArborCore/Performance/`, tests in `Tests/ArborCoreTests/PerformanceTests.swift`, benchmarks in `scripts/bench.sh`
and `scripts/bench-fixtures.swift`. Measurements, budgets and method: [docs/PERFORMANCE.md](../PERFORMANCE.md).

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-228 | Large directory responsiveness | implemented (measured) | 100,000-entry folder: rows on screen 3.0 s → 0.68 s, peak 197 → 128 MB, longest main-thread stall while opening 777 → 68 ms (242 ms worst while sorting), sorts 290–550 ms → 50–240 ms; `scripts/bench.sh` workload `large`; unit tests prove the faster sort gives the identical order |
| FE-229 | Stable live updates | implemented | folder-change bursts throttled (first change after 0.15 s, then at most one reload a second, last change never lost); unchanged background reloads keep rows, selection and scroll untouched; unit tests for the throttle |
| FE-243 | Decoded-image memory cost | implemented | thumbnails budgeted by decoded bytes (existing 64 MB LRU), now trimmed through the shared registry; `media` workload: Preview pane churn and closing the pane return to the thumbnail plateau |
| FE-251 | Global cache and inactive-tab budgets | implemented | one table of byte budgets (`CacheBudgets`); icons and inactive-tab listings moved from counts to bytes; one memory-pressure listener trims every registered cache; inactive tabs drop their sorted copy; `tabs` workload plateaus |
| FE-252 | Cold/warm and retained-growth benchmark protocol | implemented | `scripts/bench.sh` (7 workloads, repeats, first-run vs median, environment record), `--check` against `scripts/bench-budgets.txt` |

## Decisions

- **DEC-performance-1** Gate metric is physical footprint (`phys_footprint`, what Activity Monitor and `footprint(1)` show),
  read in-process by the `memlog:` step; resident size is logged for context only (spec §15.3).
- **DEC-performance-2** The Type column comes from Launch Services once per extension (first file's answer reused), not once
  per file; packages, links, aliases, extension-less files and folders with an extension are still asked individually.
  Unit test compares against the per-file answer for 27 kinds of items.
- **DEC-performance-3** File icons are looked up per type for ordinary files; per file for apps, icon files, links and files
  without an extension. A file with a custom Finder icon but an ordinary extension shows its type icon (Explorer also shows
  type icons except for executables and shortcuts).
- **DEC-performance-4** Inactive tabs keep their listing within a shared 48 MB budget (least recently used evicted first;
  an evicted tab lists its folder again when selected) instead of "the last 8 listings", which allowed ~0.7 GB with large
  folders.
- **DEC-performance-5** Budgets in docs/PERFORMANCE.md are proposals with measurements behind them; `--check` allows a
  25 % margin (`BENCH_MARGIN`) because runs share the machine with other work.
- **DEC-performance-6** Plain background views paint through their layer's background colour instead of a drawn bitmap
  (`ThemeBackgroundView`); snapshots still use `draw(_:)`. An extra window went from ~25 MB to ~9 MB.

## Shared files touched (small, additive)

`DebugScript.swift` (wait steps, current step name), `Features.swift` (one line), `Theme.swift` (`ThemeBackgroundView`
layer path), `DetailsViewController.swift` (view-recycling reload, lazy check box, background release),
`BrowserWindowController.swift` (coalesced volume rebuild, quiet reloads), `TabState.swift` (byte-budgeted listings),
`IconProvider.swift` (byte budget, per-type icons), `FileSystemSupport.swift` (throttled watcher, cached volume check
while dragging), `NavigationPaneExtras.swift` (coalesced refresh), `FolderProvider.swift` (background pre-sort),
`ArchiveProvider.swift` (trim/count), `ThumbnailService.swift` (budget from `CacheBudgets`), ArborCore `FileItem`,
`DirectoryLister`, `Sorting`, `Location.isVolumeRoot`, `SystemItems`, `FolderViewSettings`.

## Known gaps

- Listing is still all-or-nothing: the first rows of a 100,000-entry folder appear when the whole listing is read and sorted
  (~0.7 s on the reference Mac). Progressive first rows would need an incremental, sorted insert into the view.
- About 40 MB stays with the process after leaving a 100,000-entry folder: freed memory the allocator keeps (live heap
  is back to ~17 MB, verified with `heap`); it is reused by the next large listing.
- Each extra window costs ~9 MB (its own view tree and layers).
- Idle CPU is dominated by volume mount notifications when other software mounts disk images; the `idle` line reports how
  many arrived during the measurement.
- Remote-storage and optional-index workloads of spec §15.4 are not part of the harness yet.
