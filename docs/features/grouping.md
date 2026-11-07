# Details view depth: grouping, column filters, columns

Slot: "grouping and column filters" (`DetailsDepth.register()` in `Features.swift`).
Code: `Sources/ArborCore/{DetailsColumns,Grouping,MetadataReader}.swift`, `Sources/Arbor/Features/DetailsDepth/`,
plus row-model changes in `Views/DetailsViewController.swift`. Tests: `Tests/ArborCoreTests/DetailsDepthTests.swift`.

## Status

| FE-ID | What | Status | How verified |
|---|---|---|---|
| FE-035 | Column chooser: header right-click (Size column to fit · Size all columns to fit · common columns · More…), Choose Details sheet (search, check boxes, Move Up/Down, Show/Hide, width), drag to reorder (Name stays first), resize, fit | Implemented | Script `headermenu`, `choosedetails`/`cd*`, sheet snapshot (dark); unit tests for `ColumnSet` |
| FE-036 | More columns: Date created, Date accessed, Size on disk, Tags, Date, Dimensions, Width, Height, Date taken, Camera model, Length, Bit rate, #, Title, Authors, Contributing artists, Album, Genre, Year, Pages, Comments | Implemented (values depend on Spotlight / file parsers) | Fixture images (Dimensions 64 x 48), AIFF/M4A (Length 00:00:02), Finder tags, unit test on a generated PNG |
| FE-038 | Group by: None, Name, Date modified, Type, Size, Date created (+ any shown column), Ascending/Descending, collapsible headers, header click selects the group, keyboard across groups | Implemented | Unit tests (buckets with fixed now/time zone/first weekday); scripts `groupby`, `collapse`, `key:` (↑↓ across headers, ← collapse, Return toggles), `groupclick`, rename in a grouped view; light + dark snapshots |
| FE-039 | Column header filters: hover ▾, checklist of buckets, AND across / OR within, ✓ on filtered headers, "N of M items", Clear Filters | Implemented; no date calendar picker | Unit tests; scripts `filter`, `filtermenu`, `openfilter` + `snapshotpopover`; status "3 of 15 items" |
| FE-040 | Column sets per folder kind (General, Documents, Pictures, Music, Videos, Downloads) | Partial by design: column sets + `ViewOptions` API only; the Folder Options UI ("Optimize this folder for", Apply to Folders) belongs to that feature | Fixture `Photos/` folder discovered as Pictures (Name, Date, Type, Size, Tags, Dimensions); unit tests |
| FE-051 | Readable numeric metadata | Partial: numeric values right-aligned, unknown vs zero vs not-applicable kept apart, "Size on disk" (allocated) column next to Size (logical). Size column still uses the core adaptive format, not Explorer's always-KB | Snapshots; unit tests for formatting |
| FE-235 | Sort by any shown column; previous key becomes the tie-breaker; stable ties (name, then path) | Implemented | Unit tests (`previousKeyBreaksTies`, `secondaryKeysAreBoundedAndUnique`, loading values last); script `sortcol:dimensions:desc` |

## How it fits together

- **Pipeline.** `TabState.visibleItems` = search filter → `TabState.visibleItemsFilter` (column filters, this feature) →
  `FileSorter` (any column via `FileSorter.columnValues`). Grouping happens in the view (`FileGrouper.group`), so commands
  that use `window.visibleItems` still see the flat sorted list.
- **Per-tab state** lives in `ViewOptions.options(for: tab)` (`TabViewOptions`: columns, groupBy, groupAscending, collapsed
  groups, filters). It resets when the tab shows another location; Group by is remembered per folder for the session
  (Back restores it).
- **Metadata.** `ColumnValueStore.shared` (bounded LRU, 4,000 items; key = path + modification date) reads values on a
  2-thread utility queue. The Details view requests visible rows ± a margin and cancels on scroll/navigation. Sorting,
  grouping or filtering by a metadata column requests that one column for the whole folder (also cancellable), then
  `DetailsDepth.refresh(tab)` re-sorts. Missing values sort last and group under "Loading…".
