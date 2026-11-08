# Search (Explorer-style)

Spec: spec §10, §15.3–15.4, §16.1; FE-131–FE-146, FE-236, FE-237. Reference: windows11-reference.md §12, §12.1, §12.2.
Code: `Sources/Arbor/Features/Search/` (controller, provider, session, Spotlight adapter, commands), `Sources/ArborCore/Search/`
(AQS parser, evaluator, Spotlight translation, direct scan, readers, history, saved-search format, coverage).
Tests: `Tests/ArborCoreTests/SearchQueryTests.swift`, `SearchEngineTests.swift`.

## How it works

Typing in "Search <location>" starts a search after a 0.6 s pause, or at once on Return. The search opens a `.search` location in the
current tab: "Search Results in <folder>". It covers the folder **and its subfolders**. Refining the query replaces that history entry,
so Back returns to the folder with its selection restored. Clearing the box, Esc, or "Close search" goes back too. Two engines run side
by side, and their hits are merged by file identity (device+inode; hard links stay separate):

1. **Spotlight** (`NSMetadataQuery` scoped to the folder, or the whole Mac for This Mac). The query is translated to MDQuery syntax. The
   translation is always a superset, and every hit is re-checked locally. The query stops after gathering, with a 20 s timeout.
2. **Direct scan** (`DirectSearch`): 4 workers, BFS, cancellable. Symbolic links are never followed, and each directory is entered once
   (by device+inode). Hidden items and package contents are skipped unless asked, and other mounted disks are not entered. Results
   arrive in batches of 64 or every 0.15 s and are capped at 10,000.

