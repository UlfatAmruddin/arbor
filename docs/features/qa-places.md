# QA record: places, search, archives and dialogs

Acceptance pass over Home, This Mac, Gallery, Libraries, Network, Trash, cloud status, search, archives,
disk images, Properties, Folder Options and the copy conflict dialogs, using spec §17.5 (T18–T26) and
§16.1 as the checklist. Every bug found got a regression test (unit test in
`Tests/ArborCoreTests/QAPlacesTests.swift`, or a headless scripted run where only the UI shows it) and a
minimal fix in the owning feature's files.

How the runs were made: `scripts/build-app.sh debug`, then `ARBOR_HEADLESS=1` with `ARBOR_TEST_TRASH`,
`ARBOR_STATE_DIR`, `ARBOR_FAKE_NETWORK=1` or `ARBOR_TEST_CLOUD_ROOT/STATUS` as needed, fixtures in fresh
temporary folders, results read from `log:` / `crumbs:` / `proplog:` / `sheetlog:` output and PNG snapshots.
A disk image (`hdiutil create`, 8 MB HFS+) was attached and detached while tabs showed it.

## Bugs

Priority order: data safety, crash, wrong behavior, visual.

| # | Area | Bug | Severity | Status | Regression check |
|---|---|---|---|---|---|
| 1 | Archives | A symlink could escape the extracted folder through another link: with `self → .`, a link `esc → self/../outside.txt` passed the lexical check in both the planner and the verifier and pointed outside after extraction (`self/self/../..` reached any depth) | Data safety | Fixed: links are resolved through the archive's (planner) or the staging folder's (verifier) other links, case-insensitively; loops count as escaping; the verifier judges all links before removing any | `ArchiveLinkChainTests` (both layers); headless Extract All of a tar with `self`/`esc` kept `self` and `ok.txt`, left out `esc` with the safety alert |
| 2 | Search, libraries | Several items with one name (search results) were remembered by name: after switching tabs, Back/Forward, pressing Return in the search box or a single-click open, *every* item with that name came back selected (10 × `match0.txt`), so a following Delete would trash files the user never chose | Data safety | Fixed. Main's `select(urls:)` / `TabState.selectedURLs` (QA-CORE-4) covers tab switches and Return; this pass adds the selected URLs to Back/Forward history entries (`NavigationEntry.selectedURLs`) and makes single-click open select by URL | `HistorySelectionTests`; headless: one of two `same.txt` stays one after a tab round trip, after Back and after Forward/Back; Return after a re-run search selects 1 item, not 10 |
| 3 | Search | `size:99999999999999999999999 GB` crashed the app (Double → Int64 trap) | Crash | Fixed: sizes beyond 1 EB are a syntax error with an explanation | `AQSRobustnessTests` (80 odd queries parse or fail cleanly) |
| 4 | Search | A pasted query of thousands of `(`, `NOT`s or `OR`s overflowed the stack (recursive parser and matcher) | Crash | Fixed: at most 256 words/operators and 32 levels of nesting, each with a plain error | `AQSRobustnessTests` |
| 4b | Archives | Several archive tools running at once (extract, compress, list) could hang forever: each run blocked a shared dispatch thread while its pipe readers waited for a thread from the same pool. Seen as a full test-suite hang (8 runs stuck in `ToolProcess.run`, no child processes left) | Hang | Fixed: pipes are drained on dedicated threads | `OddNameArchiveTests` + `ArchiveToolTests` run in parallel; full suite run three times |
| 5 | Network / address bar | `smb://`, `smb:///share`, `afp://` (no server) and `\\\share` were accepted and handed to the system connect flow (Finder's Connect to Server) | Wrong behavior | Fixed in `PathResolver`: an address without a server is "isn't a valid address" | `AddressInputTests` |
| 6 | Archives | An archive opened from inside another (nested.zip ▸ inner.zip) showed a breadcrumb through the temporary folder (`… > T > Arbor Archives > session-… > UUID > inner.zip`), and Up went into that temporary folder | Wrong behavior | Fixed: `NestedArchives` remembers each temporary copy's origin; `Location.parent()` and the archive breadcrumb continue the outer archive (`fx > nested.zip > inner.zip`); Up selects the inner archive | `NestedArchiveTests`; headless crumbs/Up log |
| 7 | Archives / dialogs | Extract All conflicts said "Moving 1 item from **top** to top": the source was the hidden staging folder (a link to a temporary folder that is deleted) | Wrong behavior | Fixed: `OperationCenter.Job.presentedAs` lets extraction show "Extracting 1 item from **good.zip** to top" in Replace or Skip, Compare, folder-merge and name-clash dialogs | Headless conflict snapshot; Skip kept the user's changed file |
| 8 | Archives | A damaged archive's alert listed every extracted name before the error ("x top/ / x top/sub/ / …") | Wrong behavior | Fixed: `ArchiveError.summarize` drops bsdtar `-v` progress lines unless they carry an error | `ArchiveErrorTextTests`; headless corrupt.zip alert |
| 9 | Gallery | A photo whose file dates were all implausible (before 1900 or in the future) was silently left out of Gallery | Wrong behavior | Fixed: it is filed under its earliest date instead of dropped | `GalleryDateEdgeTests` |
| 10 | Gallery | Impossible EXIF dates (`2024:02:31`, `25:61`) rolled over into another day | Wrong behavior | Fixed: invalid components mean "no date taken" | `GalleryDateEdgeTests` |
| 11 | Search / cloud | The search box said "Search cloud" (the folder's name on disk) in a cloud root shown as "Test Cloud"; volume roots likewise | Visual | Fixed: placeholder uses the provider's title ("Search Test Cloud", "Search Macintosh HD") | Headless log |
| 12 | Network | Two network errors at once (a second connection fails while the first error sheet is open) showed the second as an app-modal alert that blocked every window (and headless scripts) | Wrong behavior | Fixed: alerts about a window queue behind its current sheet (`AlertSheets`); an identical error already showing or waiting is not shown again | `behavior-checks.sh network`: `\\nope-one`, `\\nope-two`, `\\nope-one` again → first sheet, then the second, then nothing |
| 13 | Archives | `\` in ZIP member names: the listing turned every `\` into a folder separator while bsdtar (which extracts) splits only names without `/`, so a Mac-made `u/lit\b.txt` showed as `u > lit > b.txt` and extracting it found nothing; a Windows-made `w/mixed\c.txt` likewise | Wrong behavior (rare, safe) | Fixed (`ZipNames`): an archive made on Windows (an entry from a FAT/HPFS/NTFS/VFAT host contains `\`) uses `\` as a separator everywhere, and extraction rewrites it (`bsdtar -s`) to match; other archives follow bsdtar's rule, keeping `\` in names that also contain `/`. Results go through `ArchivePath`, so `..\..\x`, `\x`, `C:\x` and `\\server\x` are rejected like their `/` spellings | `ZipBackslashTests` (4 tests: shown names, single-folder and full extraction from Windows and Mac archives, traversal attempts with backslashes) |
| 14 | Libraries | The "may be incomplete" status showed missing folders with `/private/tmp` while existing ones show `/tmp` (Foundation only shortens existing paths) | Visual | Fixed (`DisplayPath`: `/private/tmp`, `/private/var`, `/private/etc` are shown short whether or not they exist; Gallery's message too; stored paths unchanged) | `DisplayPathTests` |

## Scenario checklist (spec §17.5)

| Test | Result | Evidence |
|---|---|---|
| T18 Search with missing coverage | Pass | 40,000-match tree plus an unreadable folder: status "Search incomplete: only the first 10,000 results are shown"; `searchdetails` lists the denied folder |
| T19 Mixed AQS / unsupported queries | Pass after #3, #4 | `AQSRobustnessTests`; existing AQS suites |
| T20 Preview a cloud-only file | Pass | Test cloud root: Status column (online, available, conflict, error glyphs); Preview pane shows "is available when online" + Download to preview, nothing downloaded on selection (snapshot) |
| T21 Paste into a library | Pass | Library [L1, missing L2, L3, link to L3]: L1 removed while open; Paste went to L3 (fallback), link3 merged as the same folder, "may be incomplete" status names the missing folders |
| T22 Remove a recent entry / collection source | Pass | Home recent menu offers "Remove from Recent" (history only); Libraries' remove keeps files (unit tests in `GalleryLibraryTests`) |
| T23 Delete on a non-recycling provider | Not re-run here | Covered by the file-operations record |
| T24 Same-name network shares | Pass | `\\NAS-01\Public` and `smb://office-pc/Public/` open different folders with the right server in the breadcrumb |
| T25 Extract/create each archive | Pass after #1, #6–#8, #13 open | ZIP/7z/TAR odd-name round trip (`OddNameArchiveTests`); hostile tar; corrupt ZIP (nothing left behind); password-protected ZIP refused with explanation; Extract All twice → Replace or Skip, Skip kept the changed file |
| T26 Offline device / cloud disconnect | Pass | OFFLINE-PC: "Loading “Data”…" while the window stays usable, quit during the attempt is immediate; unknown server: "can't reach \\nope" sheet with Retry; disk image detached while two tabs showed it: both tabs moved to This Mac, no hang |

## Failure states (spec §16.1)

| State | Result | Evidence |
|---|---|---|
| Empty / no matches | Pass | Existing feature runs; search "Search complete" vs incomplete wording |
| Loading | Pass | Network "Loading …" status; progressive search |
| Denied | Pass | Denied folder in search coverage; locked network share sheet with Retry / Use Different Credentials… |
| Missing | Pass | Trash restore recreated a deleted parent folder (`docs/sub`) |
| Disconnected | Pass | Disk image detached during use; offline server |
| Partial enumeration | Pass | Search result cap and unreadable folders reported; libraries with missing folders |
| Read-only | Pass | Archives say read-only on entry; Properties read-only / locked applied (`uchg`, mode 0400) |
| Conflict | Pass | Trash restore Keep Both → `a (2).txt`; extraction Replace or Skip |
| Interrupted job | Not re-run | File-operations record |

## Other areas checked

- **Trash**: three items trashed by Arbor plus one placed in the Trash directly. Restore all: conflict asked Keep Both (`a (2).txt`), missing parent recreated, item of unknown origin explained ("Arbor only knows where items came from…") and left in place.
- **Properties**: rename to an existing name refused, nothing overwritten; file renamed externally while the sheet was open → Apply did not touch the moved file; mode 0400 + Read-only applied; multi-select Hidden applied to both; folder Security tab lists owner/group/everyone with the real mode.
- **Folder Options**: Show hidden files, Hide extensions, Full path in title bar, Status bar off → Apply honored at once; Restore Defaults + OK reverted all four; Cancel discarded an "own window" change.
- **This Mac**: 8 MB disk image attached, browsed in two tabs, detached externally: tabs go to This Mac, the volume disappears, no hang.
- **Home**: Recent and Favorites menus; duplicate favorites collapse to one.

## Decisions

| ID | Decision | Why |
|---|---|---|
| DEC-qa-1 | Back/Forward entries keep the selected URLs next to the names, using the same restore path as tab switches | One mechanism for listings where names repeat; names stay for session files |
| DEC-qa-2 | Search queries are limited to 256 words/operators and 32 nesting levels | Far beyond real queries; keeps recursion bounded on any thread |
| DEC-qa-3 | Extraction keeps using the app's conflict dialogs, but they name the archive and say "Extracting" | The staging folder is an implementation detail and is deleted afterwards |
| DEC-qa-4 | Gallery files a photo with only implausible dates under its earliest date rather than hiding it | Spec §16.1: never hide items silently |
| DEC-qa-5 | ZIP names are read the way the extractor reads them, except in archives made on Windows, where every `\` is a separator (as in Explorer) and extraction is told to rewrite it | What a ZIP shows must be exactly what Extract writes; a Mac name may legitimately contain `\` |
| DEC-qa-6 | Alerts queue per window; duplicates merge and their callers hear Cancel | One sheet at a time never blocks the rest of the app; retrying the same failed share twice helps nobody |

## Shared files touched (small, additive)

- `ArborCore/Location.swift`: `parent()` asks `NestedArchives` for archives opened from inside another archive.
- `Window/BrowserWindowController.swift` (`goUp`): selects the inner archive when leaving it.
- `ArborCore/NavigationHistory.swift`: `NavigationEntry.selectedURLs`, `saveState(selectedNames:selectedURLs:topVisibleName:)` (default keeps old callers).
- `Window/BrowserWindowController.swift` (`request`): saves and restores the selected URLs with Back/Forward.
- `Window/SearchController.swift`, `FolderOptions/ItemClickBehavior.swift`: select one item with main's `select(urls:)`.
- `Search/ExplorerSearchController.swift`: placeholder uses the provider's title.
- `Support/OperationCenter.swift`: `Job.presentedAs` (new `Support/PresentedJob.swift`); `FileOperations/ConflictDialogs.swift` reads it.
- `ArborCore/PathResolver.swift`, `Search/AQSParser.swift`, `Archives/ArchiveSafety.swift`, `ArchiveEntry.swift`, `ArchiveTool.swift`, `GalleryTimeline.swift`: the fixes above; `ArchiveTool.swift` also drains tool pipes on dedicated threads.
