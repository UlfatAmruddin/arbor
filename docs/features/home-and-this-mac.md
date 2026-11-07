# Home and This Mac

Feature slots "Home page" and "This Mac page" in `Sources/Arbor/Features.swift`.

## Status

| FE | Requirement | Status | How verified |
|---|---|---|---|
| FE-069 | Home page | **Implemented.** Sections in Explorer order: Quick access, Favorites, Recent, each under a collapsible header (state remembered per section). Selection (one section at a time), arrows (continue into the next/previous section), Tab between sections, Return/double-click opens, ⌘Return/middle-click opens in a new tab, right-click menus from the command registry, drag out, Back/Forward, status-bar counts, command bar (Copy, Share, Copy as path…) act on the Home selection | Scripted headless runs (`log:`, `homemenu:`, `pagekey:`), snapshots light + dark |
| FE-070 | Quick access folders | **Implemented.** Tiles: 48 px folder icon, name, location (parent folder), pin glyph for pins. Pinned folders first in pin order, then up to 10 frequent folders. Menu: Open, Open in New Tab/Window, Pin/Unpin from Quick access, Remove from Quick access (frequent folders), Copy as Path, Properties (when the Properties feature registers it). Dropping folders on the Quick access background pins them; dropping on a tile copies/moves into that folder. A renamed or moved pin is followed (file ID) | Scripted menus + log; unit tests for identity |
| FE-071 | Favorite files | **Implemented.** "Add to Favorites" / "Remove from Favorites" on any file selection (all locations). Favorites list: Name · Date modified · File location. Stored as `ItemReference` (file ID + bookmark + path), so renames/moves are followed and a new file at the old path is not mistaken for it | `homeperform:home.favorite`, unit tests |
| FE-072 | Recent files and frequent folders | **Implemented.** Recent = files opened from Arbor + Spotlight `kMDItemLastUsedDate` in the home folder, last 30 days, 20 rows, newest first, merged by current path (synchronous `MDQuery` on a background queue). Folder visits are counted (frecency, 30-day half-life, 200 entries, ≥2 visits to appear). "Remove from Recent" | Unit tests (merge, cutoff, dedupe, ranking, eviction); headless Spotlight run returned results |
| FE-073 | Recommended / shared content | **Boundary.** Explorer's Recommended carousel depends on Microsoft account insights; there is no Mac provider. Omitted, as the reference (§16) suggests; Recent covers local activity | — |
| FE-074 | This PC → This Mac | **Implemented.** "Devices and drives" and "Network locations" sections (reference §3.2: no Folders section). Tiles: drive icon by kind (startup/internal, external, removable, optical, disk image, network), name, capacity bar (accent; red under 10% free), "281 GB free of 494 GB". Disk images and optical media are detected with Disk Arbitration. Live updates on mount/unmount/rename. Menu: Open, Open in New Tab/Window, Copy as Path, Eject “Name” (ejectable only), Share, Show in Finder, Properties when registered. Drop onto a writable drive transfers into its root | Mounted an 8 MB temporary DMG while the page was shown: appeared live as "diskImage", red bar when full, Eject from the page menu unmounted it and the page updated |
| FE-080 | Mac known folders | **Implemented** (core `QuickAccess.defaults`): Desktop, Downloads, Documents, Pictures, Music, Movies, home folder, Applications, all native URLs with their own folder glyphs | Snapshot |
| FE-082 | Control Home clutter | **Partial.** Sections collapse (persisted); Recent and frequent folders can be turned off. Startup location is Folder Options' job (DEC-020) | Scripted toggles |
| FE-206 | Recent activity privacy | **Implemented.** "Show recently used files" (off hides Recent and stops recording), "Show frequently used folders" (off hides them and stops counting), "Clear Arbor history" (frequent folders, Recent, removal marks; Spotlight items used before the clear stay hidden). Pins, favorites and files are untouched | Scripted run; fixture files listed unchanged afterwards |
| FE-239 | Projection removal vs deletion | **Implemented.** Remove from Recent/Favorites/Quick access and Clear history only change Arbor's records; Delete/Rename/Cut are disabled on Home and This Mac (they're not real folders) | Scripted run + `fixture-after.txt`; unit test `removingAReferenceNeverTouchesTheFile` |

Navigation pane: "This Mac" now lists drives through `VolumeCatalog.navigationNodes()`: the same names (network shares as `share (server)`), the same order and the same "Hide empty drives" rule as the page.

## Contract for Folder Options

Preferences (each change posts `Prefs.changed` with the key; defaults in brackets):

