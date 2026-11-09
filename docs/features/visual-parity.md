# Visual parity and window chrome

Spec: DEC-017/DEC-018 (Windows 11 look with original artwork), FE-011, FE-017–FE-021, FE-094. Reference:
docs/research/windows11-reference.md §1 (layout, navigation row, command bar, menus), §2.3 (tabs), §4 (context
menus), §5.2 (Details values), §9 (operation dialogs), §15 (visual tokens).
Code: `Sources/Arbor/Features/VisualParity/`, `Sources/Arbor/Window/TabTearOff.swift`,
`Sources/ArborCore/ExplorerFormat.swift`, `Sources/ArborCore/RecentLocations.swift`, plus small additive edits listed
under "Shared files touched".

## Status

| FE / area | What | Status | How verified |
|---|---|---|---|
| FE-011 | Navigation row order Back · Forward · Up · **Refresh** · address bar · search box (Refresh moved out of the address box) | Implemented | Headless `log` (`nav row:` line), light/dark snapshots |
| FE-011 | Back/Forward/Up/Refresh tooltips name their target: "Back to “Documents” (⌘[ or Delete)", "Up to “Users” (⌘↑)", "Refresh “Projects” (⌘R or F5)" | Implemented | Headless `log` (`tooltips:`) |
| FE-062 | Keyboard: Back · Forward · Up · Refresh are one toolbar stop of the address region (⇧Tab from the path field enters it, ←/→/Home/End move, Tab returns to the field); Tab from the field reaches the ▾, then the search box. F6 order is unchanged (tabs, address, search, command bar, navigation pane, items, side pane). In right-to-left layouts the tab overflow arrows keep pointing at the side they scroll toward and merge slots are mirrored | Implemented | Headless `key:`/`focus:` steps (focus log), `axdump`, snapshot of the focus ring |
| FE-003 | Recent-locations ▾ at the right end of the address bar (shared by all windows, most recent first, no duplicates, search results left out, vanished folders hidden; remembered across launches, see address-entry.md) | Implemented | Unit test `recentLocationsAreMostRecentFirstWithoutDuplicates`; headless `log` (`recent:`) |
| FE-020 | Drag a tab out of the tab row: it floats under the pointer; released over another window's tab row it is inserted at the marked slot (accent insertion bar), elsewhere it opens a new window under the pointer. History, selection, view mode and sort travel with the tab | Implemented | Headless steps `tearoff:`, `mergetab:`, `droppreview:` + `log` (`window tabs:`) and snapshots; pointer dragging itself is manual (scripts can't move the mouse) |
| FE-020 | A window's only tab drags the whole window; dropping it on another window's tab row merges it (a click without movement never merges) | Implemented | Code path (`tabStripDragWindow`); manual |
| FE-017 | Tabs are equal width between 100 and 240 pt; past the minimum the strip scrolls with ‹ › overflow buttons (enabled only when there is more to see) and the mouse wheel; the active tab is scrolled into view | Implemented | Headless with 12 tabs: `tab strip: overflow=true tabWidth=100 visible=3-12 of 12 back=true forward=false`, after `tabscroll:-20` `visible=1-10 … back=false forward=true`; snapshots light/dark |
| FE-017 | Tab hover/active styling: active tab joins the navigation row (rounded top, outward feet), inactive tabs show a hover fill and separators that hide next to hovered/active tabs, ✕ on active and hovered tabs | Implemented (existing, re-checked) | Snapshots light/dark |
| Type column | Finder aliases show **Shortcut**; symbolic links show the type of their target (a link to a folder is a folder, a dangling link is "Symbolic link"); all other types keep the system's real names | Implemented | Unit tests `typeNamesUseExplorerWordsOnlyWhereMacOSDiffers`, `listingTypesAliasesAsShortcutsAndLinksByTarget`; snapshots |
| §5.2 sizes | Details size columns (Size, size on disk, ZIP "Compressed size") always whole KB rounded up with grouping: `0 KB`, `1 KB`, `12,696 KB`; folders blank | Implemented | Unit tests `detailsSizeIsAlwaysWholeKilobytesRoundedUp`, `folderRowsHaveNoSizeInDetails`; snapshots |
| §5.2 sizes | Everywhere else adaptive 1024-based units, three significant digits, truncated: status bar `2.34 KB`, tiles/content, tooltips, dialogs, Properties, transfer speed `1.43 MB/s` | Implemented | Unit tests `detailsColumnsUseKilobytesAndOtherPlacesAdaptiveUnits`, transfer tests; snapshots |
| ZIP | One ZIP central-directory reader (`ZipDirectory`) for archive browsing, Extract All and the "Zipped (compressed) folders" search option; search uses a bounded read (`limit`) | Implemented | Unit tests `limitedReadStopsEarlyInOrder`, `limitedReadToleratesAPartialDirectoryPrefix`, `zipDirectoryListsEntries`, `zippedFilesOption` |
| Menus | In-window menus (command bar ▾ menus, context, tab and navigation-pane menus) use Windows 11 sentence case; the Mac menu bar keeps title case | Implemented | Unit test `inWindowMenusUseSentenceCase`; headless `menu:` dumps |
| Menus | Background menu order as §4.4: View › · Sort by › · Group by › · Refresh, then Undo · Paste · Paste shortcut, then New ›, then Properties, then Open in Terminal / Show in Finder | Implemented | Headless `menu:background` dump |
| Command bar | **New ▾** greys out where nothing can be created (This Mac, Trash, search results, archives) | Implemented | Snapshots (This Mac, search, archive) |
| Details | Headers of right-aligned layout columns (ZIP "Compressed size", "Ratio") are left-aligned like every Explorer header; ZIP folder default widths fit a standard window | Implemented | Snapshot of an opened .zip |
| Icons | Shortcut arrow overlay stays a corner badge (30 %, max 64 pt) on medium/large/extra-large icons instead of covering half the icon | Implemented | Snapshot, extra large icons |
| Search | "Advanced options ▸ Zipped (compressed) folders" (was "files") | Implemented | `searchmenu:` dump |
| Audit | Every screen in light and dark (list below) | Done | Headless snapshots read one by one |
| Selection | One rule for every list (Details, icon layouts, navigation pane, Home / This Mac / Gallery / Network tiles): accent tint while the list has keyboard focus in the active window, neutral grey otherwise; the navigation pane's current-location pill and accent bar turn grey in an inactive window | Implemented | Headless `windowactive:0` / `windowactive:1` + `log` (`selection emphasis:` line), snapshots light/dark of Details and Large icons in both states |
| FE-055 | Long names in Details: one line shortened in the middle by default; Folder Options › View › Details view › **Wrap long file names** (off by default, an Arbor addition with no Explorer counterpart claimed) lets each name take up to 3 lines. The extension is never split across lines and survives shortening; the full name stays in the tooltip, rename edits the whole name, and rows, the band, the keyboard, right-to-left layouts, compact view and text size follow the taller rows | Implemented | Unit tests `NameWrapTests`; `scripts/behavior-checks.sh namewrap`; snapshot |
| FE-204 | Right-to-left tabs: icon and title start at the right, ✕ and separator on the left; a tab dragged along the row lands in the slot counted from the right edge | Implemented | `ARBOR_RTL=1` snapshots light/dark (also pseudo-localized), `dragtab:1:-260` + `log` (`window tabs:`), unit tests `TabStripGeometryTests` |

