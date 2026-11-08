# Accessibility, keyboard and input, localization

Code: `Sources/Arbor/Features/Accessibility/`, logic in `Sources/ArborCore/Accessibility/` (tests in
`Tests/ArborCoreTests/AccessibilityTests.swift`). Registered as `AccessibilityFeature.register()` in `Features.swift`.

## Status

| FE | Requirement | Status | How verified |
|---|---|---|---|
| FE-012 | Keyboard and mouse navigation | implemented | Mouse buttons 4/5 (AppKit 3/4) go Back/Forward (`mouse:` step); ⌥←/→/↑ and Delete = Back already existed |
| FE-016 | Trackpad gestures | implemented | Two-finger swipe (with the system "Swipe between pages") only when the content under the pointer is at its horizontal edge, so List view and wide Details still scroll; three-finger swipes; Go ▸ Swipe to Go Back and Forward toggles it. Decision logic unit-tested; gesture tracking itself not testable headless (`swipe:` step drives the navigation) |
| FE-050 | Text size and row height | implemented | View ▾ › Text Size (100/115/130/150 %), View menu ⌘+ / ⌘− / ⌘0. Details rows, icon labels, Tiles/Content, group headers and the navigation pane scale; row heights grow with the font (unit test: no clipping at any level). Snapshots at 150 % in Details and Tiles |
| FE-061 | Tree keyboard expansion | implemented | Left/Right native; `*` (main or keypad) expands everything under the node breadth-first, bounded to 400 folders / depth 6 (status message when cut short); `+` / `−` expand / collapse. Scripted (`tree` run) and unit-tested plan |
| FE-062 | Focus traversal | implemented | F6 / ⇧F6 and Tab / ⇧Tab cycle tabs → address → search → command bar → navigation pane → items → side pane, skipping hidden regions; arrows move inside the tab strip and the command bar; Home's sections keep their own Tab order. Scripted with `key:` + `focus:` |
| FE-066 | Keyboard presets | partial | One preset (DEC-009 plus this feature). Text fields keep normal editing keys (Tab/F6/Esc handling defers to them). No second "Mac-only" preset |
| FE-067 | Mac Delete keys | implemented (documented) | Delete (⌫) = Back in the file list, Forward Delete (fn⌫ / ⌦) = move to Trash, ⇧ Forward Delete = delete permanently with confirmation, ⌘⌫ = Move to Trash (menu). Delete on a focused tab closes it. Plain ⌫ never deletes files |
| FE-068 | IME and international keyboards | implemented | While a text field has marked (uncommitted) input-method text, every key without ⌘ goes to the input method: F6, Tab, ⌃Tab, ⌥ shortcuts and window key bindings can't fire (scripted: `compose:か` then F6 / ⌃Tab leave focus and tab unchanged). Type-to-select in Details and the icon layouts goes through an input context of the list's own (`TypeSelectInput`): the uncommitted text shows in a small underlined box at the top left of the items, every key belongs to the input method while it composes (arrows pick candidates, Escape cancels, Return accepts), and committed text selects by prefix (width-, case- and diacritic-insensitive). Scripted: `compose:か`, `key:down` (selection unchanged), `key:escape`, `composecommit:かな` (selects かな.txt), `key:b`; snapshots light/dark; unit tests `TypeSelectInputTests` |
| FE-199 | Keyboard-only operation | implemented | Every region reachable; chrome buttons press with Space/Return, drop-downs open with ↓; ⇧F10 / Menu key open the context menu for the focused items, tree node or tab; Esc returns from chrome to the items; F6 also in Go ▸ Move Focus to Next Area |
| FE-200 | VoiceOver | implemented | Navigation-pane separator rows are hidden from the tree (no more empty rows); row and tile icons are decoration (hidden); text fields and pop-up buttons in Batch rename, the archive options dialog, Choose Details, Extract All and Properties are named on their cells as well. `axaudit:` reports 0 unnamed controls and 0 empty rows on: folder, Details / Preview panes, icon layouts, Home, This Mac, Gallery, Network, Trash, search, Folder Options, Properties, copy progress, Replace or Skip, compare, operation history, Map network drive, Extract All, Choose Details, Batch rename, Create shortcut, archive options. `axdump:` walks the window's accessibility tree (what VoiceOver reads): tab group with tab buttons (selected value, Close tab action, show-menu), breadcrumb in reading order with menu-button chevrons, command bar toolbar with menu buttons, labelled status bar group, outline rows, Details table labelled with its count, icon/List/Tiles/Content items as cells with name, type, selected and focused state, press = open, show menu = context menu, settable selection; Home/This Mac/Network tiles and headers enabled; Gallery photos exposed. Announcements: location (+ item count), selection count (throttled), status bar outcomes and errors, region changes |
| FE-201 | Contrast, motion, transparency | implemented | Increase contrast: stronger borders, separators, secondary text, hover/selection, accent outline on selected items, thicker focus ring (`ARBOR_CONTRAST=1` snapshot). Reduce motion: search progress fade skipped. Reduce transparency: Arbor has no translucent surfaces |
| FE-202 | Text scaling | implemented | See FE-050; chrome stays at its fixed size so no control disappears |
| FE-203 | Focus after refresh/navigation | implemented | New windows start on the items; when navigation, a page change, tab switch or pane toggle hides or removes the focused view, focus moves to the items (or the page); Esc out of the address/search box returns to the items |
| FE-204 | Localization and RTL | implemented (English only) | `L10n` string table with English keys, `Resources/en.lproj/Localizable.strings` generated by `scripts/extract-strings.sh` (~1,340 strings) and copied into the app; `scripts/test.sh` runs `extract-strings.sh --check`. Routed: menu bar titles and items, command titles/tooltips, page texts (Home, This Mac, Gallery, Network, Trash, Libraries), dialogs and wizards, placeholders, tooltips, column headers, status messages, and display titles kept in ArborCore (Folder Options catalog, archive formats, batch-rename choices, permissions, cloud status, drive kinds, metadata labels, time remaining). Sentences that assembled English words (file/folder, it/them, verbs, plurals) are whole sentences per case. Under `ARBOR_PSEUDO_LOC=1` only strings that are in the table are transformed, so anything not extracted stays plain. `l10naudit:` reports 0 plain strings (other than file, folder, volume, user and type names, which come from the system) and 0 clipped labels on the 21 screens listed under FE-200, light and dark. `ARBOR_RTL=1`: tab strip (contents and drag slots), breadcrumb and navigation arrows mirror |