| Explorer option | Swift | Key |
|---|---|---|
| Privacy › Show recently used files [on] | `Prefs.showRecentFiles` | `home.showRecentFiles` |
| Privacy › Show frequently used folders [on] | `Prefs.showFrequentFolders` | `home.showFrequentFolders` |
| Privacy › Clear File Explorer history [Clear] | `HomeStore.clearHistory()` (posts `HomeStore.historyCleared`) | — |
| View › Hide empty drives [on] | `Prefs.hideEmptyDrives` | `thisMac.hideEmptyDrives` |

The same switches are also in Home's "…" menu (command ids `home.showRecentFiles`, `home.showFrequentFolders`, `home.clearHistory`).

## Hooks added to shared files (small, additive)

- `BrowserWindowController.selectedItems`: returns the page's selection when the shown page adopts `LocationPageSelection` (new protocol in `Locations/LocationPageSelection.swift`). Any custom page can use it.
- `BrowserWindowController`: posts `LocationEvents.didVisit` after a committed navigation and `LocationEvents.didOpenFiles` after opening files with their apps.
- `NavigationPaneController.volumeNodes`: optional provider for the drives under "This Mac".

## Scripted checks

Steps: `homerecord:/a|/b` (record files as opened, no app launched), `homefav:/a`, `homeselect:quickAccess|favorites|recent:Name|Name`,
`homecollapse:recent`, `homemenu:/out.txt`, `homeperform:<command id>` (with the Home menu's context), `homeclear`,
`pagekey:down|up|left|right|return|cmdreturn|tab`, `macselect:Name`, `macmenu:/out.txt`, `hideemptydrives:on|off`.
`log:` adds `home: …` and `thismac: …` lines. Headless runs skip Spotlight unless `ARBOR_RECENT_SPOTLIGHT_SCOPE=<folder>` is set, so snapshots never list the user's files.

## Decisions

| ID | Decision | Alternatives | Reason | Status |
|---|---|---|---|---|
| DEC-home-1 | Identity of favorites, pins and recent entries = file ID on its volume (`fsgetpath`), then bookmark, then path | Path only; bookmark only | Spec §3.2; a bookmark alone resolves to a *new* file created at the old path | Provisional |
| DEC-home-2 | Recent = Arbor's opens + Spotlight last-used dates under the home folder; 30 days, 20 rows; files only; Library, hidden and app-bundle paths excluded | Arbor's opens only | Explorer's Recent includes files opened anywhere; Spotlight is the system's record of that | Provisional |
| DEC-home-3 | Frequent folders: frecency (visits halve in weight every 30 days), shown after 2 visits, up to 10, bounded at 200 records; Back/Forward/Refresh don't count | Plain counts | Old habits fade like Explorer's list; bounded storage | Provisional |
| DEC-home-4 | Column titles: Recent "Date accessed", Favorites "Date modified", both "File location" (path with `~`) | Same date column for both | The Recent date is when the file was used; a favorite's useful date is its modification | Provisional |
| DEC-home-5 | Tile subtitle = parent folder's display name | "Stored locally"/"This PC" | Mac has no OneDrive split; the parent says where the folder is | Provisional |
| DEC-home-6 | "Clear Arbor history" in the "…" menu instead of "Clear File Explorer history" | Microsoft's wording | Name the app the user is running; DEC-018 | Provisional |
| DEC-home-7 | Recommended section omitted (FE-073 boundary) | Fake recommendations | DEC-019; no account-insights provider on Mac | Provisional |
| DEC-home-8 | Capacity text: 3 significant digits, truncated, decimal units ("15.9 GB free of 494 GB"); free = "available for important usage" (includes purgeable, like Finder) | Binary units like Windows | Agrees with Finder and the rest of Arbor's sizes | Provisional |
| DEC-home-9 | This Mac sections follow the reference (Devices and drives, Network locations); within a section: startup disk, internal, attached drives, by name. "Hide empty drives" hides drives that report no capacity (no media) | Group by every drive type | Reference §3.2; Macs rarely show media-less drives | Provisional |
| DEC-home-10 | Rename, Cut and Move to Trash stay disabled on Home and This Mac | Allow deleting the real file from Home | FE-239: removing a projection must never be confused with deleting; "Open file location" leads to the real folder | Provisional |

## Known gaps

- Search box on Home doesn't filter Recent/Favorites yet (search is another feature's slot; a page hook would be needed).
- Selection on Home isn't restored by Back/Forward (the page is rebuilt); Quick access order can't be changed by dragging tiles.
- Opening a file through "Open With ›" isn't recorded in Recent (it bypasses the window's open path).
- Hover-only "Open file location" button on Home rows (ROLLOUT) and the Activity column are not built.
- The navigation pane's drive icons come from the core `IconProvider` (a disk image shows a drive icon there, a package icon on the page).
- Network locations section only lists mounted shares; saved-but-disconnected shares belong to the Network feature.
- Explorer's exact tile metrics and colors were not measured (no Windows reference install; spec §2).
