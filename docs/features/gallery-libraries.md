# Gallery and Libraries

Code: `Sources/Arbor/Features/GalleryLibraries/`, logic in `Sources/ArborCore/GalleryTimeline.swift`,
`GallerySources.swift`, `Libraries.swift`, `LibraryCatalog.swift` (tests: `Tests/ArborCoreTests/GalleryLibraryTests.swift`,
`LibraryCatalogTests.swift`; headless: the `libraries` group of `scripts/behavior-checks.sh`).
Shared hooks used: see below.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-075 | Gallery: photos/videos from the collection's folders, newest first, month headers ("November 2026"), justified thumbnail rows without names, date rail (years + month ticks, click/drag jumps to a month, hover bubble), View ▾ sizes (Extra large/Large/Medium/Small), Sort ▾ Date taken ascending/descending, Collection ▾ (folder check boxes + Manage collection…), Manage collection dialog (Add…/Remove/Restore defaults), real file identity (Open, Open With, Open file location, Cut/Copy, Share, Rename via sheet, Move to Trash with undo, Quick Look, Details/Preview pane, drag out), keyboard (arrows incl. up/down by row, Shift-extend, Home/End, Return, Esc, ⌘A, Space/F2/Delete via the window's key bindings), partial coverage message for missing folders, empty states | Implemented | Unit tests (bucketing, time zones, ordering, rail years, EXIF date parsing, best date, orientation, justified layout, collection rules, bounded set). Headless runs with generated fixtures (EXIF dates 2023–2026, PNGs dated by `touch -t`, a `.mov`, a `Photos Library.photoslibrary` package and a hidden folder that must be skipped): month list, order, selection, keys, Trash (test trash), rename, Open file location, size/sort/collection toggles, missing source; snapshots light and dark |
| FE-076 | Libraries: Documents/Music/Pictures/Videos (one folder each by default, Videos → ~/Movies), custom libraries (New ▾ › Library on the Libraries page, File ▸ New Library, background and tree menus), Rename and Delete library (F2, fn+Delete, command bar and File menu for a selected tile; tile and tree menus), Restore default libraries, Libraries page (keyboard-navigable tiles, search filter, empty state), navigation pane node (hidden by default, `Prefs.showLibraries`), breadcrumbs Libraries › Documents with chevron menus, Up → Libraries, merged listing of the top level of every folder as normal items (all views, sort, group, filter, rename, Trash, drag) with a sortable "Folder" column in Details, "Manage library" dialog with Add…/Remove/Set save location/Move up/Move down/Restore defaults (default libraries only) and "Optimize this library for" (General items, Documents, Pictures, Music, Videos: columns and view through Folder Options' precedence, each library remembers its own view), persisted; watchers on every folder | Implemented; the Explorer flows it follows are RECALL (windows11-reference.md §3.5) and not verified on Windows | Unit tests (`LibraryCatalogTests`: name rules, create/rename/delete/restore, hostile preferences, limits, rename following history and search origins, saved view move, Folder column, cancellation; `GalleryLibraryTests`: defaults, add/remove, save location moves, JSON round trip, merge, symlinked duplicate folder, unavailable folder); headless `libraries` group: create with bad and good names, rename with the library open in a background tab, delete from tile and tree, Optimize with the library already open and with a filtered folder in another tab, Reset Folders, Restore defaults, the New menu and a search on the Libraries page, a 118-character name in the name sheet (not clipped, reason announced to VoiceOver); snapshots light and dark |
| FE-238 | Virtual collection write destination | Implemented | `LibraryLogic.resolveSaveLocation` (explicit → first usable folder flagged as fallback → explanation), resolved off the main thread. New folder and Paste in a library write to it; with no writable folder they show "This library has no save location." with the reason and a Manage library button (headless run with a read-only folder and with an empty library). After a save-location edit the view's drop target and `library target` both follow (headless). Removing the save location in Manage library hands it to the next folder; the fallback note stays after the reload that follows New folder; New folder's name field edits the folder just made even when an earlier folder holds the same name (all headless). Gallery has no destination: New/Paste are disabled there |
| FE-239 | Projection removal ≠ deletion | Implemented | Removing a folder from a library or the collection, deleting a library, or unchecking a folder in Collection ▾ only edits the list: `LibraryCatalog` has no way to reach a file, library tiles carry no file identity, and the confirmation says the files stay (unit tests + headless runs confirm the files stay and the Trash stays empty). Delete inside a library or Gallery is the normal Move to Trash on the real file |

## Decisions

- **DEC-GL-1** Gallery's date is EXIF/Spotlight "date taken", else the *earlier* of file creation and modification (a copied photo keeps its old modification date). Dates before 1900 or > 1 day in the future are ignored.
- **DEC-GL-2** Default collection: `~/Pictures`. Photo-library and media-library packages (`.photoslibrary`, `.migratedphotolibrary`, `.aplibrary`, `.fcpbundle`, …) are never scanned or addable; all packages and hidden files are skipped.
- **DEC-GL-3** Scanning: Spotlight (`kMDItemContentTypeTree` = public.image / public.movie; dates from `kMDItemContentCreationDate` / `kMDItemFSCreationDate`) first, then always a direct enumeration that fills what Spotlight missed (reads only the image header with ImageIO). Off the main thread, batched, cancelled when no Gallery page is in a window. Index bounded to 100,000 items (newest kept), shared app-wide; FSEvents watch on the collection rescans after changes. `ARBOR_GALLERY_NO_SPOTLIGHT=1` forces the direct scan.
- **DEC-GL-4** Nested sources (Pictures and Pictures/Trips) are scanned once; unchecking a nested folder hides its photos even if the parent is checked.
- **DEC-GL-5** Gallery is a custom page; its selection reaches commands through the new `ItemSelectionPage` hook (one additive change in `BrowserWindowController.selectedItems`).
- **DEC-GL-6** View ▾ in Gallery shows only the four icon sizes (stored separately from the folder view mode); Sort ▾ shows "Date taken" + Ascending/Descending. Implemented with command overrides that apply only while the location is Gallery (`CommandRegistry.override` / `hide(prefix:)`, order `.early`; DEC-024).
- **DEC-GL-7** Rename in Gallery uses a sheet (tiles have no names); it goes through the window's normal rename (extension warning, undo).
- **DEC-GL-8** A library's save location falls back to the next usable included folder when the chosen one is missing or read-only (the status-bar note is posted by each load, in one message with any partial-coverage note, so a reload can't replace it); with none, New/Paste explain and offer Manage library. Removing the save-location folder makes the next folder the save location (Windows behavior).
- **DEC-GL-9** Library merge dedupes by **identity**: a folder reached twice (same device + inode, e.g. a symlink) is listed once. Same-named files in different folders, and hard links in different folders, are all shown.
- **DEC-GL-10** "Folder" column text is `FolderName (parent path)`, like Windows' `Documents (C:\Users\me)`. It is a normal catalog column (`ColumnID.folder`), so it sorts and groups and is offered in Choose Details everywhere.
- **DEC-GL-11** Libraries node sits after Network (and Trash), collapsed; each library expands to its folders. `.library("Libraries")` is the Libraries page (the name is reserved).
- **DEC-GL-12** "Add Phone Photos" (Windows Phone Link QR flow) has no Mac equivalent and is not shown (DEC-019).
- **DEC-GL-13** Gallery thumbnails use main's shared `ThumbnailService` (one byte budget for all views), requested through a per-grid `ThumbnailLoader` at the shared pixel sizes, visible tiles first.
- **DEC-GL-14** Library names are trimmed, NFC, at most 120 characters, free of controls, line breaks and invisible format characters such as direction marks (joiners and tag characters stay, since emoji and some scripts need them), and unique ignoring case and width ("Libraries" is reserved the same way). `Location.library` is case-exact, so look-alikes must not coexist. Limits: 200 libraries, 64 folders each (a folder costs a watcher and a listing), 1 MiB saved; an edit that would exceed what can be read back is refused with a message.
- **DEC-GL-15** "Optimize library for" stores a `FolderTemplate` on the definition and reuses Folder Options through `FolderViews.virtualFolders`: there is no second view engine. A library's view is filed under its location key. Changing Optimize forgets that saved view, otherwise the new choice would be invisible; a rename moves it. Only tabs showing that library are re-applied, because re-applying resets a tab's filters. Apply to Folders is off for libraries, since it would copy the Folder column to a folder type.
- **DEC-GL-16** `.library-ms` import is left out. Those files locate folders by known-folder GUIDs, Windows drive or UNC paths and binary shell links; none of these resolves on a Mac without guessing, against "truthful destination resolution" and DEC-019. A `.library-ms` file stays an ordinary file.
- **DEC-GL-17** Delete library is offered on tiles and tree nodes, not inside an open library, where Delete means the real files. On a selected tile, F2 and fn+Delete act on the library and the File menu says "Delete library". Every edit reaches open tabs through a non-quiet reload (`LibraryActions`), the one path that refreshes the drop target and the tracked view; the watcher only reports changes inside the folders and coalesces them across folders.
- **DEC-GL-18** Manage library edits a draft `LibraryDefinition` through its own `add`, `remove`, `move` and `setSaveLocation`, so the folder rules exist once and the tested code is the code that runs. The Gallery list has no such rules and stays a plain row array.
- **DEC-GL-19** Folder names in the tree and the breadcrumb menus are the path's last component, not `FileManager.displayName`: that call reads the disk and these run on the main thread for up to 200 × 64 stored paths, any of which may sit on an offline share.