## Audit: screens checked (light and dark)

Folder Details (plain, grouped by Type), Extra large / Medium / Small icons, List, Tiles, Content; Home; This Mac;
Gallery (empty collection); Libraries (Documents library with its Folder column); Network (nothing found);
Trash (empty); Search results with the Search options menu; an opened ZIP; Properties (General, Security, Details,
Previous Versions, folder General and Customize); Folder Options (General, View, Search); copy progress (Fewer and
More details); Replace or Skip Files; the compare dialog ("2 File Conflicts"); Extract All wizard; Map network
drive; Preview pane; Details pane; New ▾, Sort ▾, View ▾ and "…" menus, item / folder / background / tab /
navigation-pane context menus (text dumps; AppKit menus can't be drawn headless); navigation pane; tab strip
with 1, 3 and 12 tabs.

## Findings and fixes (before → after)

1. **Refresh placement.** Before: Refresh inside the right end of the address box (Windows 10 style, DEC-022 recorded
   it as an owner instruction). After: separate button after Up, the address box ends with the recent-locations ▾.
   DEC-022 rewritten.
2. **Tab tear-off/merge.** Before: dragging a tab 60 pt vertically moved it to a new window at the cascade position;
   no merge (DEC-021 listed it as missing). After: floating tab while outside the row, merge into the window under
   the pointer at the marked slot, new window placed under the pointer, single-tab windows drag and merge.
3. **Tab overflow.** Before: tabs stopped at 96 pt and the extra ones were simply clipped (scrollable only by
   trackpad swipe, no indication). After: 100 pt minimum, ‹ › buttons with correct enabled states, wheel scrolling.
4. **Type "Alias".** Before: shortcuts and symbolic links both showed Finder's "Alias". After: "Shortcut" for aliases,
   target type for links; Properties (General "Type of file", Details "Item type") agree with the column.
5. **Size column.** Before: Finder-style decimal adaptive sizes ("2 KB", "13 MB") in Details. After: Explorer's KB
   column ("3 KB", "12,696 KB"), and 1024-based adaptive sizes elsewhere ("2.34 KB", "12.3 MB", speed "1.43 MB/s")
   instead of a mix of 1000- and 1024-based numbers between the status bar and Properties.
6. **Two ZIP readers.** Before: search had its own parser without ZIP64, Unicode-path or CP437 support, which also
   kept `__MACOSX` handling separately. After: one reader with a bounded mode; the search-only parser is deleted.
7. **Menu wording.** Before: Mac title case inside the window ("Open in New Tab", "Copy as Path", "Group By",
   "Compact View", "Navigation Pane", "Close Tabs to the Right", "Details" for the pane toggle in View ▸ Show).
   After: "Open in new tab", "Copy as path", "Group by", "Compact view", "Navigation pane", "Close tabs to the
   right", "Details pane". Proper names stay ("Quick access", "Finder", "Terminal", "Trash").
8. **Background menu order.** Before: New › first, View/Sort/Group last. After: Explorer's order (§4.4), with
   "Undo" ahead of "Paste".
9. **New ▾ on This Mac / Trash / search / archives.** Before: enabled, opening a menu of disabled items. After:
   greyed like Explorer.
10. **ZIP folder Details.** Before: "Compressed size" and "Ratio" headers right-aligned and touching their
    neighbours, Date modified clipped off the window at the default size. After: left-aligned headers, narrower
    Name/Type defaults so all seven columns fit 1180 pt.
11. **Shortcut overlay.** Before: the arrow box covered the lower-left half of 256 pt icons. After: corner badge.
12. **Navigation tooltips.** Before: static ("Up to the parent folder"). After: name the destination, like Explorer.

Checked and left as is (already matching, or a deliberate Mac decision recorded elsewhere): Home sections and
empty texts; This Mac "Devices and drives" tile with capacity bar (decimal GB to agree with macOS storage figures,
home-and-this-mac decision); Trash columns and Mac name "Trash" (DEC-trash-1); "Move to Trash" instead of
"Delete" in menus (macOS wording for a recoverable delete; see DEC-parity-4); Properties, Folder Options, progress,
conflict, compare, Extract All and Map network drive layouts and wording (match §9–§14, readable in dark mode);
status bar `N items | n item selected size |` with Details / Large icons toggles.

## Decisions

- **DEC-parity-1** Sentence case applies to menus inside the window only; the macOS menu bar keeps Mac title case
  (it has no Explorer counterpart and Mac users expect it). Implemented as a title table plus
  `CommandDispatcher.menuTitleHook`, so features keep their original command titles.
- **DEC-parity-2** Sizes: Details size columns are whole KB rounded up (Explorer §5.2); all other sizes use
  Explorer's adaptive 1024-based format (`PropertyFormat.adaptiveSize`), including `StatusText.bytes` and transfer
  speed. Drive capacity on This Mac stays decimal (owned by that feature, matches the numbers macOS shows).
- **DEC-parity-3** Folders keep macOS's type name "Folder" (not Windows' "File folder") because the task is to keep
  real type names except where macOS uses a Mac-only word for the same concept (Alias → Shortcut).
