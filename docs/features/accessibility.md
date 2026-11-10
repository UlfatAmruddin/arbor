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
| FE-066 | Keyboard presets | implemented | Windows style (default, DEC-009) and Mac style, chosen in Folder Options ▸ View ▸ Keyboard and read at key time, so Apply takes effect at once. One table, `FileListKeyPreset.rows`, run by `FileListKeys` through the command registry (DEC-accessibility-13). Text fields keep their keys in both presets, and ⌘↑ now yields to them. Unit tests `KeyboardPresetTests`; registration tests (no `KeyBinding` for a table chord); scripted `keypreset` group in `scripts/behavior-checks.sh`. Menu validation of ⌘↑ needs a key window, so it is unit-tested only |
| FE-067 | Mac Delete keys | implemented (documented) | Windows style: Delete (⌫) = Back in the file list, Forward Delete (fn⌫ / ⌦) = move to Trash, ⇧ Forward Delete = delete permanently with confirmation. Mac style: plain ⌫ and ⌦ do nothing in the file list. Both: ⌘⌫ = Move to Trash, ⌥⌘⌫ = Delete Permanently (menu). Delete on a focused tab closes it. Plain ⌫ never deletes files. ⌫ also goes Back on the Network page, which used to ignore it |
| FE-068 | IME and international keyboards | implemented | While a text field has marked (uncommitted) input-method text, every key without ⌘ goes to the input method: F6, Tab, ⌃Tab, ⌥ shortcuts and window key bindings can't fire (scripted: `compose:か` then F6 / ⌃Tab leave focus and tab unchanged). Type-to-select in Details and the icon layouts goes through an input context of the list's own (`TypeSelectInput`): the uncommitted text shows in a small underlined box at the top left of the items, every key belongs to the input method while it composes (arrows pick candidates, Escape cancels, Return accepts), and committed text selects by prefix (width-, case- and diacritic-insensitive). Scripted: `compose:か`, `key:down` (selection unchanged), `key:escape`, `composecommit:かな` (selects かな.txt), `key:b`; snapshots light/dark; unit tests `TypeSelectInputTests` |
| FE-199 | Keyboard-only operation | implemented | Every region reachable; chrome buttons press with Space/Return, drop-downs open with ↓; ⇧F10 / Menu key open the context menu for the focused items, tree node or tab; Esc returns from chrome to the items; F6 also in Go ▸ Move Focus to Next Area |
| FE-200 | VoiceOver | implemented | Navigation-pane separator rows are hidden from the tree (no more empty rows); row and tile icons are decoration (hidden); text fields and pop-up buttons in Batch rename, the archive options dialog, Choose Details, Extract All and Properties are named on their cells as well. `axaudit:` reports 0 unnamed controls and 0 empty rows on: folder, Details / Preview panes, icon layouts, Home, This Mac, Gallery, Network, Trash, search, Folder Options, Properties, copy progress, Replace or Skip, compare, operation history, Map network drive, Extract All, Choose Details, Batch rename, Create shortcut, archive options. `axdump:` walks the window's accessibility tree (what VoiceOver reads): tab group with tab buttons (selected value, Close tab action, show-menu), breadcrumb in reading order with menu-button chevrons, command bar toolbar with menu buttons, labelled status bar group, outline rows, Details table labelled with its count, icon/List/Tiles/Content items as cells with name, type, selected and focused state, press = open, show menu = context menu, settable selection; Home/This Mac/Network tiles and headers enabled; Gallery photos exposed. Announcements: location (+ item count), selection count (throttled), status bar outcomes and errors, region changes |
| FE-201 | Contrast, motion, transparency | implemented | Increase contrast: stronger borders, separators, secondary text, hover/selection, accent outline on selected items, thicker focus ring (`ARBOR_CONTRAST=1` snapshot). Reduce motion: search progress fade skipped. Reduce transparency: Arbor has no translucent surfaces |
| FE-202 | Text scaling | implemented | See FE-050; chrome stays at its fixed size so no control disappears |
| FE-203 | Focus after refresh/navigation | implemented | New windows start on the items; when navigation, a page change, tab switch or pane toggle hides or removes the focused view, focus moves to the items (or the page), while a control in a dropdown attached to the window keeps it; Esc out of the address/search box returns to the items |
| FE-204 | Localization and RTL | groundwork implemented; no translations yet | `L10n` table with English keys, generated by `scripts/extract-strings.sh`. Adding a language is one `Resources/<language>.lproj/Localizable.strings`: the build copies every `.lproj` and writes `CFBundleLocalizations`; `Bundle` picks the user's preferred language and a key the table lacks shows English. `extract-strings.sh --check` (run by `scripts/test.sh`) validates every other table: well-formed file in UTF-8 or UTF-16, no unknown keys or empty values, printf specifiers identical in kind and count (numbered forms allowed, modifiers only in the usual order, because `String(format:)` honours them in any order); missing keys are a count. A translation that got past the build still can't reach `String(format:)` with the wrong arguments: `L10n.format` falls back to the English template. Pseudo-languages `en-XA` (+40 %, accents, Thai, CJK, Devanagari, Cyrillic padding) and `ar-XB` (Hebrew letters, right to left) are generated into a scratch copy of the app and run with `-AppleLanguages`; nothing of them ships. Group `localization` in `scripts/behavior-checks.sh` launches under both, at pinned window sizes, and audits the main window (wide and narrow), Home, Folder Options (3 tabs), Properties (General, Security, Details), the conflict and name clash dialogs, the progress window (both sizes) and the recovery dialog: 0 plain, 0 clipped, snapshots read. It also checks: shortcuts in File, Edit, View and Go are the same in English and both pseudo-languages; ⌘A acts; names on disk carry no direction marks; a partial table falls back per key; sizes follow `de_DE` and `ar_SA`; a Properties path is isolated left to right. Direction: a right-to-left translation lays the app out right to left (`L10n.isRightToLeft`), Details columns, headers, dialog tab rows and the conflict command links mirror; `L10n.format` isolates text arguments, `BidiText.path` keeps a path root-first with each right-to-left component isolated, and both first drop overrides and unpaired marks so a name can't reorder what's around it; a selectable Properties label copies its text without the marks; address and path fields keep a left-to-right base. Numbers, sizes and dates come from locale-aware formatters, with technical values (dimensions, bit rate, ISO, dpi, exposure) left ungrouped as in English; unit names are table entries (`%@ KB`). Sentences that were glued from verbs or fragments are whole sentences with specifiers; a sentence with links is split by `SentenceParts` in the order the translation gives |

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