## Shared-file changes (after merging main)

Uses main's hooks: `LocationPageSelection` (Gallery selection → commands), `FolderViews.virtualFolders` (a library's
saved view and its Folder column), `NavigationPaneExtras.register(.afterNetwork)` (Libraries node, `.folder`
kind with preset children so it expands), `ItemViewUpdate.location`, and `ThumbnailService`/`ThumbnailLoader`
(Gallery thumbnails share the icon views' byte budget). Own additive edits: `Prefs.showLibraries` (Folder Options
wires the check box), a ▾ on titled submenu commands in `CommandBarView`, Up from a library → Libraries in
`Location.parent` (+ test), and the `Features.swift` slot line. Runtime wrapping (no file edits) of core commands
while in Gallery/libraries: `view.mode.*`, `view.compact`, `sort.*`, `edit.selectAll/selectNone/invertSelection`,
`file.rename`, `file.trash`, `file.newFolder`, `edit.paste`, `edit.pasteMove`; installed after all features register.
Inline rename is by URL in every view (`ItemViewController.beginRename(_:text:)`, `TabState.RenameTarget`), since names repeat in libraries, and `StatusText.explorerSummary` has a count-based form for rows that aren't files.
Custom libraries add small edits outside this folder: `FolderViews` (the new point, `forgetSavedView`, `moveSavedView`,
`Info.canApplyToFolders`), `ColumnDescriptor` (`truncatesMiddle`, `toolTip`), `NavigationHistory.rewriteLocations`,
`FolderViewStore.moveOverride`, `reapplyOpenViews(locationKey:)`, a dynamic tooltip on icon-only command bar buttons, and `TileGridView` moving focus to a right-clicked tile.

