# Feature status: v0.2 foundation

Tracks requirement IDs from [SPEC.md](SPEC.md) (FE-234: no row disappears).

**Status:** `basic` = implemented in a first form · `partial` = some of the requirement · `not started`.
**Verified by:** `unit` = automated test in `Tests/ArborCoreTests` · `scripted` = run against the live app with the `DebugScript` harness on disposable folders · `—` = built but not yet verified beyond compiling.

No row claims parity with Windows: there is no pinned Windows reference yet (FE-232, FE-247).

## Implemented in v0.1

| ID | Capability | Status | Verified by | Notes |
|---|---|---|---|---|
| FE-001 | Back / Forward | basic | unit, scripted | Restores selection and scroll anchor |
| FE-002 | Up | basic | unit, scripted | Selects the folder just left |
| FE-003 | Breadcrumb | basic | scripted | Explorer-style segments with › chevrons; leading segments collapse into « with a menu |
| FE-004 | Breadcrumb sibling menus | basic | scripted | Each › lists that folder's subfolders (one level, read on click); the leading › lists top-level places. Contents not compared with Explorer |
| FE-005 | Editable address bar | basic | unit, scripted | ⌘L or click empty space; Escape cancels |
| FE-007 | Folder tree | basic | scripted | Explorer order: Home, Gallery, pinned folders (pin glyph), This Mac (drives), Network. Chevron expands, label navigates, lazy |
| FE-009 | Navigation pane visibility | basic | scripted | View ▸ Show ▸ Navigation pane (⌃⌘S) |
| FE-011 | Refresh | basic | — | ⌘R / F5; keeps selection |
| FE-012 | Keyboard/mouse navigation | partial | — | ⌥ arrows, Delete = Back; mouse back/forward buttons not yet |
| FE-013 | Mac path resolution | basic | unit | ~, relative, quoted, file:// |
| FE-014 | Network path entry | partial | unit | smb:// and UNC translation handed to the system mount; no browsing |
| FE-015 | Unavailable locations | partial | unit, scripted | Distinct errors; history kept on failure |
| FE-017 | Create/close/switch tabs | basic | scripted | Custom tab strip in the title-bar row (DEC-021); ⌘T, ⌘W, ⌘1–⌘9, ⌃Tab/⌃⇧Tab, ⇧⌘[ / ⇧⌘]; shrinks then scrolls. Mouse paths not exercised (headless) |
| FE-018 | Reorder tabs | basic | scripted | Drag in the strip (mouse path not exercised); `movetab` script step |
| FE-019 | Tab context menu | basic | scripted | New tab, Duplicate tab, Close tab, Close other tabs, Close tabs to the right, Move tab to new window |
| FE-020 | Detach/merge tabs | partial | scripted | Move tab to new window (menu, or drag down out of the strip). Merging windows not built |
| FE-021 | Multiple windows | basic | scripted | New windows open Home |
| FE-022 | Open folder in new tab | basic | scripted | Open in new tab / new window (item and tree menus), ⌘Return, middle-click |
| FE-023 | Middle-click behavior | partial | — | Closes a tab; opens a folder, tree node or Home tile in a new tab. Address-bar middle-click not built |
| FE-025 | Mac window lifecycle | partial | — | Quit during a transfer asks first |
| FE-028 | Details view | basic | scripted | Explorer styling: 28pt rows, hover, rounded accent-tinted selection, flat header. Headers use the stock cell (see TESTING.md) |
| FE-029–FE-031 | Other view modes | not started | scripted (fallback) | All eight modes are listed (⇧⌘1–8); unregistered ones are disabled and show Details (ViewModeRegistry) |
| FE-032 | Compact view | basic | scripted | Row height 28 → 24 |
| FE-034 | Status bar | basic | unit, scripted | "12 items  \|  1 item selected  4.1 KB  \|", transfer progress, Details/Large icons toggles at the right |
| FE-035 | Column chooser | partial | — | Show/hide, reorder, resize, fit; no extra metadata columns |
| FE-037 | Sorting | basic | unit, scripted | Natural order; deterministic tie-breaks |
| FE-044 | Hidden items and extensions toggles | basic | unit | |
| FE-048 | Light and dark appearance | basic | scripted | Theme.swift approximates Explorer's light/dark palette; snapshots checked in both |
| FE-047 | Item checkboxes | basic | scripted | View ▸ Show ▸ Item check boxes; a box per row toggles selection |
| FE-049 / FE-055 | Name-first width, long names | partial | scripted | Middle truncation, tooltip |
| FE-051 | Readable numeric metadata | partial | — | Right-aligned; folders blank, not "0" |
| FE-053 | Folders first | basic | unit | Toggleable |
| FE-056 | Range/disjoint selection | basic | — | Native table behavior; anchor rules not audited |
| FE-057 | Select all / none / invert | basic | scripted | "…" menu and Edit menu |
| FE-059 | Type-to-select | basic | — | Native |
| FE-063 | Rename editing | basic | unit, scripted | Base name selected; Escape cancels; failed rename keeps typed text |
| FE-069 | Home page | partial | scripted | Placeholder: Quick access tiles and a "Recent files appear here" note. New tabs/windows open Home (DEC-020) |
| FE-070 | Quick access pins | basic | scripted | Pin/unpin from item, tree and "…" menus; never moves files |
| FE-074 | This PC → This Mac | partial | scripted | Location lists volumes as items (type, free space, capacity). No tiles or capacity bars. Up from a volume root goes here |
| FE-075–FE-078 | Gallery, Libraries, Trash, Network pages | not started | scripted | Locations exist and show an honest "isn't available yet" page |
| FE-080 | Mac known folders | basic | — | |
| FE-083 | Open / Open With | basic | — | |
| FE-084 | Copy/cut/paste | basic | unit, scripted | Cut is an intent tied to the pasteboard (§8.2) |
| FE-085 | Copy path | basic | unit, scripted | Each path in double quotes, one per line, like Explorer |
| FE-086 | Rename rules | basic | unit | Mac rules; case-only rename |
| FE-087 | New folder | basic | unit, scripted | Inline rename |
| FE-090 | Trash / permanent delete | basic | scripted | Never silently becomes permanent |
| FE-091 | Undo/redo | partial | scripted | Rename, Trash, move, new folder; not copy |
| FE-093 | Context menus | partial | scripted | File, folder, background (New ▸, View ▸, Sort by ▸), tree, tab; built from the command registry |
| FE-094 | Command bar | basic | scripted | New ▾, Cut, Copy, Paste, Rename, Share, Delete, Sort ▾, View ▾, contextual slot, … (See more), Details toggle; from the command registry |
| FE-096 | Share | basic | — | macOS share sheet |
| FE-098 | Open terminal here | basic | — | No shell strings |
| FE-101 | Clipboard interop with Finder | partial | — | File URLs written/read; move-intent only within Arbor |
| FE-104 / FE-105 | Drag defaults and modifiers | basic | — | Same volume = move; ⌥ copy, ⌘ move |
| FE-107 | Tree drop targets | basic | — | |
| FE-109 | Drop onto background | basic | — | Uses the current folder |
| FE-110 | Cross-app drag | partial | — | File URLs; no file promises yet |
| FE-112 | Invalid drop prevention | basic | unit | Self/descendant rejected |
| FE-114 | Progress | partial | scripted | Item counts, no bytes or ETA (deliberate) |
| FE-115 | Cancel | partial | unit | Between items; no pause/resume |
| FE-116 | Concurrent operations | basic | — | App-level jobs; closing a tab doesn't cancel |
| FE-117 | Conflict choices | basic | unit, scripted | Keep Both default; Replace → Trash |
| FE-118 | Folder merge | basic | unit | |
| FE-119 | Apply to remaining | basic | unit | Per conflict kind, per job |
| FE-120 / FE-121 | Failure reporting | partial | unit | Per-item reasons; disk-full not fault-injected |
| FE-122 | Cross-volume move safety | basic | unit (logic) | Source removed only after copy success; not tested across real volumes |
| FE-126 | Operation results | partial | — | Problem summary dialog; no persistent history |
| FE-129 | Undo protection | basic | scripted | Refuses to overwrite |
| FE-131 | Current-folder search | partial | unit, scripted | Filter only, scope stated |
| FE-147 | Preview pane | basic | scripted | Released when hidden; iCloud guard; exclusive with the Details pane (⌥⌘P) |
| FE-148 | Details pane | partial | scripted | Placeholder: icon, name, type, size, dates, location (⇧⌥⌘P). No editable properties |
| FE-159 | Quick Look | basic | — | Space |
| FE-160 | Packages | basic | — | Open normally; Show Package Contents |
| FE-162 | Cloud preview hydration | partial | — | iCloud only |
| FE-175 | Eject | basic | — | |
| FE-199 | Keyboard-only | partial | — | Not audited end to end |
| FE-200 | VoiceOver | partial | — | Native controls, labels; not audited |
| FE-203 | Focus after refresh | partial | scripted | Selection and scroll preserved |
| FE-205 | Preference persistence | partial | — | Global prefs, per-tab sort |
| FE-218 | Show in Finder | basic | — | |
| FE-219 | CLI entry | basic | — | `Arbor <path>` |
| FE-221 | Open-source governance | partial | — | License, README, CONTRIBUTING, decisions |
| FE-222 | Privacy by default | basic | — | No telemetry |
| FE-223–FE-226 | Unicode, case, races | partial | unit | Case-only rename; no NFC/NFD corpus yet |
| FE-229 | Stable live updates | partial | scripted | Folder watcher; rename never interrupted |
| FE-250 | Revalidate after delayed decision | basic | unit | Replace re-checks the destination |
| FE-255 | Actual committed destination | basic | unit | Keep-both names reported |

## Not started

Everything else in FE-001–FE-258, notably: FE-006, FE-008, FE-010, FE-016, FE-024, FE-026, FE-027, FE-029–FE-031 (fallback only), FE-033, FE-036, FE-038–FE-043, FE-045, FE-046, FE-050, FE-052, FE-054, FE-058, FE-060–FE-062, FE-064–FE-068, FE-071–FE-073, FE-075–FE-079, FE-081, FE-082, FE-088, FE-089, FE-092, FE-095, FE-097, FE-099, FE-100, FE-102, FE-103, FE-106, FE-108, FE-111, FE-113, FE-123–FE-125, FE-127, FE-128, FE-130, FE-132–FE-146, FE-149–FE-158, FE-161, FE-163–FE-174, FE-176–FE-198, FE-201, FE-202, FE-204, FE-206–FE-217, FE-220, FE-227, FE-228, FE-230–FE-249, FE-251–FE-254, FE-256–FE-258.

## Not yet measured

Memory and responsiveness budgets (§15.4) have not been benchmarked. The design is bounded (lazy tree, no recursive scans, shared bounded icon cache, preview released when hidden), but no numbers are claimed.
