# Core browsing and file operations: acceptance pass

Scope: tabs and windows, navigation and the address bar, selection in Details and icon views, sort/group,
clipboard, rename, New, Trash/undo/redo, drag-and-drop policy, copy/move conflicts across file systems,
read-only and denied folders, races, folder-watcher bursts.

How to rerun:
- Unit under load: the whole suite passed 5 runs in a row while `scripts/bench.sh --quick` ran, and 5 more with
  every core also busy (about 6× slower). Tests wait on conditions and ordering, never on wall-clock gaps.
- Unit: `scripts/test.sh` (new: `Tests/ArborCoreTests/CoreRegressionTests.swift`, 12 tests; the
  cross-file-system tests create and mount 20 MB ExFAT, HFS+ and case-sensitive APFS disk images with
  `hdiutil` and skip themselves when that is impossible).
- Headless: `scripts/build-app.sh debug && scripts/core-checks.sh` (asserts the fixed UI bugs stay fixed) and
  `scripts/behavior-checks.sh [undo undomove selection sheets network headless recent queue services capabilities]` (undo/redo names,
  undo of cross-volume moves, selection identity, window-modal alerts and their queue, headless safety, Recent
  for shortcuts, queued jobs after quit, Services, explained refusals).

## Bugs

Severity order: data safety, crash, wrong behavior, visual.