## Script steps

`gallerysources:/a|/b`, `gallerytoggle:/a`, `galleryselect:a.jpg|b.jpg`, `gallerykey:124[:shift]`, `galleryyear:2024`,
`gallerysize:smallIcons`, `galleryhover:x,y`, `managecollection`, `managelibrary:Documents`,
`dialog:add|remove|save|moveup|movedown:/path`, `dialog:optimize:music`, `dialog:restore|ok|cancel`, `showlibraries:1|0`,
`librarydef:Name=/a|/b` (creates the library if needed), `libraryselect:Name`, `librarytree:<command id>:Name`, `librarymenu:Name:/path`, `resetfolders`,
`sheettext:Name`, `collectionmenu:/path` (`sheetsnapshot:` comes from ItemActions). `log:` adds gallery, library (types, tiles, target, drop target), Details-column and sheet lines.

## Known gaps

- Library items with the same name in two folders select together after a plain refresh (core selection is restored by name; a click selects one row, and New folder and Rename act on the exact row).
- The search box doesn't filter Gallery.
- The Spotlight phase was not exercised by fixtures (temporary folders aren't indexed); the direct scan was. Video aspect/dates come from Spotlight only (16:9 and file dates otherwise); video thumbnails depend on Quick Look.
- A Gallery rescan after a change is a full rescan (EXIF is only read for new files).
- Gallery scroll position isn't kept when switching tabs; Quick Look arrow keys don't move the Gallery selection.
- Libraries: no per-library "Show in navigation pane", custom icon or undo for Delete library (it asks first; files are never affected); the nav pane doesn't auto-expand to reveal the current library. No `.library-ms` import (DEC-GL-16).
- macOS can't do: other apps' Open and Save panels showing Arbor libraries; Windows Search behavior tied to libraries (basic-library mode, indexed Arrange By views). There is no non-owner save location or owner-SID sharing on the Mac, so neither is offered.
- New › text, image and shortcut entries and Paste shortcut use the save location resolved when the library loaded, and grey out when there is none; only New folder and Paste explain why. Remove location from library is in Manage library, not on the tree's child nodes.
- Dropping onto a library tile or tree node is refused rather than guessed; a drop inside an open library uses the save location. On the Libraries page "Single-click to open" opens a tile, but point-to-select and the hover underline are not applied.
- A stale Back, recent or session entry for a deleted library shows the "doesn't exist" message, or Home at launch.
- Sort ▾/View ▾ on the Libraries page (a tile page) show core entries that don't apply, same as the core Home page.