## File-list keys by preset (FE-066)

| Keys | Windows style (default) | Mac style |
|---|---|---|
| Return, keypad Enter | Open | Rename |
| ⌘↓ | — | Open |
| ⌫ | Back | — |
| fn⌫ (⌦) | Move to Trash | — |
| ⇧fn⌫ (⇧⌦) | Delete permanently (always asks) | — |

The same in both, so not in the table: F2 renames, ⌘↑ goes to the parent, ⌘⌫ moves to Trash, ⌥⌘⌫ deletes permanently, ⌘Return
opens in a new tab, ⌥←/→/↑, ⌘[ ⌘], Space, F5. Windows-style keys are from docs/research/windows11-reference.md §8.1 ([W01] and
[W03], DOC). The Mac-style keys are Finder's convention as FE-066 asks for them and were not checked against Apple's documentation:
PROP. "—" means the key goes to the focused view as usual.

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
- **DEC-accessibility-11** — Pseudo-languages are generated string tables loaded like any other language, so text not in the table shows plain and names passed through `L10n.tr` by accident never look translated. Amended by DEC-accessibility-14. Status: Provisional.
- **DEC-accessibility-12** — Decorative icons (row icons, tile icons, dialog header icons) are hidden from VoiceOver; the row, tile or heading already says the name. Status: Provisional.
- **DEC-accessibility-8** — Two-finger swipe navigation follows the system "Swipe between pages" setting and only starts at the scroll edge; it can be turned off in Go. Status: Provisional.
- **DEC-accessibility-14** — Pseudo-languages are tables written into a scratch copy of the app at test time, not a transform inside `L10n`: they prove the path a real translation takes (bundle, `CFBundleLocalizations`, fallback, the checker) and leave nothing in shipped code but the generator. `ARBOR_PSEUDO_LOC` is gone. `en-XA` and `ar-XB` are CLDR's pseudo-locale identifiers. Status: Provisional.
- **DEC-accessibility-15** — AppKit keeps a left-to-right layout when only `-AppleLanguages` selects a right-to-left language (checked on macOS 26 with a plain app bundle), so Arbor forces the layout direction whenever the language it is showing reads right to left. Status: Provisional.
- **DEC-accessibility-16** — `L10n.format` isolates text arguments in a right-to-left interface and whenever an argument holds right-to-left letters, because a format call can't know which of its arguments is a file name. Its result is display text; anything that becomes a file name goes through `L10n.plainFormat`, which adds no marks. Status: Provisional.
- **DEC-accessibility-17** — `extract-strings.sh` compiles a small tool from the ArborCore sources that do the checking, so `--check`, the unit tests and `L10n.format` share one specifier parser. It compiles only when there is a translation to check. Status: Provisional.
- **DEC-accessibility-18** — The caption column in Properties grows to the widest caption instead of having a fixed width, up to 200 pt; a dialog tab row gives up padding and then text rather than running off the window. Status: Provisional.
- **DEC-accessibility-13** — A second, opt-in keyboard preset, amending DEC-009 (which rejected separate presets): the default stays DEC-009's keys and Mac style is chosen in Folder Options. Only keys whose meaning differs by preset are in the table, and they run the registry's commands, so every override still applies. When a command can't run, the key goes on to the focused view, so group headers and the tiles of Home, This Mac and Network keep their Return. The exception is a selected item in the file list, where it beeps and stops: in Trash and ZIP listings a key the preset calls "renames" must never fall into the view's open and launch the item. Status: Provisional.

