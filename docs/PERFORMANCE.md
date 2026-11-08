# Performance: memory and responsiveness

Low RAM and a responsive window are owner requirements (spec §15.1). This page records how Arbor is measured, what was
measured, the budgets proposed from those measurements, and what changed to meet them. Feature status and decisions:
[docs/features/performance.md](features/performance.md).

## Proposed budgets

Measured on the reference Mac (an Apple silicon laptop with 16 GB of memory, macOS 26, release build) with the
fixtures below. Budgets leave room for slower Macs; `scripts/bench.sh --check` fails a run whose median exceeds a budget
by more than 25 %. They are proposals for the owner to confirm (spec §15.4: "agree targets before enforcing numbers").

| Area | Budget | Measured (median) | Metric in `scripts/bench-budgets.txt` |
|---|---|---|---|
| Idle, one folder open | ≤ 45 MB footprint | 36 MB | `idle.idle.footprint_mb` |
| Time to first drawn folder | ≤ 600 ms | 312 ms | `idle.launch.first_content_ms` |
| Idle CPU | ≤ 2 ms per second | 0.2 ms/s | `idle.idle.cpu_ms_per_s` |
| Opening a 1,000-entry folder | p95 ≤ 60 ms | p50 16 ms, p95 26 ms | `browse.nav.p95_ms` |
| Browsing 50 folders, retained growth | ≤ 6 MB | 1.9 MB | `browse.retained_growth_mb` |
| 20 tabs | ≤ 70 MB total, ≤ 1.2 MB per tab | 52 MB, 0.8 MB/tab | `tabs.open1.footprint_mb`, `tabs.per_tab_mb` |
| Tabs opened and closed 3 times | plateau ≤ 4 MB | +1.8 MB | `tabs.plateau_growth_mb` |
| 5 windows | ≤ 120 MB | 96 MB | `tabs.windows1.footprint_mb` |
| Windows opened and closed 3 times | plateau ≤ 3 MB | +0.3 MB | `tabs.window_plateau_growth_mb` |
| 100,000-entry folder: rows on screen | ≤ 1.2 s | 0.68 s | `large.first.ms` |
| 100,000-entry folder: peak footprint | ≤ 170 MB | 128 MB | `large.big.peak_mb` |
| 100,000-entry folder: longest main-thread stall while opening/leaving | ≤ 150 ms | 68 ms | `large.large.max` |
| 100,000-entry folder: longest stall while sorting and scrolling | ≤ 350 ms | 77 ms (sorts run in the background; was 242 ms) | `large.large_details.max` |
| 100,000-entry folder: scroll frame | p95 ≤ 12 ms | 4.4 ms | `large.details.p95_ms` |
| After leaving the 100,000-entry folder (twice) | ≤ 110 MB | 94 MB | `large.away2.footprint_mb` |
| Thumbnails of 60 12-megapixel photos | ≤ 70 MB | 48 MB | `media.thumbs.footprint_mb` |
| After Preview pane churn and closing it | ≤ 80 MB | 58 MB | `media.paneclosed.footprint_mb` |
| 100 changing searches | final results ≤ 1.5 s, 0 stale rows, growth ≤ 6 MB | 0.73 s, 0, +1.7 MB | `search.*` |
| Copies (3,000 small files; 512 MB file) | ≤ 16 MB extra while copying | 2.3 MB; 0 MB | `copy.*.peak_delta_mb` |

App-wide cache budgets (`CacheBudgets` in `Sources/ArborCore/Performance/CacheRegistry.swift`): decoded thumbnails 64 MB,
icons 12 MB, inactive tabs' listings 48 MB. Bounded by count instead (small entries): Details metadata (4,000 rows), archive
directories (4), search sessions (4, each ≤ 10,000 results), image dimensions, text measurements per icon view. All of them
are trimmed when the system reports memory pressure (warning: to a quarter, critical: emptied).

## Before and after

Same Mac, same fixtures, back to back, 3 launches each; "before" is the app at the start of this work (with the
measuring steps added), "after" the current code. Medians.

| Metric | Before | After |
|---|---|---|
| Idle footprint | 56.8 MB | 36.3 MB |
| Time to first drawn folder | 381 ms | 312 ms |
| Idle CPU | not measurable¹ | 0.2 ms/s |
| 1,000-entry folder navigation p50 / p95 | 85 / 87 ms | 16 / 26 ms |
| Browsing retained growth (round 5 − round 1) | 6.3 MB | 1.9 MB |
| 20 tabs: footprint / increment over 1 tab | 101.6 / 44.6 MB | 51.5 / 15.1 MB |
| Tabs plateau (closed, cycle 3 − cycle 1) | 1.4 MB | 1.8 MB |
| 5 windows | 192.4 MB | 96.1 MB |
| Windows plateau (closed, cycle 3 − cycle 1) | 0.3 MB | 0.3 MB |
| 100k folder: rows on screen, first visit / revisit | 3,027 / 2,975 ms | 676 / 671 ms |
| 100k folder: footprint / peak | 196 / 197 MB | 127 / 128 MB |
| 100k sort by size / type / name / reversed | 293 / 461 / 547 / 453 ms | 98 / 242 / 51 / 225 ms |
| 100k longest stall opening and leaving | 777 ms | 68 ms |
| 100k longest stall while sorting and scrolling | 811 ms | 242 ms |
| 100k Details scroll frame p95 | 6.6 ms | 4.4 ms |
| After leaving the 100k folder twice (absolute) | 116.9 MB | 93.4 MB |
| Thumbnails shown / after Preview churn / pane closed | 61.0 / 72.6 / 77.8 MB | 47.5 / 59.2 / 57.8 MB |
| Search churn: final results / stale rows / growth | 733 ms / 0 / 3.5 MB | 733 ms / 0 / 1.7 MB |
| Copy 3,000 small files / 512 MB file | 337 / 9 ms | 335 / 9 ms |