Finished searches stay fresh from FSEvents (FE-146): matches are added, removed or updated, and lost events mark the results "may be
stale". Sessions are kept in an LRU of 4. A running search is cancelled on every keystroke that changes the query and when no tab shows
it; reopening a stopped search reruns it. Refresh (F5 or the address bar) reruns.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-131 | Current folder search: subfolders by default; Search options ▸ Current folder / All subfolders; scope shown in the address bar ("Search Results in X") and the coverage dialog | Implemented | Fixture runs: nested results, Current folder narrowed them, Back restored the folder selection |
| FE-132 | Whole-computer search | Partial | From This Mac: Spotlight index only, labeled "Search incomplete: only places in the Spotlight index were searched". Not run headless (it would touch real user files) |
| FE-133 | Name vs content modes | Implemented | Free text = name. Advanced options ▸ File contents adds contents; `content:` targets contents only. The Match column says Name / Contents. Unit tests + fixture run |
| FE-134 | AQS subset (see the compatibility table below) | Implemented | 120+ parser/evaluator assertions |
| FE-135 | Search history dropdown (recent searches, filtered as you type, remove one, Clear search history) | Implemented | Fixture runs (`log`, light and dark `dropdownsnap`); unit tests for refine/dedupe/cap |
| FE-136 | Search options ▾: Date modified ▸, Kind ▸, Size ▸, Other properties ▸, Advanced options ▸. Choosing a filter adds it to the query, replacing an earlier one; checkmarks show active filters; choosing again removes it | Implemented | `searchmenu` dump, `searchopt` runs, `AQSQueryEditor` tests |
| FE-137 | Result details: Folder column (all Details groupings), Match column, "Folder:" in the Content layout and icon infotips, Open file location (selects the item) | Implemented | Snapshots (Details, grouped, Content), `searchrows`, Open file location run |
| FE-138 | Save search → JSON `.arborsearch` (query, scope path + volume UUID + bookmark, options, version); opening it reruns the search | Implemented | Round-trip unit tests; headless save, close, open, results back |
| FE-139 | Edge cases: System files (hidden items + package contents), Zipped files (zip central directory; the archive is the result, "In archive: path"), text-file contents. Localized syntax: see FE-237 | Implemented / boundary | Fixture runs, unit tests. Not supported: ZIP64, other archive formats (counted as "archives couldn't be read") |
| FE-140 | Indexing integration: `mdutil -s` per volume; "Change indexed locations…" opens System Settings ▸ Spotlight | Implemented | Unit test for output parsing; the settings link isn't clicked headless |
| FE-141 | Unindexed search: direct scan, cancellable, reports denied folders | Implemented | Fixture with a `chmod 000` folder → "Search incomplete: 1 folder couldn't be opened (access denied)" + path in details |
| FE-142 | Semantic / cloud search | Boundary | Not built. No equivalent API; cloud placeholders are not downloaded to read their contents |
| FE-143 | Spotlight adapter | Implemented | Translation unit tests. Fixtures live in temp folders Spotlight doesn't index, so live index results weren't observed headless |
| FE-144 | Why a result is absent: status line plus Search options ▸ "Why might results be missing?" (denied, unreadable, offline scope, not indexed, index timeout, unchecked contents, unreadable archives, other disks skipped, result cap, stopped, stale) | Implemented | `searchdetails` output, coverage unit tests |
| FE-145 | Name-first ranking | Implemented (later, in docs/features/consistency.md #5) | Relevance (exact name, prefix, substring, contents) is the default order of results; name and content matches are also labeled separately (Match column) |
| FE-146 | Freshness | Implemented | Fixture run: a file created during the session appeared, a deleted one vanished, with no rerun |
| FE-236 | Mixed AND/OR left to right; parentheses override | Implemented | Parser tests plus a data test where the result differs from AND-before-OR |
| FE-237 | Canonical `System.*` names are the internal identity, independent of UI language; unknown or localized labels are rejected visibly | Implemented | Tests: every canonical name round-trips; `größe:`, `taille:` and `foo:` give errors |

### AQS compatibility table (`AQSParser`)

| Construct | Arbor |
|---|---|
| `word` | Name contains (case-, accent- and width-insensitive); with File contents, also text contents |
| `"exact phrase"` | Name contains the phrase |
| `*.txt`, `re?ort` | DOS wildcards on the whole name |
| `AND` / `OR` / `NOT`, uppercase only; juxtaposition = AND; `-term`; `( )` | Left-to-right folding (FE-236). Lowercase `and`/`or` are words |
| `name:`/`filename:`/`file:` | Name: contains, `=` exact, `~<` begins with, `~` wildcard, `~=` contains, `~!` doesn't contain, `<>` not equal |
| `ext:`/`fileext:`/`fileextension:`/`extension:` | Whole extension (`ext:doc` ≠ .docx), leading dot optional, wildcards allowed |
| `kind:` | folder, document, picture, music, video/movie, text, program, link, archive, email, contact, calendar, playlist, savedsearch, font, communication, unknown. Windows-only kinds (game, journal, recorded tv, web history, feed, task, note, instant message) → error |
| `type:` | Type description contains, or extension (`type:.txt`) |
| `size:` | Bytes, KB/MB/GB/TB (1,024), names empty…gigantic, `> >= < <= = <>`, ranges `1MB..5MB`. `size:>1MB` means > 1,048,576 bytes; `size:5MB` means 5.0–5.99 MB. Folders never match |
| `date:`/`datemodified:`/`modified:`, `datecreated:`/`created:` | today, yesterday, this/last/past/next week/month/year, M/D/YY(YY), YYYY-MM-DD, YYYY-MM, YYYY, operators and `..` ranges |
| `tag:`/`tags:`/`keyword(s):` | Finder tags, whole-tag match; `:=[]` = no tags |
| `author:` | Spotlight metadata only (unknown in the direct scan) |
| `content:` | Text contents (direct read of text files ≤ 4 MB, never cloud placeholders) plus the Spotlight index for other documents |
| `folder:`/`folderpath:`/`path:` | Containing folder path contains |
| `System.FileName`, `System.Size`, … (see `SearchProperty.canonicalNames`) | Same as the mnemonics |
| Anything else (unknown property, stray operator, unbalanced quotes or parentheses, bad size/date/kind) | Visible error in the results area and status bar ("Search couldn't run: …"); never silently ignored |

## Decisions

- **DEC-search-1** The search box opens a results location (replaces DEC-014's filter) in folders, Home (scope: home folder) and
  This Mac (index only). Trash, Network and other virtual places keep the in-place name filter, because their items aren't a folder tree.
- **DEC-search-2** Searches start after a 0.6 s typing pause or at once on Return. Refining a query replaces the current history entry,
  so Back goes to the folder, not to an earlier query. Return or ↓ on results already shown moves focus into them.
- **DEC-search-3** Free text matches names only (Explorer does this in non-indexed locations). Contents are opt-in (File contents)
  or explicit (`content:`), so a plain search never reads file data.
- **DEC-search-4** Coverage is three-valued. Values the scan couldn't read are "unknown", never "no match". A Spotlight hit is accepted
  on unknown parts only when the translated query was exact. The status says "Search complete" only with zero gaps.
- **DEC-search-5** System files = hidden items + package contents. Zipped files = .zip only, and the archive is the result
  ("In archive: inner/path"), so every file command acts on a real file.
- **DEC-search-6** Mnemonics are English (the UI language). Canonical `System.*` names always work. Labels from other languages are
  rejected with a message (FE-237).
- **DEC-search-7** US date order (M/D/Y, as in the documented examples) plus ISO dates. Weeks follow the system calendar's first weekday.
- **DEC-search-8** Saved searches are `.arborsearch` JSON. The save dialog defaults to Documents (macOS has no "Searches" folder). The
  scope resolves by bookmark first, then by path only on the same volume UUID, otherwise it shows as unavailable (never another disk).
- **DEC-search-9** Results are capped at 10,000 per search, labeled. The session cache holds 4. FSEvents batches over 2,000 paths mark
  results "may be stale" instead of re-evaluating.
- **DEC-search-10** Details for results: Name · Date modified · Type · Size · Folder · Match (Match is an Arbor addition for FE-137).
  The Folder path uses the scope's spelling (`/tmp/…`, not `/private/tmp/…`).
- **DEC-search-11** The address bar shows a green progress fill while searching (Explorer behavior). There's no total, so it eases
  toward 92% and completes when the search finishes.

## Hooks and shared-file changes (for maintainers)

- `SearchRequest.options` (`SearchOptions`: contents, systemFiles, zipped). Encoded as `opts=` in the location key only when set, so
  existing keys are unchanged. `NavigationHistory.replaceCurrent(with:)`.
- `SearchController.boxText(for:filterText:)` (protocol requirement with a default) is used in `BrowserWindowController.activate`.
  `LocationProvider.statusDetail(for:)` (requirement with a default nil) is appended to the status summary in `updateChrome`.
- `InteractionHooks.itemDetail`: an extra "Label: value" for layouts without columns (Content view middle column, icon infotips).
  Wired in `ItemGridView` / `ItemGridDrawing` / `IconViewController` (sets `grid.location`).
- `CommandBarView`: commands with a submenu get the "▾" indicator.
- `DetailsViewController`: keeps the selection by URL on refresh (results can share names); the empty-state label wraps.
  **Fix to main's column code:** `DetailsColumns` now marks a layout active *before* moving columns. Details applies the tab's column set
  only when no per-location layout is active, and `columnsEditedByUser` ignores layout locations. Before this fix, layout extras
  (Trash's, search's) leaked into folders' saved column sets and showed up as raw-id columns elsewhere. Behavior change: a cloud folder
  shows the cloud layout's columns rather than the tab's custom column set.
- The `nav.refresh` command and the address bar's Refresh button are wrapped so searches rerun.

Scripted steps (`DebugScript`): `searchopt:Date modified/Today`, `searchmenu:/out`, `searchrows:/out`, `searchdetails:/out`,
`searchsave:/x.arborsearch`, `searchopenfile:/x.arborsearch`, `searchclose`, `searchfocus`, `dropdownsnap:/out.png`. The logger
prints the box text, session status, dropdown, progress, history, back stack and Details columns.

## Known gaps

- The history dropdown is mouse-only: ↓ in the box submits (core `SearchBox` behavior). Selection restore after Back uses names, so
  duplicate-named results can both be selected when restored from history.
- Tiles and icon modes show the folder only in the infotip; Content shows it inline.
- Live Spotlight results and This Mac searches weren't observed headless (temp fixtures aren't indexed; real folders were never touched).
- Double-clicking a `.arborsearch` in Finder isn't handled: no document type is registered in Info.plist, and `AppDelegate` opens files
  as their folder. Opening it from inside Arbor works.
- Index exclusions (System Settings ▸ Spotlight privacy) can't be read, so contents from the index are labeled "via the Spotlight
  index" rather than proven complete.
