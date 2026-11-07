# Icon views: Extra large / Large / Medium / Small icons, List, Tiles, Content

Code: `Sources/Arbor/Features/IconViews/` (registered by `IconViewsFeature.register()` in `Features.swift`),
logic in `Sources/ArborCore/{ItemFlowLayout,ItemSelection,ByteBudgetCache,ThumbnailPolicy}.swift`,
tests in `Tests/ArborCoreTests/IconViewLogicTests.swift`.

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-029 | List view: column-major flow, horizontal scroll, keyboard movement | implemented | unit tests (flow, moves); scripted: List snapshots light/dark, `iconkey:right,down,shift+left`, horizontal marquee autoscroll |
| FE-030 | Extra large (256), Large (96), Medium (48), Small (16) icons; responsive grid | implemented | unit tests (columns per width); snapshots of all four in light/dark; window-width reflow keeps the first visible item |
| FE-031 | Tiles (name · type · size) and Content (name · type · dimensions · date modified · size, row separators) | implemented | snapshots light/dark; Content dimensions read async from image headers |
| FE-032 | Compact view (tighter padding/gaps, same icon and text sizes) | implemented | scripted `click:view.compact` snapshot; re-read in `reloadRows()` |
| FE-033 | Thumbnail sizing without blocking or losing selection | implemented (discrete) | ⇧⌘1…8, status-bar Large icons toggle and ⌘-scroll wheel step sizes; scripted mode switches keep selection and top item (incl. through Details) |
| FE-047 | Item check boxes | implemented | Win11-style box on hovered/selected items (top-left over icons; own column in row layouts); click toggles; snapshots light/dark |
| FE-054 | Predictable arrangement | implemented | always auto-arranged in sort order; no free positioning, so drops never overlap or go off-screen |
| FE-058 | Marquee selection | implemented | starts on empty space; plain/⇧ add/⌘ toggle; autoscroll vertical and (List) horizontal; scripted with real mouse events |
| FE-060 | Arrow / Home / End / PageUp / PageDown | implemented | unit tests; scripted; ⇧ extends from the anchor; ⌃arrow moves focus only, ⌃Space toggles (see gaps) |
| FE-149 | Thumbnail providers, lazy, cancellable, cached | implemented | QLThumbnailGenerator for images, PDFs, movies; visible items + one line only; cancelled on scroll-away/folder change; logged counters |
| FE-242 | Stale completion / lifecycle | implemented | results checked against request generation and in-flight identity; key includes path + mtime + size; loader reset on folder change and deinit |
| FE-243 | Decoded-image memory budget | implemented | one app-wide LRU by decoded bytes (64 MB default, `ARBOR_THUMBNAIL_BUDGET_MB` for tests), memory-pressure trim; scripted with a 3 MB budget: stays under budget, no regeneration loop |

Also: hover highlight and rounded selection from `Theme` (accent tint when focused, grey when not); keyboard focus
outline after arrow keys; names centered under icons, wrapped to 2 lines (3 for Extra large) and shortened in the middle
(DEC-013); the selected item expands to its full name (Explorer); infotip with name/type/size/date; type-to-select (1 s
buffer, repeated letter cycles, case/diacritic-insensitive); Return/⌘Return open; double-click opens; middle-click a
folder opens a tab; right-click selects the target first and shows the registry context menu; F2 / slow second click
renames with the base name selected (multi-line box under large icons); cut and hidden items at 50 %; drag source
(copy/move/link) and drop target on folders or the background with `DropPolicy`, with autoscroll; "Always show icons,
never thumbnails" read from `Prefs.alwaysShowIcons`.

Memory: no per-item views. One document view + one canvas sized to the visible area (`subviews=1` in logs).
100,000 files: Large icons / List / Content / Tiles, End, PageDown, Select All, scroll to middle: footprint 187–249 MB
vs 182 MB for Details on the same folder.

## Decisions

- **DEC-iconviews-1** One `IconViewController` serves all seven layouts (`canDisplay` true for each), so switching keeps the
  instance, selection, focus and top item. Details stays its own controller.
- **DEC-iconviews-2** Custom drawing instead of NSCollectionView: arithmetic layout (`ItemFlowLayout`) and a canvas the size
  of the visible area. Reason: List needs column-major flow, 100k items must not allocate per-item views, and marquee,
  check boxes, expanded labels and spatial keys need exact control.
- **DEC-iconviews-3** Metrics (our approximation at 100 %): icons 256/96/48/16; cells 276/124/92 wide (compact 268/112/84);
  label 12 pt, 3 lines (XL) / 2 lines (Large, Medium); Small icons 236×26; List rows 26 (22 compact) with columns sized
  to the longest name (150–420); Tiles 268×72; Content rows 72 (60 compact). Not measured against a reference install.
- **DEC-iconviews-4** Labels under icons are shortened in the middle (extension visible) like the rest of Arbor (DEC-013),
  not with Explorer's trailing ellipsis.
- **DEC-iconviews-5** Thumbnails for images, PDFs and movies only (by extension; no disk access to decide), at Medium and
  larger, Tiles and Content. Other types and folders keep their icons (no folder "content peek", no type badge).
- **DEC-iconviews-6** Ctrl+mouse wheel maps to ⌘+scroll wheel (DEC-009 style), stepping Details → List → Small → Medium →
  Large → Extra large (Tiles/Content step from Medium's position). Discrete presets, not continuous sizes.
- **DEC-iconviews-7** Explorer's Ctrl+arrow (focus only) and Ctrl+Space (toggle) are bound to ⌃arrow / ⌃Space. macOS
  reserves these for Mission Control / input sources by default, so they only work if those system shortcuts are off;
  ⌘-click and check boxes are the reliable disjoint-selection paths.
- **DEC-iconviews-8** Clicking a selected item in a multiple selection keeps the selection until mouse-up (so the group can
  be dragged), then collapses to that item.
- **DEC-iconviews-9** Thumbnail cache budget 64 MB of decoded bitmaps, shared by all windows and tabs; when a screenful
  needs more than the budget, evicted items show icons instead of being regenerated until they scroll away and back.

## Script steps (headless, `DebugScript.registerStep`)

`iconlog:/path` (layout, scroll, top/focus, visible count, subviews, thumbnail cache, footprint; also appended to `log:`),
`iconkey:right,shift+down,ctrl+space,home,end,pageup,pagedown,return,f2,escape,type=abc`,
`iconclick:<name>[:cmd|shift|cmd+shift|double|right|name]` (real mouse events),
`iconmarquee:x1,y1,x2,y2[:cmd|shift][:holdSeconds]` (points relative to the visible area; a hold exercises autoscroll),
`iconhover:<name>`, `iconscroll:<name>`, `iconsonly:1|0` (always show icons), `iconwheel:up|down`, `iconselectrange:a-b`.

## Known gaps

- No folder "content peek" thumbnails, no file-type badge on thumbnails ("Display file icon on thumbnails"), no video
  film-strip frame.
- Icon sizes are presets; Explorer's continuous Ctrl+wheel sizes are not implemented.
- Tab/Shift+Tab during rename does not move to the next item (same as Details).
- Accessibility is minimal (list role, visible items as cells with name/selection/frame); full VoiceOver navigation is the
  accessibility area's job.
- Drag and drop was verified by code review and build only (DropPolicy shared with Details); headless runs can't drive a
  real drag session.
- Small 16 pt file icons come from `IconProvider` (system icons), which reads the icon per file on the main thread.
