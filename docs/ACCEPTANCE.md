# Acceptance record: task scenarios T01–T30

The task scenarios of [SPEC.md §17.5](SPEC.md#175-essential-task-scenarios), run against the debug build of version
0.2.0 on macOS 26 (Apple silicon). Every scenario is scripted in [`scripts/acceptance.sh`](../scripts/acceptance.sh):
each builds its own fixture in a fresh `mktemp -d` folder with a private Trash, journal and history, drives the real
app headless (`ARBOR_HEADLESS=1`, see [TESTING.md](../TESTING.md)) and checks the app's `log:` output and the files on
disk. Rerun with:

```bash
scripts/build-app.sh debug && scripts/acceptance.sh          # all scenarios
ACCEPT_KEEP=1 scripts/acceptance.sh T13 T25                   # some, keeping logs and snapshots
```

**Result values:** *pass* = every check passed and the scenario's pass condition is fully shown · *partial* = every
check passed, but part of the pass condition can't be shown headless or isn't met exactly (the reason is given) ·
*fail* = a check failed · *not testable headless* = needs something a headless run can't provide.

No Windows machine was used: "expected" behavior comes from the specification and
[research/windows11-reference.md](research/windows11-reference.md), not from side-by-side observation.

## Summary

| Result | Scenarios |
|---|---|
| pass | 20 |
| partial | 10 (T06, T08, T09, T12, T20, T24, T25, T26, T27, T30) |
| fail | 0 (T06, T08 and T10 first failed on app bugs, fixed below) |
| not testable headless | 0 |

166 individual checks passed in the final run of `scripts/acceptance.sh`.

## Other suites run for this record

| Suite | Result |
|---|---|
| `scripts/test.sh` (unit tests, string table check) | 582 tests in 129 suites passed |
| `scripts/core-checks.sh` | 6 / 6 passed |
| `scripts/behavior-checks.sh` | 47 / 47 passed |
| `scripts/bench.sh --check` | 23 / 23 budgets met (see [Benchmarks](#benchmarks)) |
| `scripts/build-app.sh debug` | built with zero warnings |

## Scenarios

| Test | Task | Result | Evidence (script checks; logs read) | Not shown / notes |
|---|---|---|---|---|
| T01 | Expand and browse hierarchy | pass | ⇧F6 puts focus on the tree row of the current folder; → expands it (`expanded=true`, subfolders listed) while `location:` stays on the folder; ↓ moves the tree selection (focus stays in the tree) and the list shows that folder; F6 moves on to the items | Moving the tree selection with ↓ shows that folder, as in Explorer; only expanding never navigates |
| T02 | Back/Forward/Up across tabs | pass | Two tabs with separate histories: Back/Forward in one never moves the other; Back restores the selection left behind (`selected: A2`); Up selects the folder just left | — |
| T03 | Enter invalid/quoted/network path | pass | Quoted path with a space opens; a missing path gives "Can't find “…”. Check the spelling and try again." and the location doesn't change; `C:\Windows` is explained; `open -a Calculator` is treated as a (missing) path and `system open: none`; `\\NAS-01\Public` opens the share with `Network > NAS-01 > Public`; `smb://` without a server is refused | Network share simulated (`ARBOR_FAKE_NETWORK`) |
| T04 | Switch tabs with search/selection | pass | Search results and query stay in tab 1 (`search box: “readme”`, its selection kept); tab 2 keeps its own selection and an empty search box | — |
| T05 | Read similar long file names | pass | Three 75-character names differing near the end: the snapshot shows "Quarterly financial…nal version A.docx / …inal version A.xlsx / …inal version B.xlsx" in a 900 pt window (middle truncation keeps the distinguishing end and extension); every row has the full name as its tooltip (`axdump:`) | Snapshot read by eye |
| T06 | Change sort/group/columns | partial | Natural order with folders first; size ↓ keeps folders first and uses the previous key as tie-breaker (`sort: size↓ then name↑`); Group by Type shows headers; selection (`file10.txt`) kept through sort, grouping, adding and removing a column; name ↓ | **Bug found and fixed:** showing or hiding a column cleared the selection (now restored by item; `DetailsViewController+Depth.swift`, regression check in this scenario). "No disk I/O per comparison" is shown by unit tests (`BackgroundSortTests`, `LargeSort` precomputes keys), not by this run |
| T07 | Revisit folder with override | pass | Large icons chosen in A; B keeps Details; back in A: Large icons, `folder view: source=Saved for this folder`, and View ▾ says "Folder view: Saved for this folder (Documents)"; the override survives a relaunch (`ARBOR_STATE_DIR`) | — |
| T08 | Range/disjoint selection after updates | partial | ⇧↓ ⇧↓ from b.txt selects b–d; files created and deleted outside the app while it is shown: the same items stay selected; ⇧↑ then shrinks the range toward the same anchor (`b.txt \| c.txt`); a disjoint selection survives Refresh | **Bug found and fixed:** after a file appeared inside a selected range, ⇧↑ grew the range (b, bb, c, d) instead of shrinking it, because the table remembered the anchor by row number (`Views/DetailsSelectionAnchor.swift`). Remaining difference: the new file inside the range (bb.txt) isn't added by the next ⇧↑; Explorer reselects the whole anchor-to-focus range |
| T09 | Right-click a selected batch | partial | A real right-click (`iconclick:…:right`) on an item of a 3-item selection keeps all three; ⇧F10 opens the context menu for the batch (Batch rename… offered) without dropping it; Copy from it puts all three on the clipboard; right-clicking an item outside the batch selects only that item | AppKit menus can't be drawn headless; the menu titles come from the ⇧F10 path |
| T10 | Rename dotfile/case-only/conflict | pass | F2 selects the base name ("Readme" of Readme.md) or a dotfile's whole name; case-only rename `Readme.md → README.md` changes the name on disk; `.env → .env.local` asks first; renaming b.txt to the existing a.txt is refused and the typed name stays in the field; nothing overwritten | **Bug found and fixed:** the extension prompt for a dotfile said “If you change “.” to “.local””; it now says “If you add “.local” to the name” (`ArborCore/ExtensionChange.swift`, unit tests `ExtensionChangeTests`) |
| T11 | Cut, change clipboard, cancel | pass | Cut marks the item (`cut marks=[one.txt]`); copying another file clears the stale mark and Paste copies the new content; the cut file never moved; a cut whose paste hits a conflict and is cancelled leaves source and destination unchanged | — |
| T12 | Copy promised/virtual content | partial | Copy of a member inside a ZIP pastes the right content elsewhere; a 3 MB member delivered as a file promise (drag-out path) arrives byte for byte; the archive is unchanged | Memory while streaming isn't measured; members are extracted by bsdtar into a staging folder on disk, never held in memory. Dragging to Finder interactively not run |
| T13 | Cross-volume move and cancellation | pass | Move of 4 × 3 MB files to a mounted HFS+ disk image, throttled, cancelled mid-way: every file is in exactly one place, moved files are whole, nothing half-copied is left on the destination, unmoved files stay in the source, and Operation history records the job | — |
| T14 | Merge or replace folders | pass | Default (Windows' "Hide folder merge conflicts" on): the folders merge, the destination's own files stay, same-named files are asked about (Skip kept the old content); Replace puts the new file in place and moves the old one to the (test) Trash; with the merge prompt turned on, "Confirm Folder Replace" is asked and No copies nothing | Recorded in DECISIONS.md: DEC-fileops-3 described the prompt as the default; the code follows Windows' default |
| T15 | Change destination while prompt open | pass | While "Replace or Skip Files" is open the destination file is edited from outside; choosing Replace asks again instead of overwriting; the outside edit survives and nothing goes to the Trash | — |
| T16 | Recover interrupted operation | pass | The app is killed (SIGALRM) in the middle of a throttled copy; the journal remains; the next launch shows "A file operation didn't finish" listing Completed / Not done / Uncertain items with Retry remaining and Dismiss; nothing is retried or written until the user chooses | — |
| T17 | Undo after an external edit | pass | A pasted copy is edited from outside, and another file takes a renamed item's old name; Undo refuses both: the edited copy and the other file are kept, the original untouched | — |
| T18 | Search with missing coverage | pass | A search in a folder with an unreadable (`chmod 000`) subfolder: the readable match is listed, the status says "Search incomplete: 1 folder couldn't be opened (access denied)", the scope "Search Results in fx" is shown, and the details name the locked folder | — |
| T19 | Mixed AQS query/localized properties | pass | `ext:md OR ext:txt size:>1KB` folds left to right (big.md, big.txt); parentheses change it (big.md, big.txt, c.md); `größe:>1KB` and `kind:game` are rejected with "Search couldn't run" | — |
| T20 | Preview a cloud-only large file | partial | A 20 MB online-only file in a simulated provider folder: Status column says Online-only; the Preview pane shows "“video.mov” is available when online" with a separate "Download to preview" button (nothing downloaded on selection, snapshot read); closing the pane releases it | Simulated provider (`ARBOR_TEST_CLOUD_ROOT/STATUS`); real File Provider downloads weren't run |
| T21 | Paste into library | pass | Documents library over two folders shows both folders' items; Paste writes into the save location (first folder) only; with only a read-only folder, Paste explains "This library has no save location." and writes nothing | — |
| T22 | Remove a collection source/recent entry | pass | Remove from Recent removes the Home entry and the file stays; removing a folder from a library removes its items from the library view and leaves the files on disk | — |
| T23 | Delete on nonrecycling provider | pass | With a Trash that can't take items, Move to Trash opens "Delete File": "This file can't be moved to the Trash. Do you want to permanently delete it?" with No as the default (snapshot read); No keeps the file; only Yes deletes it | — |
| T24 | Same-name network shares | partial | `\\NAS-01\Public` and `smb://OFFICE-PC/Public/` open different folders, each breadcrumb names its own server, Back returns to the first server's share | Simulated servers; no real SMB server was available |
| T25 | Extract/create/modify each archive | partial | Compress to ZIP, 7z and TAR create the archives next to the items; the new ZIP opens as a folder; inside it Rename/Delete/Paste are off (archives are read-only); a ZIP with `../escaped.txt` and `/abs.txt` members extracts only the safe member and writes nothing outside the destination | Modifying archives is not offered (FE-165, by decision); RAR untested (no fixture can be made with built-in tools) |
| T26 | Offline device/cloud disconnect | partial | A server that never answers shows "Loading “Data”…" while another tab browses a local folder normally; after the deadline an explicit "didn't respond in time" sheet with Retry; a disk image detached under an open tab moves the tab to This Mac instead of hanging | Simulated servers; real network loss and File Provider disconnects weren't run |
| T27 | Keyboard and VoiceOver task sequence | partial | Keyboard only: type-to-select finds budget.txt, ⌘X, type "d" + Return opens Dest, ⌘V moves the file in, ⌘Z undoes the move, Delete goes Back: the file is back in its folder only; `axaudit:` reports 0 unnamed controls and 0 empty rows | VoiceOver itself wasn't run; the accessibility tree it reads was audited. Menu shortcuts are delivered with the `menukey:` step (headless windows are never key) |
| T28 | Large directory and event churn | pass | A 20,000-file folder with one item selected; 2,000 files created and 1,000 deleted from outside while it is shown: status goes from "20,000 items" to "21,000 items", the selection survives, no main-thread stall during the churn (longest stall 57 ms while opening) | Larger folders (100,000 entries) are measured by `bench.sh` |
| T29 | Repeated previews/search/tab closure | pass | 2 warm-up cycles then 2 rounds of 8 (Preview pane on/off with two selections, new tab, search, close search, close tab): footprint +1.5 MB over the second round of 8 cycles (limit 4 MB; 53.2 → 54.8 MB in an earlier run) | Longer-run plateaus are in `bench.sh` (tabs, media, search workloads) |
| T30 | Quit/close during active work | partial | Closing the tab that started a copy doesn't stop it; quitting during the copy ("Quit Anyway" path) keeps the journal and leaves no half-written file; the next launch reports what was left unfinished | The quit confirmation is an app-modal alert the script can't click; the script takes its Quit Anyway path (`terminate`) |

## Bugs found and fixed in this pass

| Scenario | Bug | Fix | Regression check |
|---|---|---|---|
| T06 | Showing or hiding a Details column (header menu, Choose Details) cleared the selection | `setColumns` restores the selected items after reloading the table | `acceptance.sh T06` ("adding / removing a column keeps the selection") |
| T08 | After a file appeared inside a selected range, ⇧↑ grew the range instead of shrinking it | `Views/DetailsSelectionAnchor.swift`: the range's anchor and moving end are remembered by item and reapplied after a reload | `acceptance.sh T08` |
| T10 | The extension prompt for a dotfile named an empty extension (“If you change “.” to “.local””) | `ArborCore/ExtensionChange.swift`: added / removed / changed are worded separately | `ExtensionChangeTests` (4 tests); `acceptance.sh T10` |

## Open items

- T08: a file that appears inside a selected range isn't included by the next ⇧-arrow (Explorer reselects anchor to
  focus). Fixing it means taking over ⇧-arrow handling from NSTableView in the Details view.
- Scenarios marked partial rely on simulated servers and cloud providers (T20, T24, T26), on the accessibility tree
  rather than a live VoiceOver session (T27), and on script paths for pointer menus and the quit alert (T09, T30).
  A manual pass on real hardware and services is still needed.
- The core `file.trash` command's own failure alert (replaced at runtime by the file-operations feature's "Delete File"
  dialog) and the "Delete File" dialog's texts aren't routed through the string table yet.

## Benchmarks

`scripts/bench.sh --check` (release build, 3 runs per workload, medians; budgets and method in
[PERFORMANCE.md](PERFORMANCE.md)): all 23 budgets met.

| Metric | Result | Budget |
|---|---|---|
| Idle footprint, one folder | 37.1 MB | 45 MB |
| Time to first drawn folder | 315 ms | 600 ms |
| Idle CPU | 0.2 ms/s | 2 ms/s |
| 1,000-entry folder navigation, p95 | 28.9 ms | 60 ms |
| Browsing 50 folders, retained growth | 1.9 MB | 6 MB |
| 20 tabs / per tab / plateau after 3 open-close cycles | 52.1 MB / 0.77 MB / +1.2 MB | 70 / 1.2 / 4 MB |
| 5 windows / plateau after 3 cycles | 96.3 MB / −2.9 MB | 120 / 3 MB |
| 100,000 entries: rows on screen / peak | 678 ms / 128.6 MB | 1,200 ms / 170 MB |
| 100,000 entries: longest stall opening / sorting and scrolling | 73 ms / 75 ms | 150 / 350 ms |
| 100,000 entries: scroll frame p95 / after leaving twice | 8.7 ms / 94.3 MB | 12 ms / 110 MB |
| Thumbnails of 60 photos / after Preview churn, pane closed | 48.3 MB / 58.7 MB | 70 / 80 MB |
| 100 changing searches: final results / stale rows / growth | 732 ms / 0 / 1.6 MB | 1,500 ms / 0 / 6 MB |
| Copy 3,000 small files / 512 MB file, extra memory | 2.3 MB / 0.1 MB | 16 MB |
