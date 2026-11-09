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
| FE-058 | Marquee selection | implemented (Explorer behaviour not audited, DEC-iconviews-10) | icon layouts and Details: starts on empty space and, in Details, on row space outside the icon and name; plain/⇧ add/⌘ toggle; autoscroll vertical and (List, Details) horizontal; scripted with real mouse events; `behavior-checks.sh detailsmarquee`; unit tests `MarqueeGeometryTests`. Physical-mouse checks listed below |
| FE-060 | Arrow / Home / End / PageUp / PageDown | implemented | unit tests; scripted; ⇧ extends from the anchor; ⌃arrow moves focus only, ⌃Space toggles (see gaps) |
| FE-149 | Thumbnail providers, lazy, cancellable, cached | implemented | QLThumbnailGenerator for images, PDFs, movies; visible items + one line only; cancelled on scroll-away/folder change; logged counters |
| FE-242 | Stale completion / lifecycle | implemented | results checked against request generation and in-flight identity; key includes path + mtime + size; loader reset on folder change and deinit |
| FE-243 | Decoded-image memory budget | implemented | one app-wide LRU by decoded bytes (64 MB default, `ARBOR_THUMBNAIL_BUDGET_MB` for tests), memory-pressure trim; scripted with a 3 MB budget: stays under budget, no regeneration loop |

Also: hover highlight and rounded selection from `Theme` (accent tint while the grid has focus in the active window,
grey otherwise, the same rule as Details and the tiles: `SelectionEmphasis`, DEC-parity-8); keyboard focus
outline after arrow keys; names centered under icons, wrapped to 2 lines (3 for Extra large) and shortened in the middle
(DEC-013); the selected item expands to its full name (Explorer); infotip with name/type/size/date; type-to-select (1 s
buffer, repeated letter cycles, case/diacritic/width-insensitive; typed through the input method, so Japanese, Chinese
and Korean names can be composed, DEC-accessibility-9); Return/⌘Return open; double-click opens; middle-click a
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
- **DEC-iconviews-10** (provisional; project direction, no Windows evidence) In Details, row space outside the icon and name
  counts as whitespace for a drag, and so does the area below the rows. Dragging there draws the band; a file drag now
  starts only from the icon or name (today's any-part-of-a-row file drag from Date, Type or Size goes away). A click with no
  drag on row space still selects that row, because the row shows full-width hover and selection and single-click open treats
  the whole row as the item; if the audit disagrees it is a one-branch change in `marqueePress`. A band only selects, never
  opens or moves anything. Modifiers match the icon layouts and are latched at press: ⌘ toggles (Explorer's Ctrl, DEC-009),
  ⇧ adds, ⌘ wins if both are held. Under a right-to-left layout, or for a name with right-to-left script or bidi
  controls, the whole name field counts as the name, because the text can be drawn away from the leading edge.
  windows11-reference §8.2 has only the empty-space marquee (RECALL-h); to settle this, record a spec §2.3 observation:
  press and drag in the blank end of the Name column and in the Date column, click without dragging, note selection and band.

## How the Details band works

`Features/DetailsDepth/DetailsMarquee.swift`, contributed through `InteractionHooks.leftMouseDown`. It shares `MarqueeDrag`,
`PointerTracking`, `MarqueeBand` and `TextWidthCache` with the grid. A press on row space waits for the drag threshold;
on release the mouse-up is re-posted first in the queue and NSTableView replays a whole native click, so selection for
those clicks lands on mouse-up. `FileTableView.pressBecameMarquee` is set when a band starts and cleared by the next press,
never at the end of the drag, because the single-click open runs after tracking and must still see it. Listing updates wait
for mouse-up and only the newest is kept, with a pending folder change and its landing point carried over a later refresh (a later folder change replaces them); if rows are
rebuilt anyway, selection stops following the band and the anchor is left alone.

## Script steps (headless, `DebugScript.registerStep`)

`iconlog:/path` (layout, scroll, top/focus, visible count, subviews, thumbnail cache, footprint; also appended to `log:`),
`iconkey:right,shift+down,ctrl+space,home,end,pageup,pagedown,return,f2,escape,type=abc`,
`iconclick:<name>[:cmd|shift|cmd+shift|double|right|name]` (real mouse events),
`iconmarquee:x1,y1,x2,y2[:cmd|shift][:holdSeconds]` (points relative to the visible area; a hold exercises autoscroll),
`iconhover:<name>`, `iconscroll:<name>`, `iconsonly:1|0` (always show icons), `iconwheel:up|down`, `iconselectrange:a-b`,
`detailsmarquee:x1,y1,x2,y2[:cmd|shift][:holdSeconds][:queued]` (points relative to the rows area; `queued` goes through the
event queue, so event monitors see the press and later script steps run during a hold; the `log:` line `detailsmarquee:`
reports press target, hits, band, the overlay's band and placement while tracking, table rows and scroll offset), `detailsrowclick:x,y[:clickCount]`, `detailspress:<name>:/path`
(how presses on a row are classified, and whether the shape matches the laid-out cell).

## Known gaps

- No folder "content peek" thumbnails, no file-type badge on thumbnails ("Display file icon on thumbnails"), no video
  film-strip frame.
- Icon sizes are presets; Explorer's continuous Ctrl+wheel sizes are not implemented.
- Tab/Shift+Tab during rename does not move to the next item (same as Details).
- Accessibility is minimal (list role, visible items as cells with name/selection/frame); full VoiceOver navigation is the
  accessibility area's job.
- Drag and drop was verified by code review and build only (DropPolicy shared with Details); headless runs can't drive a
  real drag session.
- Details marquee, checks that need a physical mouse: a drag from a name starts a file drag vertically and horizontally and
  keeps a multiple selection; Control-press opens the context menu; a row-space click selects through the re-posted mouse-up
  and a row-space double-click opens; in single-click mode a row-space click opens and a band released near its start does
  not. Headless windows are never key, and NSTableView ignores clicks in a window that isn't, so the scripted group checks
  everything around these but not native selection. Run once with the window forced key, a row-space click selected its row and
  a double-click opened it.
- The band has no Escape to cancel and no wheel scrolling while dragging (nor do the icon layouts), and it doesn't start on group
  headers. Control-left-press is the system's secondary click, so Explorer's Ctrl+drag can only be ⌘+drag.
- The icon grid does not hold listing updates during a marquee, so a mid-drag reload can leave stale indexes; Details does.
- Single-click open reads `NSApp.currentEvent` from a main-queue block, which can run during mouse tracking on a real mouse, so
  it needs a physical check in both Details and the icon layouts.
- Small 16 pt file icons come from `IconProvider` (system icons). Ordinary files use their type's icon; a custom Finder icon
  is found by a background check of the files on screen and replaces it a moment later (docs/features/performance.md).
