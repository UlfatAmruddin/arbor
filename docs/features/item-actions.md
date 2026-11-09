# Item actions: New menu, shortcuts, Send to, rename, image actions, drag polish

Code: `Sources/Arbor/Features/ItemActions/` (registered by `ItemActionsFeature.register()` in `Features.swift`),
logic in `Sources/ArborCore/NewItemTemplates.swift`, `BatchRename.swift`, `ImageRotation.swift`, tests in
`Tests/ArborCoreTests/ItemActionsTests.swift`. Core hooks: `Sources/Arbor/Support/InteractionHooks.swift`.

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-023 | Middle-click on a breadcrumb segment | Implemented for segments: opens that location in a new, active tab (as tree nodes and rows do), including non-folder segments. Tabs, folders, tree nodes and Home tiles have their own middle-click handling outside this feature | Headless `crumbmiddle` through the window's event path. **Not tested with a physical third button** |
| FE-057 | Select all / Select none / Invert selection | Implemented (core commands re-registered with Explorer wording "Select all"… in the "…" menu; Mac title case in the menu bar). They act on visible (filtered) items; the status bar shows the count | `menu:seemore` dump; existing scripted selection checks |
| FE-064 | Tab / Shift-Tab while renaming | Implemented in the Details view: commits and starts renaming the next / previous item in view order (also when the name is unchanged); Escape stops | Headless: `editorcmd:insertTab:` / `insertBacktab:` with `log` (rename field state) |
| FE-088 | New ▸ templates | Implemented: Folder, Shortcut, separator, Bitmap image, [Compressed (zipped) Folder: archives feature], Rich Text Document, Text Document. Windows names with "(2)" numbering, then inline rename with the base name selected. Every file is valid; no iWork/Office items | Unit tests decode the BMP with ImageIO and the RTF with AppKit; headless creation + rename snapshot |
| FE-089 | Multi-item rename | Implemented: F2 with several items selected edits the first (whole batch stays selected); the typed name becomes "Name (1).ext", "Name (2).ext"… in view order, each item keeping its extension, numbers taken by other items skipped. One undo step | Unit tests; headless rename + ⌘Z |
| FE-092 | Create shortcut / Paste shortcut / New ▸ Shortcut | Implemented with macOS aliases (`.suitableForBookmarkFile`), named "<name> - Shortcut". Create Shortcut wizard (location + Browse…, then name; Next/Back/Finish/Cancel); web or server addresses become `.webloc`. Opening a folder shortcut navigates to the target; a file shortcut opens its target; a broken one shows "Problem with Shortcut" with Yes (move to Trash, undoable) / No. Shortcut arrow overlay (own artwork) on aliases and symbolic links. "Create Symbolic Link" is a separate File-menu item | Headless: create, open, broken alias, wizard (bad path error, folder, web address), paste shortcut; snapshots light/dark |
| FE-096 | Send to ▸ | Implemented: Compressed (zipped) folder (only when `archive.compress.zip` is registered), Desktop (create shortcut), Documents (copy), Mail recipient (files only; system compose-mail service), removable/external drives (copy). Bluetooth and Fax omitted | Headless with `ARBOR_TEST_SENDTO_ROOT` / `ARBOR_TEST_SENDTO_DRIVE` (never the real folders) |
| FE-097 | Rotate / Set as desktop background / Print | Rotate right/left implemented (contextual command bar + context menu); Set as background implemented (all screens). Print omitted (no honest Mac API) | Unit tests (pixel layout, orientation tag, refusal); headless rotation, checked with ImageIO; wallpaper is never changed in headless runs |
| FE-100 | Pin to Start / taskbar | **Boundary.** No menu item | DEC-items-9 |
| FE-103 | Advanced batch rename | Implemented: "Batch rename…" (item menu for 2+ items, "…" menu, Edit menu). Find/replace (plain or regex, match case, include extension), insert before/after, case change, numbering (start, step, digits, before/after, separator), extension keep/lower/upper/remove/change, live preview with OK / Unchanged / Name already exists / Duplicate name / invalid, Rename disabled while any problem exists; swaps handled; all-or-nothing; one undo step | Unit tests; headless dialog + rename + undo; snapshot |
| FE-106 | Right-button drag menu | Implemented: a right-button drag from the Details view shows Copy here / Move here / Create shortcuts here / Cancel on drop, the plain-drag action in bold ("Move here" hidden for same-folder). ⌥⌘-drop creates shortcuts | Drop path headless (`simdrop:right…`, `dropmenu:`). **Starting a right-button drag was not tested with a physical mouse** (headless runs can't post real mouse events) |
| FE-107 | Tree and breadcrumb drop targets | Implemented: tree nodes and visible breadcrumb segments that are real folders take drops under one rule set (`DropPolicy.operation` / `accept`) and one path (`transferDropped`: drop menu, shortcuts, overlapping sources, cloud prompt, conflicts, undo). The target gets a selection fill and an accent border; the drop goes to the location stored with that highlight and is refused if the bar was rebuilt. An invalid target shows no highlight and no operation badge | Unit tests of the shared rules; headless group `breadcrumb` in `scripts/behavior-checks.sh`, including a right-to-left run (segment order, hit testing, middle-click). The highlight's look was reviewed once by eye in snapshots (light, dark with increased contrast, right-to-left); no script repeats that review. **A real drag session was not tested** (headless runs can't start one) |
| FE-108 | Spring-loading | Implemented: a drag resting 0.7 s on a folder row or breadcrumb segment opens it, on a tree node expands it, on a tab switches to it; leaving the target, the view, or dropping cancels | Unit tests of the timer logic; headless through the views' real drag code (`springrow`, `springtree`, `springtab`, `crumbhover`) including cancel |
| FE-109 | Drop onto background | Implemented (core targeting, verified): background and file-row drops go to the folder shown | Headless `simdrop:plain:c.md:Folder/a.txt` moves into the shown folder |
| FE-111 | Overlapping drag sources | Implemented: a folder plus items inside it are transferred once (drops, Send to) | Unit test; headless drop of `Other` + `Other/inner/deep.txt` |

