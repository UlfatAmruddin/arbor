# Consistency across features

Features were built separately; this area makes them behave the same everywhere. Code: `Sources/Arbor/Features/Consistency/`
(registered last, in the "spare 1" slot of `Features.swift`, so it can adjust what other features installed),
logic in `Sources/ArborCore/Consistency/`, unit tests in `Tests/ArborCoreTests/ConsistencyTests.swift`.

## Status

| # | Fix | Status | Regression test |
|---|---|---|---|
| 1 | Search box per location | **Implemented.** Folders: search (unchanged). **Home**: user folder + pinned folders and Favorites/Recent files outside it ("Search Results in Home", Up/Close search return to Home). **Library**: all its folders ("Search Results in Documents"). **This Mac**: Spotlight index everywhere + direct scan of the other local drives (network drives index only). **Trash, archives**: filter the items shown. **Gallery, Network, server pages, Libraries page**: filter the page's tiles by name. Pages with nothing to search: box disabled, placeholder "Nothing to search here", tooltip explains | Unit: `ScopedSearchTests` (keys, origin, nesting, limits). Headless: `scopedrequest:` from Home/library/This Mac; library search found a file in a second folder, title + Up; Gallery `search:zzz` → 0 shown, `pho` → 1; Network `search:NAS` → 3 tiles; Libraries page `Do` → 2 tiles (snapshot) |
| 2 | Home Back restore; Recent | **Implemented.** Home saves selection (per section, by path) and scroll in the tab history; Back/Forward, Refresh and tab switches restore them (`LocationPageViewState`, any page can adopt it). "Open With ▸" now records files in Recent; opening a file shortcut records its target (`behavior-checks.sh recent`); double-click in every view (Details, icons, Gallery, search results, Home) already went through `open`; read-only temporary copies of archive members are never recorded | Headless: select Recent `notes.txt`, go to a folder, Back → `page selection=[notes.txt]`; `openwith:1` → `recent=[report.txt]`; Gallery single click → `recent=[photo.png]` |
| 3 | Item actions in all layouts | **Implemented.** Icon layouts: Tab / Shift-Tab rename chaining, spring-loaded folders on drag hover, right-button drag (drop menu from DragPolish), multi-item rename numbering (already routed). Folder Options: underline icon titles always/hover in icon layouts; single-click to open, point to select, hover underline on Home, This Mac and Gallery; pop-up descriptions follow the setting on Home/This Mac tiles, Home lists and Gallery (Gallery now has infotips) | Headless: `renametab` while renaming `b.txt` in Large icons → `renaming=notes.txt`; F2 on two items, type "Doc" → `Doc (1).txt`, `Doc (2).txt`; `setpref` always → all icon names underlined, hover + `hoverrow:Pics` → only Pics; Home `pagehover:Pics` → selected + underlined (snapshot), `pageclick:Pics` → opened |
| 4 | Context menus per location | **Implemented** (`MenuAudit`). In context menus only: commands disabled for structural reasons are left out (Cut/Copy/Rename/Move to Trash on drives and Home, Create shortcut without a folder, Share/Copy as Path/Show in Finder where nothing applies); New/Paste/Paste shortcut/Move Item Here on the background need a writable folder; Trash items get Restore/Open/Cut/Copy/Delete/Show in Finder/Properties (one Properties); archives drop Cut, Rename, Delete, Share, Create shortcut, Copy as Path, Terminal, New/Paste; a disconnected mapped drive offers only Open, Reconnect, Open in new tab/window, Disconnect. The command bar and menu bar still show greyed items | Headless `menu:item`/`menu:background`/`macmenu`/`menu:tree` dumps for folder, Trash, archive, This Mac, Gallery, library, Home, search results, fake-network disconnected drive |
| 5 | Sorting | **Implemented.** Sort values for every extra column (Trash Original Location / Date Deleted, cloud Status, search Folder / Match, ZIP Compressed size / Password protected / Ratio, library Folder); header clicks and Sort ▾ entries work in every layout. **Relevance (FE-145)** is the default order of search results (exact name, prefix, substring, contents, other; more matched words first) with "Relevance" in Sort ▾; leaving results restores the previous order; refining keeps the order the user picked | Unit: `SearchRelevanceTests`. Headless: search "report" → report.txt, Reports, reports-old.txt, Annual report.md; Trash by Date Deleted asc/desc; ZIP by Compressed size; search by Folder; back in a folder → Name |
| 6 | Quick Look / Preview for archive members and Gallery; nav pane promises | **Implemented.** Members are extracted on demand (safe extraction of one member, ≤ 64 MB, not encrypted) to a read-only temporary copy, cached (12) and used by Quick Look and the Preview pane ("Preparing a preview…", "too large", "password protected" otherwise). Gallery selection already fed both; Quick Look arrow keys now go to the page's view (Gallery moves its selection). The navigation pane registers the file-promise types and uses the same drop handlers as the item views | Headless: archive member selected with Preview pane → `quicklook url=…/Arbor Archives/…/notes.txt`, pane shows the text (snapshot); `nav pane accepts promises=true` |
| 7 | `.arborsearch` from Finder | **Implemented.** `Resources/Info.plist` exports `io.github.arbor-files.saved-search` (extension `arborsearch`, conforms to JSON) and claims it as Owner/Viewer. `application(_:open:)` opens any file that has an Arbor location (saved search, archive) as that location, and queues documents that arrive before launch finished | Unit: `SavedSearchDocumentTypeTests` parses Info.plist. Headless: `searchsave:` then `opendoc:` → new tab "Search Results in fx" |
| 8 | FE-188 drive capabilities | **Implemented.** Drive Properties ▸ File System: file system, access, case sensitivity/preservation, Trash support, extended attributes, clones, hard/symbolic links, compression, encryption, journaling, maximum file size, with plain-language notes (read-only NTFS explanation, FAT32 4 GB, no Trash). Values the system doesn't report say "Unknown" | Unit: `VolumeCapabilityTests` (startup volume, NTFS, FAT). Headless: `propertiesof:/` + `proptab:File System` + `proplog` (snapshot checked) |

