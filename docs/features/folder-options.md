# Folder Options, per-folder views, session restore

Code: `Sources/Arbor/Features/FolderOptions/`, logic in `Sources/ArborCore/FolderOptions/`, tests in
`Tests/ArborCoreTests/FolderOptionsTests.swift`. Registered with `FolderOptionsFeature.register()` in `Features.swift`.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-042 | Folder Options dialog: General · View · Search, Windows order and wording, OK / Cancel / Apply, Restore Defaults per page. Opened from "…" ▸ Options and Arbor ▸ Settings… (⌘,) | Implemented | Unit tests (catalog order, draft Apply/Cancel, per-page defaults); headless snapshots of all three pages in light and dark; scripted Apply / OK / Cancel / Restore Defaults runs |
| FE-043 | Every Advanced settings item from reference §11.2. Honored by the app: compact view, full path in title bar (tab and window title), hidden files, hide empty drives (navigation pane), hide extensions, hide folder merge conflicts (auto-merge; files inside still ask), hide protected OS files, restore windows, pop-up descriptions (name infotips), preview handlers (Preview pane), status bar, sync provider notices, check boxes, typing into the Search box, availability status, expand to open folder, show all folders. Disabled with a one-line Mac reason: Always show menus, folder-tip sizes, separate process, drive letters, NTFS color, Sharing Wizard | Implemented | Scripted runs log each effect (status bar frame 0, tab title = path, `.hidden-note` shown while `.DS_Store` stays hidden until the protected box is cleared after the warning, tree rows, new windows) |
| FE-045 | Protected system items: Mac definition (macOS bookkeeping files such as `.DS_Store`, `.Spotlight-V100`, `._*`, Windows `desktop.ini`/`Thumbs.db`, and hidden folders at `/`), with a Mac-worded warning when shown | Implemented | Unit tests; scripted run |
| FE-046 | Single-click to open (point to select), underline always / on hover; double-click default. ⌘/⇧-click only select | Implemented: Details and icon/list/tiles/content layouts (underline in Details only) | Scripted clicks via real posted events open a folder in Details and Large icons; point-to-select verified in both |
| FE-040 | One folder type chain: Properties › Customize ("Optimize this folder for", `FolderTemplateStore`) → Downloads → known folder or inside one → content (≥50% of files) → General items. The same answer is grouping's column-set kind (`ViewOptions.folderKindResolver`) | Implemented | Unit tests; scripted: choosing Pictures in Properties switches the folder to Large icons and the Pictures column set; Folder Options shows "set in Properties" |
| FE-041 | Per-folder view mode, sort (any column), Group by and Details columns (grouping's `ColumnSet`), keyed by volume UUID + file number (path fallback), in `~/Library/Application Support/Arbor/FolderViews.json` (2,000 folders, LRU pruned). Column edits (Choose Details, header menu, user resize/reorder) are saved for the folder through `ViewOptions.columnsEdited`. Never writes `.DS_Store` | Implemented | Unit tests; scripted: sort, Group by, column width and hidden column restored on return and after relaunch |
| FE-052 | Precedence app default → folder type (built in, or "Apply to Folders"; columns and default grouping from the kind's column set) → this folder; source shown in View ▾ ("Folder view: Saved for this folder (Pictures)") and on the View page | Implemented | Unit tests; scripted run and menu log |
| FE-248 | Apply to Folders (mode/sort to the template, columns + Group by to the kind's column set) / Reset Folders (view database, column sets, session Group by memory) state their scope in a confirmation and never touch files; Reset This Folder's View in the View menu | Implemented | Scripted run (applied → saved=0; reset → Pictures defaults, no grouping) |
| FE-024 | Restore previous folder windows: windows, frames, tabs, active tab, Back/Forward (20 each way), view and sort | Implemented | Two-launch headless run with `ARBOR_STATE_DIR` |
| FE-026 | Windows whose title bar is on no screen move onto one (launch, restore, display change) | Implemented | Unit tests (geometry); scripted `movewindow` + `screenschanged` |
| FE-205 | Settings scope: app-wide in `Prefs`; per-folder in the view database; window/tab in the session file | Implemented | — |
| FE-251 | Restored inactive tabs keep keys only and load when first shown; session bounded (20 windows, 40 tabs, 20 history entries) | Implemented | Unit tests |

## Decisions

| ID | Decision | Why |
|---|---|---|
| DEC-FO-1 | "Hide extensions for known file types" defaults to off in Restore Defaults (Windows: on) | Keeps DEC-008 (extensions visible) |
| DEC-FO-2 | Wording adapted where the Windows text names Windows: "Open Arbor to:", "This Mac", "Clear Arbor history", "…at launch" (Windows: "at logon"), Mac-worded protected-files warning | Honest wording (DEC-019) |
| DEC-FO-3 | "Include account-based insights…" (Office.com) shown disabled with a reason; "Show recommended section" and the rollout-only "Enable window preloading" omitted | No Microsoft account services |
| DEC-FO-4 | Reset Folders resets every folder and every applied template (one confirmation that says so); Apply to Folders replaces saved views of the same type | Matches the spec; scope stated before acting (FE-248) |
| DEC-FO-5 | Built-in template defaults: Pictures and Videos open in Large icons; others Details, Name ascending, folders first | Reference §5.1 (RECALL); falls back to Details until icon views exist |
| DEC-FO-6 | A saved folder view is a full snapshot (mode, sort, Group by, columns) taken whenever the user changes view, sort, grouping or columns in that folder | Simple, predictable "this folder" source |
| DEC-FO-7 | Column edits belong to the folder (Explorer), not to every folder of the kind; kind-wide column sets change only through Apply to Folders. Grouping's resize handler now ignores the Name column's automatic resize with the window | Avoids saving a view on every window resize |
| DEC-FO-13 | One `FolderTemplate` (Properties', `generalItems`…, made `Codable` here); grouping's `FolderKind` is derived from it (Downloads added by location) | One answer to "what kind of folder is this" |
| DEC-FO-14 | Privacy and "Hide empty drives" are Home's preferences (`home.*`, `thisMac.hideEmptyDrives`); "Clear Arbor history" calls `HomeStore.clearHistory()`. "Display file icon on thumbnails" is disabled with a reason (icon views draw no badge) | No parallel keys; no dead check boxes |
| DEC-FO-8 | The session is written every few seconds while the option is on (and at quit); turning it off deletes the file | Survives crashes and logout; no location record kept when off |
| DEC-FO-9 | Pointing selects after 0.4 s in single-click mode; a second click of a double-click is ignored | Windows hover time; avoids opening twice |
| DEC-FO-10 | "Show all folders" adds the home folder and Trash to the tree's top level | Mac stand-in for Windows' Desktop root |
| DEC-FO-11 | "Hide empty drives" is This Mac's rule (`VolumeCatalog`), used by the page and the tree | One rule |
| DEC-FO-12 | Sync provider notices: one status-bar notice when entering an iCloud Drive or `~/Library/CloudStorage` provider; availability status = cloud mark on such folders in the tree | Real, local information only |

## How it connects to other features

- Folder type: `FolderViews.folderType(url, items)` = `FolderTemplateDetector.resolve(… chosen: FolderTemplateStore(defaults: Prefs.store).effectiveTemplate(for:))`; installed as `ViewOptions.folderKindResolver`. A Properties change (`PropertiesFeature.folderTemplateChanged`) re-resolves open tabs.
- Columns and Group by: `ViewOptions.options(for: tab)` holds them; Folder Options overrides them per folder on display and records them through `ViewOptions.columnsEdited` (added) and the view-state hook. Added to `ViewOptions`: `columnsEdited`, `saveEditedColumns(_:)`, `reset(_:)`, `forgetGroupMemory()`.
- Keys others read: `alwaysShowIcons` (icon views), `itemCheckBoxes` (Details and icon views), `showPopupDescriptions` (Details and icon-view infotips), `showLibraries` (Libraries; disabled while `.library` is a placeholder), `searchWithoutIndex`, `searchIncludeSystemDirectories`, `searchIncludeCompressedFiles`, `searchFileContents` (search). Home owns `home.showRecentFiles`, `home.showFrequentFolders`, `thisMac.hideEmptyDrives`; the dialog writes them through `Prefs.showRecentFiles` etc.
- `FolderOptionsHistory.register(name) { … }` for other history owners; Home is registered.
- Hooks: `Window/WindowHooks.swift` (`WindowHooks`, `ItemViewHooks`, `NavigationPaneHooks`, `PreviewPolicy`).

## Shared files touched (small, additive)

`Features.swift` (slot), `Prefs.swift` (helpers + `showLibraries`), `MainMenu.swift` (commands in `.mainMenu("Arbor")` go into the app menu), `BrowserWindowController.swift` (hook calls, `refreshChrome()`, start location, own-window hook), `TabState.swift` (title hook), `AppDelegate.swift` (start location, restore call, `openWindow(tabs:activeIndex:)`), `NavigationCommands.swift` (new tab start location), `DetailsViewController.swift` (one decorate call), `NavigationPane.swift` (four hook calls), `PreviewPane.swift` (preview-handler gate), `OperationCenter.swift` (folder merge without asking), `DetailsDepth/ViewOptions.swift`, `DetailsDepth.swift`, `DetailsViewController+Depth.swift` (column edits through `saveEditedColumns`; user-only resize), `IconViews/ItemGridView.swift` (infotip follows "Show pop-up description").

## Script steps

`folderoptions:<general|view|search>`, `fotab:`, `foset:key=value` (clicks the real control), `fobutton:<title>` (sheet first), `fosnapshot:<png>` (also `-sheet.png`), `folog:<txt>`, `singleclick:<name>`, `doubleclick:<name>`, `hoverrow:<name>`, `typekeys:<text>`, `setcolumn:<id>:<width|hide>`, `sortby:<key>[:desc]`, `sessionsave`, `movewindow:x,y,w,h`, `screenschanged`. `ARBOR_STATE_DIR=<tmp>` keeps the view database, session and Folder Options values on disk for headless runs (otherwise memory only).

## Known gaps

- Hover underline is drawn in Details only (icon views show their own hover highlight).
- Folder tips don't list folder contents (that would need I/O per hover).
- Search-tab values are stored for the search feature; the core folder filter doesn't use them.
- The dialog uses Mac check boxes, radio buttons and pop-up; tabs, group boxes, list frame and buttons are drawn Windows-style. Selection after restore isn't restored (location, history and view are).