## Scripted checks

Steps added (`AccessibilityDebug.swift`, `LocalizationAudit.swift`, `AccessibilityAudit.swift`): `l10naudit:/path` (plain and
clipped text in every window; run under a pseudo-language, see TESTING.md), `axaudit:/path` (unnamed controls and empty rows in every
window), `composecommit:<text>`, `axdump:/path`, `key:<keys>` (e.g. `shift+F10`, `cmd+opt+right`, `numstar`, `menu`),
`keyrepeat:<keys>` (the auto-repeat of a held key), `focus:/path`, `mouse:3|4`, `swipe:back|forward`, `compose:<text>`, `announcements:/path`, `contextkey:/path`, `textsize:130`.
The `log:` output gains an `accessibility:` line, with the language shown and the layout direction. Environment: `ARBOR_RTL=1` (right-to-left layout with English text), `ARBOR_CONTRAST=1`,
`ARBOR_REDUCE_MOTION=1`, `ARBOR_TEXT_SIZE=100|115|130|150`. Run `scripts/extract-strings.sh --check` to verify the string tables, and `scripts/behavior-checks.sh localization` for the real app in both pseudo-languages.

## Known gaps

- No translations exist yet: only the groundwork. Right-to-left was checked with `ar-XB` under `-AppleLanguages`, which DEC-accessibility-15 forces; a Mac whose system language is Arabic or Hebrew was not available.
- `EmbeddedDate.display` shows Exif dates as `2024-03-07 14:30:00` on purpose: the field is editable and parses that same form. Time Machine and Exif timestamps stay fixed-format internally.
- About 300 sentences on less central paths are still literal English: Trash and Cloud status messages, archive and network errors, ACL summaries ("Allow"/"group"), AQS query diagnostics, batch rename and drag notes. They read as plain under `l10naudit:` when their surface is audited. Transfer, conflict, recovery, verification and delete dialogs are routed.
- Pluralization is by key (`1 item`, `%@ items`), with one plural form; `.stringsdict` is not used, so a language with several plural forms gets the closest wording its translator can write.
- Tab titles, tiles, breadcrumbs and Gallery headers drawn directly are not measured by `l10naudit:`; they were read in the snapshots.
- Menus keep showing F2 for Rename and ⌘O for Open in both presets: a menu item has one shortcut, and a Return key equivalent would break dialogs and text fields. The Folder Options radio text states each preset's keys instead.
- In Mac style, Return under Quick Look still opens (the panel forwards keys straight to the view, which opens first), and a held Return on a Gallery tile presses the rename sheet's default button with the name unchanged.
- Not verifiable headless: ⌘↑ moving the caret in the address box (menu validation needs a key window), a real keyboard's auto-repeat, and keys forwarded by the real Quick Look panel. Each needs one manual check.
- `l10naudit:` reads labels, buttons, pop-ups, headers, tooltips and accessibility labels; text drawn directly (tab titles, tiles,
  breadcrumbs, Gallery headers) is checked through its accessibility label and the snapshots.
- VoiceOver: command bar buttons expose 0/1 values whether or not they toggle.
- Increase contrast was checked with the forced flag; the system appearance path relies on AppKit's high-contrast appearance names.
- No real VoiceOver session or physical trackpad/mouse was available: verification is through the accessibility tree, synthesized
  key/mouse events and the unit-tested gesture decision.