| ID | Severity | Bug | Status | Regression check |
|---|---|---|---|---|
| QA-CORE-1 | data safety | Copy or move into the source's own folder reached through another spelling (other letter case, a symbolic link such as `/tmp` vs `/private/tmp`) reported a conflict with the source itself. **Replace moved the source to the Trash** and the copy then failed. Move-merging a folder into its own parent spelled differently trashed every file inside; replacing an ancestor spelled differently trashed the whole tree. | fixed (`FileTransfer.plan`, `FileOps.canonicalPath/isSameEntry/isSameOrInsideOnDisk`) | `AliasedDestinationTests` (6 tests; 5 failed before the fix) |
| QA-CORE-2 | wrong behavior (enabled QA-CORE-1) | A path typed in the address bar kept its typed spelling (`~/desktop`), so the same folder became a different location: separate history entries, pins and per-folder views didn't match, tree highlight missing, and paste targets were aliases of the folder on screen. Explorer shows the stored spelling. | fixed (`PathResolver.onDiskSpelling`; symbolic links are kept as typed) | `AddressSpellingTests`, `core-checks.sh` |
| QA-CORE-3 | wrong behavior | After Cut + Paste the clipboard still named the moved files; a second Paste "copied" them and showed "2 items couldn't be copied: The item no longer exists". Explorer empties the clipboard after a move. | fixed (`FileClipboard.finishedCut` clears content this app wrote, only while unchanged) | `core-checks.sh` |
| QA-CORE-4 | data safety | In search results (many items share a name) selection was restored by name: after switching tabs, changing view, refreshing an icon view or collapsing a group, **every same-named item became selected**, so Delete would trash items the user never picked. Invert Selection with one of three `readme.txt` selected selected nothing; Return in the search box selected every match. | fixed (`ItemViewController.select(urls:)`, `TabState.selectedURLs`, icon view and group relayout keep URLs) | `core-checks.sh` (4 checks; all failed before) |
| QA-CORE-5 | wrong behavior / responsiveness | Undo of a cross-volume move ran `FileManager.moveItem` on the main thread: a large undo froze the window with no progress or cancel. | fixed (`MoveBack` plans off the main thread: same-volume items are renamed back, items on another volume go back through a normal move job with the progress window, pause, cancel, journal, conflict prompts and "original removed only after its copy"; Keep Both names are restored afterwards when free; Redo works the same way) | `MoveBackPlanTests` (3 tests); `behavior-checks.sh undomove` (HFS+ image, throttled: the undo shows as a running job, files come back, nothing left on the image, Redo offered) |
| QA-CORE-6 | visual (label) | After Undo then Redo of New folder, the Edit menu read "Undo Move to Trash" instead of "Undo New Folder". Same for New ▸ documents, shortcuts and Restore from Trash after a Redo; Redo after undoing Rotate Right said "Redo Rotate Left"; undoing a new archive offered no Redo. | fixed (`registerUndoTrash(_:actionName:)` keeps the action's name in every round; rotate keeps the user's direction; archive creation gets a Redo. Security ▸ Edit… changes are undone inside that editor with its own “Undo last change”, which names the change, not on Edit ▸ Undo) | `behavior-checks.sh undo` (14 checks: New folder ×3 rounds, Move to Trash, Rename, batch rename, New Text Document, Rotate Right, Copy; all New folder/New document/Rotate checks failed before) |
| QA-CORE-7 | wrong behavior (minor) | Back/Forward history entries stored selected names only. | fixed (qa-places #2: entries keep URLs); duplicated, torn-off and merged tabs and any visit that names URLs now also restore by URL | `HistorySelectionTests`; `behavior-checks.sh selection` |
| QA-CORE-8 | data safety | After Delete (or Delete Permanently, or deleting in the Trash) the next item to select was chosen and restored **by name**: in search results, deleting `b.txt` next to three `a.txt` selected all three, so a second Delete would trash files the user never picked. Rotate, Properties renames, Select All, a batch-rename edit and a single rename restored by name too. | fixed (`neighborURL(after:)`, `refreshSelecting(urls:)`, `select(urls:)` at every call site that knows the items) | `behavior-checks.sh selection` (failed before: `selected: a.txt \| a.txt \| a.txt`) |
| QA-CORE-9 | wrong behavior | The extension-change prompt and the rename error were app-modal (`runModal`): they blocked every window and scripts couldn't answer them. Eleven other alerts fell back to `runModal` whenever their window already showed a sheet. | fixed (`AlertSheets`: window-modal sheets, one at a time per window; Cancel on the extension prompt keeps the typed name in the field, a rename error reopens the field with the typed text; the zip-bomb confirmation is a sheet the extraction waits for) | `behavior-checks.sh sheets` (8 checks; the run timed out before the fix) |
| QA-CORE-10 | safety (test runs) | Headless runs (`ARBOR_HEADLESS`) could open files in other apps, Finder windows, Terminal, the share picker, Quick Look, network sign-in windows, change the desktop picture or default apps, and eject disks. | fixed (`SystemOpen`: every such request goes through one helper that only logs it in headless runs; `log:` prints `system open: …`) | `SystemOpenAuditTests` (fails on any direct call outside the helper; 31 direct calls before); `behavior-checks.sh headless` |

Checked and found correct (no change needed): conflict prompts with exFAT names it rejects (`what?.txt`,
`a:b.txt`) keep the originals on a move; case twins from case-sensitive APFS never overwrite each other on
a case-insensitive destination (one arrives, the other is reported once, its original kept); case-only
rename on ExFAT, HFS+ and case-sensitive APFS; cross-volume folder merge with skipped files; New ▸
templates use `withoutOverwriting`; batch rename handles swaps and rolls back; rename conflict refused
without overwriting; extension-change warning; undo/redo chains for rename, New folder, Trash and Move.

## Long and unusual paths (FE-225)

Status: implemented (macOS adaptation). Tests: `UnusualPathTests.swift` (`UnusualNameTests`, `PathLimitTests`,
`FolderDepthTests`, `FileSystemLimitTests`), 48 names through list, copy, both kinds of move, rename, Trash and delete; paths of
exactly 1023 bytes and one past; children past the limit; names and trees that only fit precomposed; 140-level trees; HFS+
and ExFAT images, each proving an item either arrives byte-identical or is refused with its original kept.

| ID | Severity | Bug (each seen failing first) | Status |
|---|---|---|---|
| QA-CORE-11 | crash | A tree about 130 folders deep overflowed the job thread's 512 KB stack and took the app down. | fixed: `PathLimits.maxFolderDepth`, 8 MB job stack |
| QA-CORE-12 | wrong behavior | One child past `PATH_MAX` stopped the folder listing, so ordinary siblings vanished too (17 of 22 rows). | fixed: the listing carries on and adds such children through a descriptor |
| QA-CORE-13 | wrong behavior | A path too long read as “the name isn't valid, rename it”, “no longer exists”, or “Can't find”. | fixed: `FailureKind.pathTooLong`, `ListingError.pathTooLong`, `PathResolutionError.pathTooLong`, `RenameError.pathTooLong` |
| QA-CORE-14 | wrong behavior | A precomposed path short enough in `URL.path` but too long once decomposed reported “doesn't exist”. | fixed: `PathLimits.fits` measures the decomposed form |

- **DEC-qa-core-8** The limits live in `PathLimits`. It measures the decomposed path because FileManager and resource values
  decompose before calling the kernel, even when `URL.path` holds the precomposed name as read from disk. It measures the
  whole path only: APFS accepts names of more than 255 bytes when decomposed, so a per-name byte check would refuse valid names.
- **DEC-qa-core-9** Items past the limit are shown and explained, never hidden or shortened; a duplicate or Keep Both name that
  would not fit fails with the path message rather than being truncated (windows11-reference §8.3 “Path too long”, adapted).
  Arbor can't operate on them: the kernel refuses such paths, `copyfile` has no descriptor form, and FileManager, Launch
  Services and Quick Look are path-based. A permanent delete still works, through descriptors. Opening such a file says so
  instead of asking macOS, which would silently refuse.

Known gaps: a row past the limit is a plain item (no package or alias detection, no folder size). Normalization-only renames
and right-to-left names on screen are FE-223. Nothing is claimed about Explorer's depth limits (FE-232).

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

## macOS Services and outside opens (FE-218)

Status: implemented; the headless checks pass, and the manual list below still has to be run in a GUI session. Arbor stays an
ordinary app beside Finder: the folder handler rank stays None, Show in Finder is unchanged, and nothing claims to replace
Finder (other apps' Reveal actions and Open/Save dialogs stay Finder's, FE-217). Services don't exist on Windows, so this is
a macOS adaptation, not Explorer parity.

- **Provider.** One service, Open in Arbor, for files and folders (`NSServices` in `Resources/Info.plist`,
  `Features/Services/ServicesProvider.swift`). It reads file URLs only and passes them to `application(_:open:)`.
- **One route for outside items.** The service, the Dock, `open -a` and Finder documents all go through
  `AppDelegate.openExternal` and `ExternalOpen` (ArborCore): only local absolute file URLs, at most 5,000 examined and
  16 tabs opened, checks off the main thread. A folder opens; a file Arbor browses (archive, saved search) opens as its
  own location; anything else, packages included, is revealed in its parent, and items sharing a parent share a tab.
  `Arbor <path>` from Terminal (FE-219) stays separate.
- **Consumer.** The window answers as a file-URL requestor, so AppKit adds its own Services submenu to the item
  context menu and fills Arbor ▸ Services. Other menus switch it off (`CommandDispatcher.menuBuilt` for those the dispatcher
  builds, one line each for the column header, group header, search history and network tile menus).
  The selection is never offered in the Trash, in an archive, for a disconnected mapped drive or while a text field has focus.

Manual checks, after building and running `/System/Library/CoreServices/pbs -update`:

- Finder right-click ▸ Services ▸ Open in Arbor on a folder, a file, several files, an app bundle, and with Arbor not running.
- With two Arbor windows open and another app in front, the tab opens in the frontmost of the two.
- Arbor's item menu shows Services and running one receives the files, including a service declared the older way
  (Finder's Open or Show in Finder).
- Type in the search box, right-click a result without clicking first: Services is there.
- Tree, tab, column header, Trash and archive menus show no Services; Arbor ▸ Services works from the keyboard.
- Whether the service is on by default.

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
- **DEC-qa-core-5** Undo/Redo of a move registers its inverse at once (AppKit requires it) and fills it in when
  the items have arrived. Pressing it before that says the previous step is still moving items instead of
  guessing. The move job an undo starts registers no undo of its own.
- **DEC-qa-core-6** Alerts about a window wait for that window's current sheet instead of stacking or going
  app-modal; an alert identical to one already showing or waiting is merged into it and its caller hears
  Cancel (the safe answer). Only the quit confirmation (no window involved) stays app-modal.
- **DEC-qa-core-7** In headless runs nothing outside Arbor's own windows is opened or changed: `SystemOpen`
  logs the request instead. Arbor's own sheets shown through `AlertSheets` are invisible there too.
- **DEC-qa-core-8** Arbor never lists or performs a service. macOS has no public way to enumerate services, so AppKit
  builds the Services menu and runs what the user picks; `NSPerformService` is forbidden by `SystemOpenAuditTests`.
- **DEC-qa-core-9** Items from outside that couldn't be opened are reported with a sheet, counts only, never names or paths.
  A status-bar message is cleared when the new tab finishes loading. A check that finishes more than 15 seconds after the request
  (a dead mount) neither activates Arbor nor shows anything modal: the user has moved on, so it is only noted in the
  status bar of a window already open.
- **DEC-qa-core-10** Aliases from outside behave as a double-click does: a folder alias opens its target (`.withoutUI`,
  `.withoutMounting`), a file alias is revealed and not resolved. Open handlers run off the main thread here, so they read only
  thread-safe state. A saved search read this way is limited to 1 MB and must be a regular file.

## Known gaps

- FE-218: a cold launch through the service shows Home or the restored session plus a new tab, because AppKit delivers
  the service after launch. Dock opens at launch don't have the extra tab.
- FE-218: Dock opens at launch are checked on the main thread, because the first window must be decided before Home or
  session restore. This is the one exception to the rule against disk work on the main thread here, and it is bounded by the 5,000-item cap.
- FE-218: AppKit places Services at the end of the context menu and decides which services show and in what order. `menu:item`
  dumps don't include it. The user turns services on or off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.
- FE-218: while an inline rename is open, right-clicking a different item or empty space does nothing; Explorer would commit the rename
  and show the menu. Committing can re-sort the list or raise the extension-change sheet, which would leave a menu on the wrong item.
- FE-218: keyboard-opened context menus (Shift+F10) have no Services; Arbor ▸ Services is the keyboard path.
- FE-218: revealing a hidden file while hidden items are off opens its parent with nothing selected. This applies to Dock opens as well.
- FE-218: the service title in Info.plist isn't localized; a `ServicesMenu.strings` waits for a second language.
- FE-218: at the 16-tab cap, an archive in a folder that is already open is revealed there instead of opened, because open
  handlers stop running at the cap.
- Redo (or Undo) pressed while the previous cross-volume Undo is still copying only reports that it is still
  running (DEC-qa-core-5); that step is used up, so the items stay where the first Undo put them.
- The quit confirmation ("Files are still being copied or moved") is still app-modal: it belongs to the app,
  not to a window.
- Sheets shown by features directly (not through `AlertSheets`) still rely on AppKit's own queueing when a
  second one arrives.
