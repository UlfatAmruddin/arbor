# Core browsing and file operations: acceptance pass

Scope: tabs and windows, navigation and the address bar, selection in Details and icon views, sort/group,
clipboard, rename, New, Trash/undo/redo, drag-and-drop policy, copy/move conflicts across file systems,
read-only and denied folders, races, folder-watcher bursts.

How to rerun:
- Unit: `scripts/test.sh` (new: `Tests/ArborCoreTests/CoreRegressionTests.swift`, 12 tests; the
  cross-file-system tests create and mount 20 MB ExFAT, HFS+ and case-sensitive APFS disk images with
  `hdiutil` and skip themselves when that is impossible).
- Headless: `scripts/build-app.sh debug && scripts/core-checks.sh` (asserts the fixed UI bugs stay fixed).

## Bugs

Severity order: data safety, crash, wrong behavior, visual.

| ID | Severity | Bug | Status | Regression check |
|---|---|---|---|---|
| QA-CORE-1 | data safety | Copy or move into the source's own folder reached through another spelling (other letter case, a symbolic link such as `/tmp` vs `/private/tmp`) reported a conflict with the source itself. **Replace moved the source to the Trash** and the copy then failed. Move-merging a folder into its own parent spelled differently trashed every file inside; replacing an ancestor spelled differently trashed the whole tree. | fixed (`FileTransfer.plan`, `FileOps.canonicalPath/isSameEntry/isSameOrInsideOnDisk`) | `AliasedDestinationTests` (6 tests; 5 failed before the fix) |
| QA-CORE-2 | wrong behavior (enabled QA-CORE-1) | A path typed in the address bar kept its typed spelling (`~/desktop`), so the same folder became a different location: separate history entries, pins and per-folder views didn't match, tree highlight missing, and paste targets were aliases of the folder on screen. Explorer shows the stored spelling. | fixed (`PathResolver.onDiskSpelling`; symbolic links are kept as typed) | `AddressSpellingTests`, `core-checks.sh` |
| QA-CORE-3 | wrong behavior | After Cut + Paste the clipboard still named the moved files; a second Paste "copied" them and showed "2 items couldn't be copied: The item no longer exists". Explorer empties the clipboard after a move. | fixed (`FileClipboard.finishedCut` clears content this app wrote, only while unchanged) | `core-checks.sh` |
| QA-CORE-4 | data safety | In search results (many items share a name) selection was restored by name: after switching tabs, changing view, refreshing an icon view or collapsing a group, **every same-named item became selected**, so Delete would trash items the user never picked. Invert Selection with one of three `readme.txt` selected selected nothing; Return in the search box selected every match. | fixed (`ItemViewController.select(urls:)`, `TabState.selectedURLs`, icon view and group relayout keep URLs) | `core-checks.sh` (4 checks; all failed before) |
| QA-CORE-5 | wrong behavior / responsiveness | Undo of a cross-volume move runs `FileManager.moveItem` on the main thread: a large undo freezes the window with no progress or cancel. Safe (originals are only removed after the copy) but slow. | open | — |
| QA-CORE-6 | visual (label) | After Undo then Redo of New folder, the Edit menu reads "Undo Move to Trash" instead of "Undo New Folder". Behavior is correct. | open | — |
| QA-CORE-7 | wrong behavior (minor) | Back/Forward history entries store selected names only, so going back to a search-results entry can reselect every same-named result. Tabs, view changes and refresh are fixed (QA-CORE-4). | open | — |

Checked and found correct (no change needed): conflict prompts with exFAT names it rejects (`what?.txt`,
`a:b.txt`) keep the originals on a move; case twins from case-sensitive APFS never overwrite each other on
a case-insensitive destination (one arrives, the other is reported once, its original kept); case-only
rename on ExFAT, HFS+ and case-sensitive APFS; cross-volume folder merge with skipped files; New ▸
templates use `withoutOverwriting`; batch rename handles swaps and rolls back; rename conflict refused
without overwriting; extension-change warning; undo/redo chains for rename, New folder, Trash and Move.

## Task scenarios (spec §17.5)

"Pass" means the behavior was observed in a headless run (fixture under `mktemp -d`, private trash) or by a
unit test; scenarios owned by other areas are marked out of scope.