- **DEC-parity-4** "Move to Trash" stays the menu wording for Delete: on a Mac, "Delete" in Finder means immediate
  deletion, so Explorer's word would misstate what the command does (safety rules, handoff §9). The command bar's
  trash-can button keeps Explorer's position and icon.
- **DEC-parity-5** Tab widths 100–240 pt follow WinUI TabView's defaults (RECALL-m); overflow uses arrow buttons
  rather than a menu, like TabView.
- **DEC-parity-6** Tear-off places the new window so the dragged tab stays under the pointer; merging targets only
  the frontmost Arbor window at the pointer (a tab row hidden behind another window, or another app's window,
  never captures the drop).
- **DEC-parity-8** Selection emphasis (`SelectionEmphasis`): accent while the list has keyboard focus in the active
  window, `Theme.selectionInactive` grey otherwise, for every list and tile view; check boxes keep the accent. Headless
  runs count as the active window so snapshots show the focused look; `windowactive:0` checks the other.
- **DEC-parity-9** Right-to-left tabs mirror their contents and count reorder slots from the right edge
  (`TabStripGeometry`); merge slots between windows already did.
- **DEC-parity-7** ~~The recent-locations list is per session and shared by all windows; it is not persisted.~~
  Superseded by DEC-address-10: the list is still shared by all windows and now survives a relaunch.