- **Header.** The stock `NSTableHeaderView` is kept (subclassing breaks row drawing on macOS 26). `HeaderOverlayView` is a
  subview drawn on top: Explorer's small sort chevron above the title, the ▾ on hover and a ✓ on filtered columns; clicks
  pass through except on the ▾. Header clicks sort through `tableView(_:didClick:)`; the table keeps no sort descriptors so
  the Mac triangle isn't drawn.

## Using grouping from other view layouts (icon views)

The grouped model is plain ArborCore data, so an icon/list/tiles view can adopt it:

```swift
// In your ItemViewController.display(_ update:):
let tab = (itemDelegate as? BrowserWindowController)?.activeTab
let options = tab.map(ViewOptions.options(for:))
let groups: [ItemGroup] = options?.groupBy.map {
    FileGrouper.group(update.items, by: $0, ascending: options!.groupAscending, lookup: DetailsDepth.lookup)
} ?? []
// groups[i].bucket.title / .id, groups[i].items (already sorted). Collapsed: options.collapsed.contains(bucket.id).
// Use NSCollectionView sections, one per group; draw the header with GroupHeaderCellView.configure(title:count:collapsed:).
```

Group by commands (`group.<column>`, `group.none`, `group.ascending/descending`) already call `DetailsDepth.refresh(tab)`,
which redisplays the active tab whatever the view mode. Toggle a group with `options.collapsed` and redisplay. Metadata
columns used for grouping are loaded for the whole folder by the pipeline hook, so a view only has to redisplay.

## API for the Folder Options / persistence feature

- `ViewOptions.folderKindResolver = { location, items in FolderKind }` picks the template. Default: known folders
  (Downloads, Pictures, Music, Movies → Videos, Documents) and their subfolders (not for Downloads), else content discovery
  (`FolderKind.discover`: ≥ 3 files, ≥ 70 % images/audio/video), else General items.
- `ViewOptions.columnSet(for:)`, `setColumnSet(_:for:)`, `resetColumnSets()`; stored as JSON in `Prefs.store` under
  `details.columnSets`. `ColumnSet.defaults(for:)` has the Windows defaults (Downloads: grouped by Date modified, descending).
- `ColumnCatalog.register(ColumnDescriptor(..., source: .listing, listingValue: { item in … }))` adds a column (e.g. Trash
  "Date deleted"); it then appears in Choose Details, Sort ▾ (when shown), Group by and filters.

## Script steps (headless checks)

`groupby:<column|none>`, `groupdir:asc|desc`, `collapse:<title>`, `expand:<title>`, `groupclick:<title>`, `key:<keycode>`,
`filter:<column>:<bucket title>`, `clearfilters`, `filtermenu:<column>:<path>`, `openfilter:<column>`,
`snapshotpopover:<png>`, `headerhover:<column>`, `columns:<id,id,…>`, `showcolumn:<id>`, `hidecolumn:<id>`,
`sortcol:<id>[:desc]`, `headermenu:<path>`, `choosedetails`, `cdsearch:<text>`, `cdselect:<title>`, `cdwidth:<n>`,
`cdup`, `cddown`, `cdshow`, `cdhide`, `snapshotsheet:<png>`. `log:` adds lines: details kind/sort/group, filters, columns,
groups, table rows (headers in brackets), focused rows, and metadata cell states (loading/unknown/unsupported/empty/value).

Example (fixture made with `touch -t` dates, `sips` images, `say`/`afconvert` audio):

```bash
ARBOR_HEADLESS=1 ARBOR_APPEARANCE=dark ARBOR_SCRIPT="wait:1.5;groupby:dateModified;groupdir:desc;log:$OUT/log.txt;snapshot:$OUT/g.png;quit" \
  build/Arbor.app/Contents/MacOS/Arbor "$FX"
```

## Decisions

