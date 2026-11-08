# Gallery and Libraries

Code: `Sources/Arbor/Features/GalleryLibraries/`, logic in `Sources/ArborCore/GalleryTimeline.swift`,
`GallerySources.swift`, `Libraries.swift` (tests: `Tests/ArborCoreTests/GalleryLibraryTests.swift`).
Shared hooks used: see below.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-075 | Gallery: photos/videos from the collection's folders, newest first, month headers ("November 2026"), justified thumbnail rows without names, date rail (years + month ticks, click/drag jumps to a month, hover bubble), View ▾ sizes (Extra large/Large/Medium/Small), Sort ▾ Date taken ascending/descending, Collection ▾ (folder check boxes + Manage collection…), Manage collection dialog (Add…/Remove/Restore defaults), real file identity (Open, Open With, Open file location, Cut/Copy, Share, Rename via sheet, Move to Trash with undo, Quick Look, Details/Preview pane, drag out), keyboard (arrows incl. up/down by row, Shift-extend, Home/End, Return, Esc, ⌘A, Space/F2/Delete via the window's key bindings), partial coverage message for missing folders, empty states | Implemented | Unit tests (bucketing, time zones, ordering, rail years, EXIF date parsing, best date, orientation, justified layout, collection rules, bounded set). Headless runs with generated fixtures (EXIF dates 2023–2026, PNGs dated by `touch -t`, a `.mov`, a `Photos Library.photoslibrary` package and a hidden folder that must be skipped): month list, order, selection, keys, Trash (test trash), rename, Open file location, size/sort/collection toggles, missing source; snapshots light and dark |
| FE-076 | Libraries: Documents/Music/Pictures/Videos (one folder each by default, Videos → ~/Movies), Libraries page (tiles), navigation pane node (hidden by default, `Prefs.showLibraries`), breadcrumbs Libraries › Documents with chevron menus, Up → Libraries, merged listing of the top level of every folder as normal items (all views, sort, filter, rename, Trash, drag) with a "Folder" column in Details, "Manage library" (command bar, … menu, background and tree context menus) dialog with Add…/Remove/Set save location/Restore defaults, persisted; watchers on every folder | Implemented | Unit tests (defaults, add/remove, save location moves, JSON round trip, merge, symlinked duplicate folder, unavailable folder); headless runs: listing, Folder column, paste and New folder into the save location, dialog edits, Libraries page, tree node, crumbs; snapshots light and dark |
| FE-238 | Virtual collection write destination | Implemented | `LibraryLogic.resolveSaveLocation` (explicit → first usable folder flagged as fallback → explanation). New/Paste in a library write to it; with no writable folder they show "This library has no save location." with the reason and a Manage library button (headless run with a read-only folder). Gallery has no destination: New/Paste are disabled there |
| FE-239 | Projection removal ≠ deletion | Implemented | Removing a folder from a library or the collection, or unchecking it in Collection ▾, only edits the list (unit tests + headless runs confirm the files stay). Delete in Gallery/libraries is the normal Move to Trash on the real file |

## Decisions