¹ The first harness measured idle CPU while its own wait step polled every 5 ms (18 ms/s in both builds). `idle:` now
pauses the script instead; the corrected figure exists only for the current build.

## What was found and changed

| Finding (how it was found) | Change |
|---|---|
| Listing a 100,000-entry folder took 2.5 s in the background, 1.3 s of it Launch Services computing the localized kind of every file (`sample` of the `large` workload) | Kind looked up once per extension and reused (`TypeDescriptions`); listing streamed in batches of 4,096 with rows built in parallel; prefetched resource values dropped from each kept URL (−0.4 KB per row) |
| `contentsOfDirectory` held all 100,000 URLs with their value caches (1.2 KB each) before any row existed; the freed memory stayed with the process | `DirectoryLister` uses a batched enumerator: peak 197 → 128 MB |
| Sorting 100,000 rows on the main thread took 300–550 ms: `String.localizedStandardCompare` bridges both strings on every comparison | `LargeSort`: names converted once, compared with the same Core Foundation call and options (unit-tested to match exactly, including composed/decomposed and full-width text), chunks sorted on all cores and merged; folders are pre-sorted in the background in the default order, so the main thread only verifies |
| Every folder change rebuilt all visible Details cells: `NSTableView.reloadData()` discards cell views on macOS 26 (counted inits; standalone check) | `reloadKeepingViews()` (`reloadData(forRowIndexes:)`) when no group rows appear or disappear; the item check box is created only when shown. 1,000-entry navigation 85 → 16 ms |
| Folder-type detection asked for a type per file, twice per display | One lookup per extension |
| Each window carried several window-sized drawn bitmaps (IOSurface/CoreAnimation in `footprint`) | `ThemeBackgroundView` paints through its layer's background colour: each extra window ~25 MB → ~9 MB, launch footprint down by ~15 MB |
| Inactive tabs kept the last 8 listings whatever their size (8 × 100,000 rows ≈ 0.7 GB) plus a sorted copy each | Shared 48 MB byte budget (`ListingBudget`), sorted copy dropped when a tab goes inactive |
| Icon cache: 2,500 entries by count; one `NSWorkspace` lookup (disk access on the main thread) per file path | 12 MB byte budget; per-type icons for ordinary files; folders share their artwork; volume roots from the kernel mount table |
| `Location.isVolumeRoot` read file metadata on the main thread for every tab title, icon and Up button; drag hover read volume ids on every mouse move | `MountPoints` (cached `getmntinfo`, never blocks); `FileOps.sameVolumeCached` for the drag cursor only |
| Folder-watcher bursts restarted a 0.15 s timer on every event (a folder being copied into never refreshed until the copy ended) and every reload rebuilt the view | `EventThrottle`: first change after 0.15 s, then at most one reload a second, last change always applied; watcher and tab-switch reloads whose listing is unchanged leave the view alone |
| Volume (un)mount notifications rebuilt the navigation pane of every window several times per disk image, reading names on the main thread | Rebuilds coalesced (0.2–0.25 s) |
| No app-wide view of cache sizes; only thumbnails listened for memory pressure | `CacheRegistry`: one pressure listener trims thumbnails, icons, listings, metadata and archive listings; `memlog:` reports each |
| Freeing a 100,000-row listing cost ~30 ms on the main thread | Large arrays released on a background queue |

Checked and fine as they were: thumbnail decode budget and cancellation (FE-243), search cancellation (no stale rows),
copy buffers (`copyfile`, constant memory), Properties/Details pane sizes (computed off the main thread), grouping and
filtering (linear), closing tabs and windows (plateaus within 2 MB over three cycles; `heap` shows the live heap returns
to ~17 MB after leaving a large folder).

## Remaining costs

- **Freed but kept memory.** After leaving the 100,000-entry folder the footprint stays ~57 MB above launch even though the
  live heap is back to ~17 MB (`heap`): the allocator keeps partly used pages; the next large listing reuses them.
- **Rows are not progressive.** The first rows of a huge folder appear when it has been fully read and sorted (0.68 s here).
- **Re-sorting** 100,000 rows by type or in reverse takes ~210 ms, now on a background queue (the main thread's share is
  under 1 ms; `timecmd:` logs both). Orders on extra Details columns still sort on the main thread.
- **Windows** cost ~9 MB each (view tree, navigation pane, layers).
- Not covered yet: remote-storage latency/disconnect and optional-index workloads (spec §15.4).