| Test | Result | Evidence |
|---|---|---|
| T01 Expand and browse hierarchy | not run | tree expansion is the navigation-pane area; Up/Back verified under T02 |
| T02 Back/Forward/Up across tabs | pass | two tabs with separate histories; Back, Forward and Up restore location and selection per tab (`log:` per step) |
| T03 Invalid/quoted/network path | pass after QA-CORE-2 | existing PathResolver tests (quotes, `file://`, UNC, drive letters, no execution) plus typed-case and NFC/NFD tests |
| T04 Switch tabs with search/selection | pass after QA-CORE-4 | search text and selection stay with their tab; duplicate tab copies history and selection; reorder and detach keep the active tab |
| T05 Similar long file names | pass | names truncate in the middle so the extension stays visible; tooltip shows the full name (snapshot reviewed) |
| T06 Change sort/group/columns | pass | natural order (`file2` < `file10`, `Folder 9` < `Folder 10`), folders first, emoji/NFD/leading-space names sort deterministically; group collapse keeps the selected item (fixed with QA-CORE-4) |
| T07 Revisit folder with override | out of scope | Folder Options area |
| T08 Range/disjoint selection after updates | pass | selection kept by URL across refresh and a 1,000-file burst; arrow keys and invert verified |
| T09 Right-click a selected batch | not run | no scripted right-click; context is frozen from the selection by design |
| T10 Rename dotfile/case-only/conflict | pass | case-only rename (APFS, ExFAT, HFS+, case-sensitive APFS), conflict refused with the typed text kept, undo/redo |
| T11 Cut, change clipboard, cancel | pass after QA-CORE-3 | cut intent tied to the pasteboard change count (unit); move then second paste disabled |
| T12 Copy promised/virtual content | out of scope | archives area |
| T13 Cross-volume move and cancellation | pass | existing HFS+ disk-full test plus new ExFAT and case-sensitive APFS tests: originals removed only after their own copy |
| T14 Merge or replace folders | pass after QA-CORE-1 | merge vs replace distinct; replace never targets the source or its ancestor however spelled |
| T15 Destination changed while prompt open | pass | existing `changedDestinationIsAskedAgain` |
| T16 Recover interrupted operation | pass (existing) | journal tests in `TransferEngineTests` |
| T17 Undo after external edit | pass (existing) | Undo Copy fingerprint tests; Undo Move/Rename refuse when the old place is taken |
| T18–T20, T22, T24–T26 | out of scope | search, cloud, libraries, network, archives |
| T21 Paste into library | out of scope | libraries area |
| T23 Delete on non-recycling provider | pass (code + existing) | a failed Trash offers an explicit "Delete Permanently…" with its own confirmation; never silent |
| T27 Keyboard sequence | partial | arrows, type-to-select (prefix, NFD "Café", emoji), Return, F2, ⌘Z verified; VoiceOver not run |
| T28 Large directory and event churn | pass | 1,000 files created then 100 deleted while viewing: counts correct (1,000 → 900), no stalls |
| T29 Memory over repeated work | not run | |
| T30 Quit during active work | pass (existing) | journal kept on quit (`TransferEngineTests`) |

Also verified headless: permission-denied folder shows "Can't open" and stays on the previous folder; New
folder in a read-only folder reports the permission error; Paste into a read-only folder shows
"Destination Folder Access Denied"; deleting the folder being viewed walks up to the nearest existing
parent; an external change while a rename field is open keeps the typed text.

## Decisions

- **DEC-qa-core-1** Locations are compared as stored on disk (symbolic links in parents resolved, case and
  normalization from the file system) only inside copy/move planning, which runs off the main thread.
  Drag validation keeps the cheap string comparison.
- **DEC-qa-core-2** The address bar adopts the stored spelling of each typed component but never swaps a
  symbolic link for its target: the user typed that folder.
- **DEC-qa-core-3** Names that are valid on the Mac but not on Windows (whitespace-only, `:`) stay allowed
  (spec §8.1); exFAT and other destinations refuse them per item with a reported failure, keeping originals.
- **DEC-qa-core-4** Selection identity is the item URL wherever a listing can repeat names; names remain
  the persisted form (history, session) and are exact in ordinary folders.

## Known gaps

QA-CORE-5, -6 and -7 above. Rename-error and extension-change alerts are app-modal (`runModal`), which
scripted checks cannot answer, so those paths were verified by reading the code and by unit tests rather
than headless runs.