- **DEC-parity-10** Wrapped names (FE-055). A cell may hold at most `NameWrapMetrics.maxLines` (3) lines; beyond that the
  name is shortened in the middle with the icon views' `MiddleTruncation`, because AppKit clips a multi-line field without
  an ellipsis. A zero-width break goes before the extension so it can only move to the next line whole. Line breaks in a
  file name are shown as spaces: left in, `a.pdf` plus newlines could hide the real extension. Heights are measured with
  the same cell settings that draw, inside `tableView(_:heightOfRow:)`, and kept per name: `NSTableView` asks only near
  the viewport (301 of 100,000 rows when a folder opens, macOS 26), so measuring is lazy without a second estimate.
  `NameWrapHeights.measurementsPerTurn` caps the work if a table ever asks for every row. A table with the option off
  only tests `nameWrap` for nil.

## Shared files touched (small, additive)

`Views/ExplorerTableStyle.swift`, `Views/TileGridView.swift`, `Features/IconViews/ItemGridView.swift`,
`Features/GalleryLibraries/GalleryPage.swift`, `Features/Network/NetworkUI.swift` (selection emphasis, a few lines each),
`Window/TabStripView.swift` (RTL tab drawing, reorder slot, `scriptDrag`), `Window/NavigationBar.swift` (Refresh button), `Window/AddressBar.swift` (Refresh removed, recent ▾ added, `onRefresh`
kept so search's wrapper still works), `Window/TabStripView.swift` (overflow buttons, drop marker, tear-off drag loop,
three protocol methods with default implementations), `Window/BrowserWindowController.swift` (`takeTab`,
`adoptTab`, one call to `updateNavigationTooltips`), `Window/CommandBarView.swift` (New ▾ enabled state),
`Commands/ExplorerCommand.swift` (`menuTitleHook`, per-slot `sectionRanks`), `Support/Theme.swift` (tab and nav
metrics), `Views/DetailsColumns.swift` (left-aligned layout headers), `Views/DetailsViewController.swift` (KB size),
`ArborCore/FileItem.swift` (type name), `ArborCore/TransferIntent.swift`, `ArborCore/TransferRate.swift`,
`ArborCore/DetailsColumns.swift` (size formats), `ArborCore/Archives/ZipDirectory.swift` (bounded read),
`ArborCore/Search/ContentReaders.swift` and `DirectSearch.swift` (second reader removed), one-line edits in the
Archives (column widths, KB), Properties (type name), Item actions (overlay size) and Search (option wording) files.
Name wrapping (FE-055): `Views/DetailsViewController.swift` (one property each on the cell and the controller, five call
sites), `DetailsViewController+Depth.swift` (row height, column resize), `FolderOptionsCatalog.swift`,
`FolderOptionsPrefs.swift`, `PortableSettingsCatalog.swift`, `BrowserWindowController+Observation.swift`,
`ItemClickBehavior.swift` (the underline keeps the field's line break mode).

## Script steps

`tearoff:N`, `mergetab:TAB:WINDOW:SLOT`, `focuswindow:N`, `tabscroll:±N`, `windowsize:W,H`, `droppreview:SLOT`
(all 1-based), `dragtab:N:DX` (drop tab N after dragging it DX points), `windowactive:0|1` (draw as if the window
were inactive / active; headless windows are never key). The `log:` output gains `window tabs:`, `tab strip:`,
`nav row:` (with tooltips), `recent:` and `selection emphasis:` lines.
`namewrap:/path` appends, for wrapped names (FE-055): whether wrapping is on, how many names were measured, and each
row on screen with its height, field size, full-name tooltip and shown text (`|` marks the extension break).

## Known gaps

- Wrapped names: while renaming, the field keeps the row's height and longer text scrolls inside it. The laziness of
  `NSTableView` was measured on macOS 26 only; on another version `measurementsPerTurn` limits the cost, and rows beyond
  it are corrected only for what is on screen.
- Pointer-driven tab dragging (the floating tab, drop marker while hovering, single-tab window drag) can't be
  driven by headless scripts; the underlying moves are covered by the script steps above.
- Hover colors in an inactive window are unchanged (tracking areas only fire in the key window anyway).
- Windows 11's exact selection/hover colors, tab metrics and menu orders are RECALL items in the reference; they
  need a check against a Windows 11 install (spec §2.2).
- Context-menu icon row (Cut · Copy · Rename · Share · Delete as icons at the top) isn't possible with AppKit menus;
  those commands stay text items.