## Decisions

- **DEC-items-1** Shortcuts are Finder aliases (they follow moved targets), named like Explorer: "Report.pdf - Shortcut", "… (2)". Web and server addresses typed in the wizard become `.webloc` files (the Mac's Internet shortcut). Symbolic links are a separate, clearly named File-menu action ("<name> - Symbolic link").
- **DEC-items-2** New ▸ Bitmap image writes a valid 1×1 white 24-bit BMP (Windows writes a zero-byte file that Mac apps won't open). Text Document is empty, Rich Text Document a minimal valid RTF (kept although 24H2 removed WordPad). No Pages/Numbers/Keynote/Office items: they can't be created as valid files without the apps (none installed on the build Mac).
- **DEC-items-3** Rotation is lossless: JPEG/HEIC/TIFF change only the orientation tag (pixels and metadata copied as is); PNG/BMP/single-frame GIF re-encode rotated pixels (lossless formats, properties kept). Other formats are refused with a message. Files are replaced atomically. Undo rotates back the other way.
- **DEC-items-4** "Set as desktop background" sets every screen (Explorer applies it to all monitors), not only the main screen.
- **DEC-items-5** Print is omitted: macOS has no public "print with the default app" API; a button that only opened the file would be a fake feature (DEC-019).
- **DEC-items-6** Send to Documents and Send to a drive **copy** (Explorer's Send to never moves). Mail recipient uses the system compose-email service. Bluetooth and Fax have no Mac equivalent and are omitted.
- **DEC-items-7** Right-drag menu items: "Copy here", "Move here", "Create shortcuts here", "Cancel". ⌥⌘-drop (Finder's alias gesture) creates shortcuts, the Mac counterpart of Explorer's Alt-drag. ⌃-drop isn't offered: AppKit turns ⌃ into a link operation that local drags exclude.
- **DEC-items-8** Spring-loading delay 0.7 s; a folder row or breadcrumb segment opens in the same tab, tree nodes expand (no navigation), tabs activate. Tabs are not drop targets; tree nodes and breadcrumb segments are.
- **DEC-items-9** FE-100 boundary: "Pin to Start/taskbar" has no Mac counterpart. "Add to Dock" would require writing the Dock's preferences (`com.apple.dock`) and restarting the Dock, which is editing system preferences; nothing is shown (DEC-019).
- **DEC-items-10** Multi-item rename strips the edited item's extension from the typed text ("Holiday.jpg" → base "Holiday"), keeps each item's extension, numbers in view order and skips numbers already used by other items.
- **DEC-items-11** Batch rename compares names case-insensitively (default Mac volumes), flags a name that would make an item hidden (leading "."), and renames all-or-nothing through temporary names when names swap.
- **DEC-items-12** Context menus and the command bar use Explorer wording ("Create shortcut", "Paste shortcut", "Select all", "Batch rename…"); the menu bar uses Mac title case.
- **DEC-items-13** Core interactions are extended through `InteractionHooks` (open file, commit rename, drop, drag hover, right mouse down, icon decoration) instead of rewriting core code.
- **DEC-items-14** Middle-click on a breadcrumb segment opens a new tab (research reference §2.3, ROLLOUT [W24]). The reference doesn't say whether the tab comes to the front; Arbor activates it, as tree nodes and rows do. Provisional.
- **DEC-items-15** Breadcrumb drop highlight (PROP, no reference evidence of how Explorer draws it): selection fill plus a 1.5 pt accent border, drawn ahead of hover and press so nothing competes with it. Only segments whose location is a folder qualify; Home, This Mac, Network, servers, archives, search results and libraries have no folder to receive files, as in the tree. Needs an AUDIT observation.
- **DEC-items-16** Breadcrumb spring-loading (PROP, follows the tree per FE-108; no reference evidence). A segment has nothing to expand, so it opens like a folder row, through normal navigation (Back works). The folder already shown never springs. Springing allows **one spring per visit to the bar**: navigating to an ancestor can uncollapse the path, which slides another segment under a pointer that hasn't moved, and that segment would spring next and climb the path by itself. After a spring segments still highlight and take drops, and leaving the bar and coming back allows another.
- **DEC-items-17** The bar reuses its last hover answer while the folder, modifier state and source mask stay the same, and forgets it when the drag leaves or drops. AppKit asks on every periodic update, and the rules read the whole drag pasteboard; `DropPolicy.accept` still checks again at drop time.

## Script steps (headless)

`sheettype:text`, `sheetsnapshot:/path.png`, `editorcmd:insertTab:`, `batchset:key=value` (find, replace, regex, matchCase,
includeExtension, prefix, suffix, case, numbering, start, step, digits, separator, numberAtStart, extension, newExtension),
`simdrop:plain|right:<row or ->:<a|b>`, `dropmenu:<title>`, `springrow:<name or ->`, `springtree:<row or title>`,
`springtab:<n>`, `sendto:<title>`, `openitem:<name>`, `dragfiles:plain|right:</abs/a|/abs/b>`, `crumbhover:[copyonly:]<title, chevron:<title>, - or =>`,
`crumbstate:/path`, `crumbleave`, `crumbdrop`, `crumbmiddle:<n>:<target>`, `treedrop:<title>`. `log` adds: drop menu, last spring, last drag, batch rename preview, shortcuts
and their targets, sheet title, rename field state. Environment for Send to: `ARBOR_TEST_SENDTO_ROOT` (folder holding
`Desktop/` and `Documents/`) and `ARBOR_TEST_SENDTO_DRIVE` (a folder posing as a removable drive); without them, headless
runs hide Desktop/Documents and never touch the real ones.

## Known gaps

- Starting a right-button drag needs a check with a physical mouse; the drop menu itself is verified.
- Breadcrumbs still need one real drag (including spring-loading and the cursor badge) and one physical middle-click. Both were exercised only through the views' real code with simulated drag info and events.
- Entries in the chevron menus, the recent list and the « overflow menu can't be drop targets: `NSMenu` has no drop support, and opening one on hover would start modal menu tracking inside the drag. Collapsed ancestors can't be reached as targets until the window is wider or the path shorter.
- `NSMenuItem` has no public way to report a middle-click, so menu entries open only in the same tab. Trackpads and the Magic Mouse produce no button 2 event without third-party configuration; nothing is faked for them.
- AppKit has no public drag caption such as "Move to X"; feedback is the highlight plus the system's cursor badge.
- Whether Explorer's breadcrumbs highlight this way or spring-load needs an AUDIT observation (DEC-items-15, DEC-items-16).
- Details and icon views keep their own copy of the rules. They could call `DropPolicy.operation` and `accept`; they weren't moved to keep this change to one topic, and because their spring logic depends on the computed kind.
- Hovering a drag never asks a share for its volume: paths on a network mount are compared through the cached mount table. The table reads the path as written, so a folder reached through a symlink into a share still asks and can stall while that server hangs.
- Tile drops (Home, This Mac) call `startTransfer` directly and so miss the right-drag menu and overlap removal. This predates the breadcrumb work and is worth its own fix.
- Tab/Shift-Tab rename sequencing, right-drag start and row spring-loading are wired in the Details view. Other view modes get the drop menu, de-duplication and multi-rename automatically (they go through `itemViewTransfer` / `itemViewRename`), but must call `InteractionHooks.dragHover` from their validate-drop and `InteractionHooks.rightMouseDown` for the rest.
- The Type column shows the system's "Alias" for shortcuts (Explorer: "Shortcut"); the type text comes from the core listing.
- With file name extensions hidden, "a.txt - Shortcut" is shown as "a" (the core treats "txt - Shortcut" as an extension).
- HEIC orientation writing depends on ImageIO support on the Mac; failures are reported and the file is left unchanged.
- The New ▸ "Compressed (zipped) Folder" slot is reserved (`MenuSection.newFileTypes`, order 20) for the archives feature.