## Keyboard reference (additions)

| Keys | Where | Does |
|---|---|---|
| F6 / ⇧F6 | anywhere | next / previous region |
| ⇥ / ⇧⇥ | anywhere except inline rename | same, stopping at each section of a page or pane |
| ← → Home End | tab strip, command bar | move between tabs (selects them) or buttons |
| Space, Return | focused button / tab | press / show the tab's items |
| ↓ | focused drop-down button | open its menu |
| ⇧F10, Menu key | items, tree, tab | context menu |
| Esc | tab strip, command bar | back to the items |
| ⌥⌘ arrows | icon layouts, Details (↑ ↓ Home End) | move the focus without selecting (Explorer's Ctrl+arrows); Details draws an accent outline on the focused row and VoiceOver hears "name, selected / not selected" |
| ⌥Space | icon layouts, Details | select / deselect the focused item (Explorer's Ctrl+Space) |
| ↑ ↓ (⇧) after a focus move | Details | continue from the focused row (⇧ extends the selection to it) |
| `*` `+` `−` | navigation pane | expand all under the node / expand / collapse |
| ⌘+ ⌘− ⌘0 | anywhere | text size bigger / smaller / default |
| mouse buttons 4, 5 | window | Back, Forward |

## Decisions

- **DEC-accessibility-1** — App-wide keys (F6, Tab, ⇧F10, Esc, IME guard) live in one local key-event monitor, not in each view, so the region order is defined once and shared views stay untouched. Status: Provisional.
- **DEC-accessibility-2** — Tab and F6 move between the same regions (one Tab stop per toolbar; arrows inside it, like Windows toolbars and WAI-ARIA composite widgets). A page or pane with several sections (Home) is visited section by section before Tab leaves it. Status: Provisional.
- **DEC-accessibility-3** — Explorer's Ctrl+arrows / Ctrl+Space are taken by macOS (Spaces, input sources), and ⌥←/→/↑ are Back/Forward/Up (DEC-009), so the icon layouts use ⌥⌘ arrows (focus only) and ⌥Space (toggle). The Control versions still work when macOS passes them through. Status: Provisional.
- **DEC-accessibility-4** — Text size scales the file list, item labels and navigation pane only (Windows' "Make text bigger" scales everything); the chrome keeps its measured Explorer metrics so nothing clips. Levels 100/115/130/150 %. Status: Provisional.
- **DEC-accessibility-5** — String keys are the English text (NSLocalizedString convention); missing translations fall back to English. Plain `.strings` instead of a String Catalog, because `xcstringstool` is not part of the Command Line Tools. Status: Provisional.
- **DEC-accessibility-6** — Flat chrome buttons and tabs accept keyboard focus only when keyboard navigation moves it there, so clicking a command bar button never takes focus away from the file list. Keyboard focus is drawn as Explorer's two-ring rectangle. Status: Provisional.
- **DEC-accessibility-7** — `*` in the tree expands at most 400 folders / 6 levels: Explorer expands the full subtree, but an unbounded recursive scan breaks spec §15.3. Status: Provisional.
- **DEC-accessibility-9** — Type-to-select uses an input context owned by the list, not NSTableView's built-in type select (which reads raw key characters). The composition is shown in a small box at the top left of the items, the way Explorer shows the IME window over the list. Status: Provisional.
- **DEC-accessibility-10** — Details gets DEC-accessibility-3's keys too: ⌥⌘↑/↓/Home/End move a focus row apart from the selection, ⌥Space toggles it; plain arrows then continue from the focus. ⌃ versions work when macOS passes them through. Status: Provisional.
- **DEC-accessibility-11** — Pseudo-localization transforms only strings that are in the string table, so missing extraction is visible and names passed through `L10n.tr` by accident never look translated. Status: Provisional.
- **DEC-accessibility-12** — Decorative icons (row icons, tile icons, dialog header icons) are hidden from VoiceOver; the row, tile or heading already says the name. Status: Provisional.
- **DEC-accessibility-8** — Two-finger swipe navigation follows the system "Swipe between pages" setting and only starts at the scroll edge; it can be turned off in Go. Status: Provisional.

## Scripted checks

Steps added (`AccessibilityDebug.swift`, `LocalizationAudit.swift`, `AccessibilityAudit.swift`): `l10naudit:/path` (plain and
clipped text in every window; run with `ARBOR_PSEUDO_LOC=1`), `axaudit:/path` (unnamed controls and empty rows in every
window), `composecommit:<text>`, `axdump:/path`, `key:<keys>` (e.g. `shift+F10`, `cmd+opt+right`, `numstar`, `menu`),
`focus:/path`, `mouse:3|4`, `swipe:back|forward`, `compose:<text>`, `announcements:/path`, `contextkey:/path`, `textsize:130`.
The `log:` output gains an `accessibility:` line. Environment: `ARBOR_PSEUDO_LOC=1`, `ARBOR_RTL=1`, `ARBOR_CONTRAST=1`,
`ARBOR_REDUCE_MOTION=1`, `ARBOR_TEXT_SIZE=100|115|130|150`. Run `scripts/extract-strings.sh --check` to verify the string table.

## Known gaps

- No translations exist yet (English base table only).
- Not routed on purpose, to stay clear of the transfer engine and undo code: the status bar's transfer line ("Copying 3 items ·
  37% complete"), undo action names and the end-of-transfer report built in `OperationCenter`, transfer failure reasons
  (`TransferFailure`) and the interrupted-job recovery text (`JobRecovery`). A few formatted strings still embed English
  words from the model (ACL entry summaries "Allow"/"group", folder-view source names).
- `l10naudit:` reads labels, buttons, pop-ups, headers, tooltips and accessibility labels; text drawn directly (tab titles, tiles,
  breadcrumbs, Gallery headers) is checked through its accessibility label and the snapshots.
- VoiceOver: command bar buttons expose 0/1 values whether or not they toggle.
- Increase contrast was checked with the forced flag; the system appearance path relies on AppKit's high-contrast appearance names.
- No real VoiceOver session or physical trackpad/mouse was available: verification is through the accessibility tree, synthesized
  key/mouse events and the unit-tested gesture decision.