- **DEC-GL-1** Gallery's date is EXIF/Spotlight "date taken", else the *earlier* of file creation and modification (a copied photo keeps its old modification date). Dates before 1900 or > 1 day in the future are ignored.
- **DEC-GL-2** Default collection: `~/Pictures`. Photo-library and media-library packages (`.photoslibrary`, `.migratedphotolibrary`, `.aplibrary`, `.fcpbundle`, …) are never scanned or addable; all packages and hidden files are skipped.
- **DEC-GL-3** Scanning: Spotlight (`kMDItemContentTypeTree` = public.image / public.movie; dates from `kMDItemContentCreationDate` / `kMDItemFSCreationDate`) first, then always a direct enumeration that fills what Spotlight missed (reads only the image header with ImageIO). Off the main thread, batched, cancelled when no Gallery page is in a window. Index bounded to 100,000 items (newest kept), shared app-wide; FSEvents watch on the collection rescans after changes. `ARBOR_GALLERY_NO_SPOTLIGHT=1` forces the direct scan.
- **DEC-GL-4** Nested sources (Pictures and Pictures/Trips) are scanned once; unchecking a nested folder hides its photos even if the parent is checked.
- **DEC-GL-5** Gallery is a custom page; its selection reaches commands through the new `ItemSelectionPage` hook (one additive change in `BrowserWindowController.selectedItems`).
- **DEC-GL-6** View ▾ in Gallery shows only the four icon sizes (stored separately from the folder view mode); Sort ▾ shows "Date taken" + Ascending/Descending. Implemented with command overrides that apply only while the location is Gallery (`CommandRegistry.override` / `hide(prefix:)`, order `.early`; DEC-024).
- **DEC-GL-7** Rename in Gallery uses a sheet (tiles have no names); it goes through the window's normal rename (extension warning, undo).
- **DEC-GL-8** A library's save location falls back to the next usable included folder (status-bar note) when the chosen one is missing or read-only; with none, New/Paste explain and offer Manage library. Removing the save-location folder makes the next folder the save location (Windows behavior).
- **DEC-GL-9** Library merge dedupes by **identity**: a folder reached twice (same device + inode, e.g. a symlink) is listed once. Same-named files in different folders, and hard links in different folders, are all shown.
- **DEC-GL-10** "Folder" column text is `FolderName (parent path)`, like Windows' `Documents (C:\Users\me)`. Not sortable.
- **DEC-GL-11** Libraries node sits after Network (and Trash), collapsed; each library expands to its folders. `.library("Libraries")` is the Libraries page (the name is reserved).
- **DEC-GL-12** "Add Phone Photos" (Windows Phone Link QR flow) has no Mac equivalent and is not shown (DEC-019).
- **DEC-GL-13** Gallery thumbnails use main's shared `ThumbnailService` (one byte budget for all views), requested through a per-grid `ThumbnailLoader` at the shared pixel sizes, visible tiles first.

## Shared-file changes (after merging main)

Uses main's hooks: `LocationPageSelection` (Gallery selection → commands), `DetailsColumns.register` (library
"Folder" column via a `DetailsLayout`), `NavigationPaneExtras.register(.afterNetwork)` (Libraries node, `.folder`
kind with preset children so it expands), `ItemViewUpdate.location`, and `ThumbnailService`/`ThumbnailLoader`
(Gallery thumbnails share the icon views' byte budget). Own additive edits: `Prefs.showLibraries` (Folder Options
wires the check box), a ▾ on titled submenu commands in `CommandBarView`, Up from a library → Libraries in
`Location.parent` (+ test), and the `Features.swift` slot line. Runtime wrapping (no file edits) of core commands
while in Gallery/libraries: `view.mode.*`, `view.compact`, `sort.*`, `edit.selectAll/selectNone/invertSelection`,
`file.rename`, `file.trash`, `file.newFolder`, `edit.paste`, `edit.pasteMove`; installed after all features register.

## Script steps

`gallerysources:/a|/b`, `gallerytoggle:/a`, `galleryselect:a.jpg|b.jpg`, `gallerykey:124[:shift]`, `galleryyear:2024`,
`gallerysize:smallIcons`, `galleryhover:x,y`, `managecollection`, `managelibrary:Documents`,
`dialog:add|remove|save:/path`, `dialog:restore|ok|cancel`, `showlibraries:1|0`, `librarydef:Documents=/a|/b`,
`sheettext:Name`, `collectionmenu:/path` (`sheetsnapshot:` comes from ItemActions). `log:` adds gallery, library, Details-column and sheet lines.

## Known gaps

- Library items with the same name in two folders select together after a refresh (core selection is restored by name; a click selects one row correctly).
- The search box doesn't filter Gallery; Group by/arrange-by-folder in libraries isn't built; the Folder column isn't sortable.
- The Spotlight phase was not exercised by fixtures (temporary folders aren't indexed); the direct scan was. Video aspect/dates come from Spotlight only (16:9 and file dates otherwise); video thumbnails depend on Quick Look.
- A Gallery rescan after a change is a full rescan (EXIF is only read for new files).
- Gallery scroll position isn't kept when switching tabs; Quick Look arrow keys don't move the Gallery selection.
- Libraries: no "Optimize library for", "Show in navigation pane" per library, custom libraries, `.library-ms` import, or "Don't show in navigation pane"; the nav pane doesn't auto-expand to reveal the current library.
- Sort ▾/View ▾ on the Libraries page (a tile page) show core entries that don't apply, same as the core Home page.