## Decisions

- **DEC-consistency-1** Search scope for virtual places is carried in `SearchRequest.extraScopes` and `originKey` (location key
  items `also=` and `from=`, absent for plain folder searches, so existing keys are unchanged). Extra folders are scanned
  directly; extra files are matched by themselves; Spotlight stays scoped to the main folder. At most 64 extras.
- **DEC-consistency-2** This Mac searches the Spotlight index plus a direct scan of other *local* drives; network drives are
  left to the index (scanning them would be very slow). Coverage text still says the startup disk comes from the index.
- **DEC-consistency-3** Trash and archives keep the in-place filter rather than a recursive search (Explorer filters the
  Recycle Bin; a ZIP search would need a new location kind). Gallery/Network/Libraries filter their tiles by name.
- **DEC-consistency-4** Context menus hide commands that can't apply; the command bar and menu bar keep them greyed
  (Explorer greys command-bar buttons). Paste stays greyed on a folder's background while the clipboard is empty.
- **DEC-consistency-5** Relevance doesn't group folders first (it's an order by match quality). It is offered as
  "Relevance" in Sort ▾ only in search results and never becomes the folder default.
- **DEC-consistency-6** Archive member previews reuse the archive feature's safe extraction (zip-bomb and space guards)
  and are limited to members ≤ 64 MB; larger or encrypted members show an explanation instead.
- **DEC-consistency-7** File System is a separate drive Properties tab (a Mac addition; Explorer shows only the format
  name on General).
- **DEC-consistency-8** Headless runs record "Open With" without launching the app (like the archive feature's Open).

## Hooks added to shared files (small, additive)

- `Location.swift`: `SearchRequest.extraScopes`, `originKey`, `origin`; key items `also`/`from`; search `displayName`/`parent()` use the origin.
- `BrowserWindowController`: `applyFilter` passes text to a `LocationPageFiltering` page; pages adopting `LocationPageViewState`
  are captured into history and restored; Quick Look asks `PreviewHooks.url(for:)`; Quick Look keys go to a page's view.
- `Locations/LocationPageExtras.swift` (new): `LocationPageFiltering`, `LocationPageViewState`, `PreviewHooks`.
- `SearchRegistry.registered`; `ExplorerSearchController.scopedRequest`; `SearchSession` scans `extraScopes`.
- `InteractionHooks.rightDrag`; `ItemViewHooks.underlinesName`; `TileView.titleField`, `showsDescriptions`, `refreshToolTip()`;
  `GalleryGridView.showsDescriptions`, `item(atWindowPoint:)`, `windowPoint(ofName:)`, Gallery infotips; `GalleryPageController.filterText`;
  `TileSectionsView.filterText`; `LibrariesPageController.filterText`; `ExplorerHomePage` view state and section accessors;
  `ThisMacPage.driveGrids`; `HomeFileList` calls `ItemViewHooks.decorateName`; `ArchiveFeature.makeReadOnly` is internal.
- Icon views: Tab chaining in `IconViewController`, spring-loading/right-drag/underline in `ItemGridView`/`ItemGridDrawing`.
- `NavigationPane`: promise drop types and `ItemHooks` drop handlers. `MoreTabs`: File System tab for volumes. `AppDelegate`: document opening.

## Script steps

`scopedrequest:/out`, `openwith:N`, `homescroll:Y`, `quicklook`, `opendoc:/path`, `pageclick:Name`, `pagehover:Name`,
`setpref:key=value`, `renametab`, `renamebacktab`. `log:` adds `consistency:` lines (search box state, sort, Recent, page
selection/hover, Gallery/Network filter counts, icon underlines, preview message, Quick Look URL, nav pane promise types).

## Known gaps

- Spring-loading and right-button drags in icon layouts were verified by code review and build (headless runs can't drive a
  real drag session); the drop menu and spring timer are shared with Details, which has scripted checks.
- Extra search scopes aren't watched for changes after a search finishes (the main scope is); Refresh reruns everything.
- This Mac's direct drive scan wasn't observed on a second local drive (none attached during tests).
- The Details pane (side pane) still shows only what the Properties feature reads for archive members.
- A tab switch away from Gallery and back still doesn't keep Gallery's scroll position (Gallery doesn't adopt `LocationPageViewState` yet).
- Underline/single-click on Home's Favorites and Recent lists follow the table rows; Network tiles keep their own click behavior.