| ID | Decision | Why |
|---|---|---|
| DEC-grouping-1 | Date buckets have chronological ranks: Ascending = oldest first ("A long time ago" … "Today"), Descending = Today first. Downloads defaults to Descending | Matches sorting semantics and Explorer's Downloads (grouped, Today first). Reference §6.1 lists Today first without stating the direction (RECALL) |
| DEC-grouping-2 | Week start, day boundaries and months follow the user's calendar (`Calendar.autoupdatingCurrent`: locale first weekday, time zone). "Yesterday" wins over "Last week" | Locale-aware like Windows; testable with an injected calendar |
| DEC-grouping-3 | Future dates: "Later this week", "Next week", "In the future" | Reference RECALL-l |
| DEC-grouping-4 | Name groups in the reference order A – H · I – P · Q – Z · 0 – 9 · Other; accents folded, non-Latin letters → Other | Reference §6.1 (RECALL-l) |
| DEC-grouping-5 | Size buckets use 16 KB / 1 MB / 128 MB / 1 GB / 4 GB (inclusive upper bounds, 1 KB = 1024 B); folders → Unspecified, always last | Reference §6.1 |
| DEC-grouping-6 | Multi-valued columns (Tags, Authors): an item is grouped under its first value (sorted) but matches a filter on any value | Avoids duplicate rows, which would break selection identity |
| DEC-grouping-7 | Group headers are selectable rows only on their own (keyboard focus); multi-selections drop them; header click selects the group's visible items; Select All selects the items of expanded groups; selecting names that are all hidden in collapsed groups (new item, rename, Select All with every group collapsed) expands those groups | Reference §6.2; selection must never include invisible targets |
| DEC-grouping-8 | Clicking a header sorts by it; clicking again reverses. The previous primary column becomes the first tie-breaker (max 2), then name, then path | FE-235 asks for explicit, stable multi-key order without assuming Shift-click; mirrors the shell's ordered sort-column list (R08) |
| DEC-grouping-9 | Column header texts are left-aligned (Explorer); numeric values right-aligned in cells | Reference screenshots; leaves the right edge free for the ▾ |
| DEC-grouping-10 | Cell states: loading "…" (dimmed), unknown "—" (dimmed), empty and not-applicable blank (like Explorer); tooltips and accessibility labels say which | Spec §6.2/§16.1 require the distinction; blank keeps media columns readable |
| DEC-grouping-11 | Spotlight's title is ignored when it equals the file name | Unindexed files report the name as kMDItemTitle, which isn't a title |
| DEC-grouping-12 | Filters, collapsed groups and the column set reset when the tab navigates; Group by is remembered per folder for the session only | Filters are per-folder views; persistent per-folder views are Folder Options' job |
| DEC-grouping-13 | Columns are saved per folder kind (`details.columnSets`) instead of table autosave | Column sets differ per kind (FE-040) |
| DEC-grouping-14 | Filtered columns that get hidden lose their filter | An invisible filter would hide items with no visible cause |
| DEC-grouping-15 | Windows "Categories" column is not offered | No Mac counterpart (DEC-019) |

## Known gaps

- No calendar picker in date filter dropdowns (Windows has one); only the date buckets.
- The address bar doesn't switch to "<folder> › Filtered"; the status bar shows "N of M items" and headers show ✓.
- Column sets per kind are in memory + one preference key; "Optimize this folder for", Apply to Folders and Reset Folders
  UI are for the Folder Options feature (API above).
- Size column keeps the core adaptive format (Explorer always shows KB); unchanged to avoid conflicting with core.
- Collapsed groups aren't persisted; Select All selects only items of expanded groups.
- Metadata for video files needs Spotlight or AVFoundation (bounded 5 s wait per file); no video fixture was tested.
- Hover ▾ needs a key window (tracking area); verified via the `headerhover`/`openfilter` steps, not real mouse hover.
- Icon views don't group yet (no icon views on this branch); see "Using grouping from other view layouts".