## How to run

```bash
scripts/bench.sh                    # builds release, generates fixtures in a fresh mktemp -d, 3 launches per workload
scripts/bench.sh --check            # same, then compares the medians with scripts/bench-budgets.txt (exit 1 on failure)
scripts/bench.sh --quick --repeats 1 --workloads "idle browse"   # a fast smoke run
scripts/bench.sh --app /path/to/Other.app --out /tmp/other       # another build (before/after comparisons)
```

Everything runs headless (`ARBOR_HEADLESS=1`) on generated fixtures and never touches user files. A full run takes about
ten minutes. Results land in `build/bench/<date>/`: `results.txt` (metric, median, first run, min, max),
`environment.txt` (date, commit, app, Mac, macOS, fixture version, repeats, memory pressure at start) and one log, stall
log and stdout per launch.

### Fixtures (`scripts/bench-fixtures.swift`, version 1, deterministic)

| Folder | Content |
|---|---|
| `idle` | 40 mixed files, 10 folders |
| `browse/f01…f10` | ten folders of 1,000 entries (900 files of 12 types, 100 folders), varied sizes and dates |
| `big` | 100,000 entries (2 % folders), 12 extensions, varied sizes and dates (`--quick`: 10,000) |
| `media` | 60 JPEG photos of 4000×3000 (48 MB decoded each) and 20 PDFs of 40 pages |
| `search` | 5,000 files in 20 folders; names carry the words, contents never do |
| `copy-small/tree`, `copy-large` | 3,000 files of 4 KB in 30 folders; one 512 MB file |

### Workloads (spec §15.4)

| Workload | What it does | Main metrics |
|---|---|---|
| `idle` | launch at `idle`, wait, 5 s idle | time to first drawn folder, idle CPU (and how many volume notifications arrived meanwhile), footprint |
| `browse` | 5 rounds through ten 1,000-entry folders, then scroll | navigation latency p50/p95/max, footprint after rounds 1 and 5, stalls |
| `tabs` | 3 cycles: open 19 tabs (repeated and different folders), close them; 3 cycles: open and close 4 windows | footprint per tab, plateau after closing, per window |
| `large` | open `big`, sort by size/date/type/reverse/name, scroll Details 150 pages and Large icons 60 pages, leave, revisit, leave | rows on screen (first visit and revisit), sort times, frame times, stalls, footprint and peak, memory after leaving |
| `media` | Extra large icons of `media`, wait for thumbnails, scroll, Preview pane over 30 files, close the pane, leave | footprint with thumbnails, after preview churn, after closing |
| `search` | 3 × (100 queries typed faster than the search delay, every fifth slow enough to start a search the next one cancels, then a final query) | time to final results, stale rows, growth between rounds |
| `copy` | copy `copy-small/tree` and the 512 MB file to a fresh folder | duration, peak footprint increase, stalls |

### Measurement

- **Memory** is physical footprint (`task_info` `TASK_VM_INFO.phys_footprint`), sampled in-process by `memlog:` one or two
  seconds after the action: the number Activity Monitor and `footprint(1)` show. Resident size (which includes shared
  framework pages) is logged, not gated. Quick Look thumbnails and previews are generated by system services and are not
  part of Arbor's footprint; they are reported separately by the system, not summed here.
- **Main-thread stalls**: a run-loop observer times every main-thread pass and records those over 50 ms with the script step
  that was running (`stalls:` prints count, max and total per workload and the five longest). Debug builds always record
  and log stalls; release builds only with `ARBOR_SCRIPT` or `ARBOR_STALL_LOG=<file>`.
- **Times**: `nav:` from the navigation request until the rows are drawn (`displayIfNeeded`); `timecmd:` a command plus the
  redraw; `scroll:` one page of scrolling plus redraw per frame.
- **Cold versus warm**: the first launch of each workload is reported separately (`first` column) from the median. The disk
  cache is warm in both (fixtures were just written); a true cold-disk run needs `sudo purge` between launches and is not
  automated. Within a run, `large.first` is the first visit and `large.again` a revisit.
- **Repeats**: 3 launches per workload by default; `--check` compares medians.
- **Noise**: runs share the Mac with whatever else runs. The reference numbers were taken while other builds and tests were
  active, hence the 25 % margin (`BENCH_MARGIN`).

### Script steps (for new workloads)

`phase:<name>`, `memlog:<label>:<file>`, `mark:<name>` / `elapsed:<name>:<label>:<file>`, `nav:<label>:<file>:<location>`,
`newtabnav:…`, `waitload`, `timecmd:<label>:<file>:<command id>`, `scroll:<label>:<file>:<pages>`,
`idle:<label>:<file>:<seconds>`, `copy:<label>:<file>:<source>|<folder>`, `thumbwait`, `selectcycle:<label>:<file>:<n>:<s>`,
`searchchurn:<label>:<file>:<n>:<final query>`, `newwindow:<location>`, `closewindow`, `closeothertabs`,
`stalls:<label>:<file>`, `launchlog:<file>`. Each writes `key=value` lines; see `PerformanceDebug.swift`.
