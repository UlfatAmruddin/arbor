# Feature status

The single status list for every requirement in [SPEC.md](SPEC.md): FE-001 to FE-258, one row each, none left out
(FE-234). Statuses were taken from the area documents in [docs/features/](features/) and checked against the code;
where a claim couldn't be confirmed it was lowered. Scenario results (T01–T30) are in [ACCEPTANCE.md](ACCEPTANCE.md).

**Status:** *implemented* = works as the requirement asks on macOS · *partial* = part of it works (the note says
what is missing) · *macOS boundary* = macOS has no counterpart, so Arbor offers the closest real equivalent or a
documented handoff instead of a fake button (DEC-019) · *not done* = not built yet.

**How verified:** *unit* = automated test in `Tests/ArborCoreTests` (`scripts/test.sh`) · *headless* = the real app
driven by `DebugScript` on disposable folders (TESTING.md) · *acceptance Txx* = a scenario in `scripts/acceptance.sh`
· *core-checks* / *behavior-checks* = `scripts/core-checks.sh` / `scripts/behavior-checks.sh` · *snapshots* = PNGs of the
window read by eye, light and dark · *code review* = read in the source, not exercised by a test.

## Summary

| Status | Requirements |
|---|---|
| implemented | 219 |
| partial | 15 |
| macOS boundary | 13 |
| not done | 11 |
| **total** | **258** |

| Area | Implemented | Partial | macOS boundary | Not done |
|---|---|---|---|---|
| Navigation and location | 16 | 0 | 0 | 0 |
| Tabs, windows and session | 11 | 0 | 0 | 0 |
| Views, density and readability | 28 | 0 | 0 | 0 |
| Selection, focus and input | 13 | 0 | 0 | 0 |
| Home, special locations and collections | 12 | 0 | 2 | 0 |
| File actions, clipboard and menus | 16 | 3 | 2 | 0 |
| Drag and drop | 10 | 0 | 0 | 0 |
| Operations, progress, conflicts and recovery | 17 | 0 | 0 | 0 |
| Search and filtering | 14 | 1 | 1 | 0 |
| Preview, metadata and properties | 14 | 2 | 0 | 0 |
| Archives and disk images | 8 | 1 | 0 | 2 |
| Drives, devices, network and sharing | 9 | 0 | 4 | 2 |
| Cloud and account integrations | 4 | 3 | 1 | 2 |
| Accessibility, localization and preferences | 9 | 1 | 0 | 0 |
| System integration and expansion boundary | 7 | 2 | 3 | 2 |
| Reliability and acceptance coverage | 10 | 0 | 0 | 2 |
| Additional research requirements (§21) | 21 | 2 | 0 | 1 |

## Known limitations

- **No Windows reference audit.** No Windows 11 machine was available. Parity is based on Microsoft's documentation
  and recalled behavior, recorded in [research/windows11-reference.md](research/windows11-reference.md) with DOC / RECALL
  labels. Exact menus, wording, spacing and colors may differ from a current Windows 11 build (FE-232, FE-247 not done).
- **Features with no macOS equivalent** are boundaries, not imitations: drive letters, BitLocker, WSL and Dev Drive,
  Control Panel and other shell folders, Pin to Start/taskbar, Microsoft account recommendations, Windows' legacy
  context menu, Offline Files, replacing other apps' Open/Save dialogs, and pinning cloud files (no public API).
- **Not exercised against real services:** SMB/AFP servers and Bonjour discovery (tested with simulated servers),
  OneDrive/Dropbox/Google Drive File Provider domains (tested with a simulated provider), Time Machine disks, RAR files,
  a live VoiceOver session, a physical trackpad and pointer-driven drags (headless runs can't move the mouse).
- **English only.** Every visible string goes through the string table, but no translations exist yet.
- **Unsigned builds** until a Developer ID is available (FE-220); see the README for the first-launch steps.

## Navigation and location

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-001 | Back and forward | implemented | unit; acceptance T02 | [qa-core](features/qa-core.md) | Per-tab history; restores selection (by item) and scroll position |
| FE-002 | Up to parent | implemented | acceptance T02 | [qa-core](features/qa-core.md) | Selects the folder just left; Up from a disk goes to This Mac |
| FE-003 | Breadcrumb path | implemented | headless `crumbs:`; snapshots | [visual-parity](features/visual-parity.md) | Collapses leading segments into «; recent-locations ▾ at the right end |
| FE-004 | Breadcrumb sibling menus | implemented | headless `crumbs:` | [visual-parity](features/visual-parity.md) | Each › lists that folder's subfolders; not compared item by item with Explorer |
| FE-005 | Editable address bar | implemented | acceptance T03 | [qa-core](features/qa-core.md) | ⌘L / ⌥D / click; Escape cancels |
| FE-006 | Path completion and history | implemented | unit; behavior-checks `address`, `addresshistory` | [address-entry](features/address-entry.md) | History survives relaunch and Clear history erases it; not compared with Windows |
| FE-007 | Folder tree | implemented | acceptance T01 | [qa-core](features/qa-core.md) | Expanding never navigates; lazy, one level per expansion |
| FE-008 | Expand tree to current folder | implemented | headless Folder Options run | [folder-options](features/folder-options.md) | "Expand to open folder" (off by default, as in Windows) |
| FE-009 | Navigation pane visibility | implemented | headless `log` (frames) | [visual-parity](features/visual-parity.md) | View ▸ Show ▸ Navigation pane |
| FE-010 | Show all folders and libraries | implemented | headless Folder Options run | [folder-options](features/folder-options.md) | Show all folders, Show libraries |
| FE-011 | Refresh | implemented | acceptance T08; headless `log` | [visual-parity](features/visual-parity.md) | Separate button left of the address bar (DEC-022); keeps selection |
| FE-012 | Keyboard and mouse navigation | implemented | headless `mouse:`, `key:` | [accessibility](features/accessibility.md) | ⌥←/→/↑, ⌘[ ⌘] ⌘↑, Delete = Back, mouse buttons 4/5 |
| FE-013 | Mac path resolution | implemented | unit (PathResolver); acceptance T03 | [qa-core](features/qa-core.md) | ~, relative, quoted, file://, on-disk spelling |
| FE-014 | Network path entry | implemented | unit; acceptance T03, T24 (simulated servers) | [network](features/network.md) | smb:// and \\server\share; no real SMB server tested |
| FE-015 | Unavailable locations | implemented | acceptance T03, T26; qa-places failure states | [qa-places](features/qa-places.md) | Permission, missing, disconnected, loading shown distinctly |
| FE-016 | Navigation gestures | implemented | unit (gesture decision); `swipe:` step | [accessibility](features/accessibility.md) | Physical trackpad not exercised |

## Tabs, windows and session

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-017 | Create, close and switch tabs | implemented | headless `log` (`tab strip:`); snapshots | [visual-parity](features/visual-parity.md) | Overflow arrows past 100 pt tabs |
| FE-018 | Reorder tabs | implemented | headless `movetab:`, `dragtab:` | [visual-parity](features/visual-parity.md) | Pointer dragging itself not scriptable |
| FE-019 | Tab context menu | implemented | headless `menu:tab` | [visual-parity](features/visual-parity.md) |  |
| FE-020 | Detach and merge tabs | implemented | headless `tearoff:`, `mergetab:` | [visual-parity](features/visual-parity.md) | Pointer drag path manual only |
| FE-021 | Multiple windows | implemented | headless | [visual-parity](features/visual-parity.md) | Each window has its own tabs and history |
| FE-022 | Open folder in new tab or window | implemented | headless menus | [qa-core](features/qa-core.md) | Menus, ⌘Return, middle-click |
| FE-023 | Middle-click behavior | implemented | headless `crumbmiddle` | [item-actions](features/item-actions.md) | Not tested with a physical third button |
| FE-024 | Session restoration | implemented | two-launch headless run | [folder-options](features/folder-options.md) | Folder Options › Restore previous folder windows |
| FE-025 | Mac window lifecycle | implemented | code review; acceptance T30 | [file-operations](features/file-operations.md) | App stays open after the last window (DEC-015); Dock reopen; quit asks during transfers |
| FE-026 | Monitor placement | implemented | unit (geometry); `screenschanged` | [folder-options](features/folder-options.md) |  |
| FE-027 | Saved workspaces | implemented | unit; headless `menu:` | [workspaces](features/workspaces.md) | An addition to Explorer, labelled as one |

## Views, density and readability

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-028 | Details view | implemented | snapshots light/dark; acceptance T06 | [visual-parity](features/visual-parity.md) |  |
| FE-029 | List view | implemented | unit; snapshots | [icon-views](features/icon-views.md) |  |
| FE-030 | Small to extra-large icons | implemented | unit; snapshots | [icon-views](features/icon-views.md) | Four presets (16/48/96/256) |
| FE-031 | Tiles and Content views | implemented | snapshots | [icon-views](features/icon-views.md) |  |
| FE-032 | Compact view | implemented | headless snapshot | [icon-views](features/icon-views.md) |  |
| FE-033 | Thumbnail sizing | implemented | headless mode switches keep selection | [icon-views](features/icon-views.md) | Discrete sizes; no continuous Ctrl+wheel sizing |
| FE-034 | Status bar | implemented | headless `log` (`status:`) | [visual-parity](features/visual-parity.md) |  |
| FE-035 | Column chooser | implemented | headless `choosedetails`, `headermenu` | [grouping](features/grouping.md) |  |
| FE-036 | Metadata-specific columns | implemented | fixtures (images, audio, tags) | [grouping](features/grouping.md) | Values depend on Spotlight/file parsers; video columns not fixture-tested |
| FE-037 | Ascending and descending sorting | implemented | unit; acceptance T06 | [qa-core](features/qa-core.md) | Natural order, folders first, stable ties |
| FE-038 | Grouping | implemented | unit; acceptance T06; snapshots | [grouping](features/grouping.md) |  |
| FE-039 | Column header filters | implemented | unit; headless `filter:` | [grouping](features/grouping.md) |  |
| FE-040 | Folder view templates | implemented | unit; headless | [folder-options](features/folder-options.md) | General, Documents, Pictures, Music, Videos, Downloads |
| FE-041 | Per-folder settings | implemented | unit; acceptance T07 | [folder-options](features/folder-options.md) | Keyed by volume UUID + file number |
| FE-042 | Folder Options | implemented | unit; headless snapshots of all pages | [folder-options](features/folder-options.md) |  |
| FE-043 | Advanced Folder Options audit | implemented | headless effect logs | [folder-options](features/folder-options.md) | Every item from the reference list; Windows-only ones disabled with a reason; not audited on a pinned Windows build |
| FE-044 | Hidden items and extensions | implemented | unit; acceptance T10 | [folder-options](features/folder-options.md) |  |
| FE-045 | Protected system items | implemented | unit; headless | [folder-options](features/folder-options.md) | Mac definition (.DS_Store, ._*, …) with a warning |
| FE-046 | Single- or double-click activation | implemented | headless posted clicks | [folder-options](features/folder-options.md) |  |
| FE-047 | Item check boxes | implemented | snapshots | [icon-views](features/icon-views.md) |  |
| FE-048 | Light and dark appearance | implemented | snapshots of every screen, light and dark | [visual-parity](features/visual-parity.md) |  |
| FE-049 | Name-first width policy | implemented | acceptance T05 | [visual-parity](features/visual-parity.md) | Name column takes the spare width; Size column to fit |
| FE-050 | Text size and row height | implemented | unit; snapshots at 150 % | [accessibility](features/accessibility.md) |  |
| FE-051 | Readable numeric metadata | implemented | unit; snapshots | [visual-parity](features/visual-parity.md) | Right-aligned whole KB; Size on disk column; unknown vs zero |
| FE-052 | Stable global view defaults | implemented | unit; acceptance T07 | [folder-options](features/folder-options.md) | App default → folder type → this folder, source shown in View ▾ |
| FE-053 | Folders first with every sort | implemented | unit; acceptance T06 | [qa-core](features/qa-core.md) |  |
| FE-054 | Predictable icon arrangement | implemented | unit (flow layout) | [icon-views](features/icon-views.md) | Always auto-arranged |
| FE-055 | Long-name alternatives | implemented | unit; behavior-checks `namewrap` | [visual-parity](features/visual-parity.md) | Optional wrapping in Details, up to three lines |

## Selection, focus and input

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-056 | Range and disjoint selection | implemented | acceptance T08 | [qa-core](features/qa-core.md) | Anchor kept by item across folder updates; a file that appears inside a selected range is not added by the next ⇧-arrow |
| FE-057 | Select all, none and invert | implemented | headless `menu:seemore`; core-checks | [item-actions](features/item-actions.md) |  |
| FE-058 | Marquee selection | implemented | unit; behavior-checks `detailsmarquee` | [icon-views](features/icon-views.md) |  |
| FE-059 | Type-to-select | implemented | headless `key:`, `compose:`; acceptance T27 | [accessibility](features/accessibility.md) | Through the input method |
| FE-060 | Arrow, Home, End, Page keys | implemented | unit; headless `iconkey:` | [icon-views](features/icon-views.md) |  |
| FE-061 | Tree keyboard expansion | implemented | unit; acceptance T01 | [accessibility](features/accessibility.md) | `*` bounded to 400 folders / 6 levels |
| FE-062 | Focus traversal | implemented | headless `key:` + `focus:`; acceptance T01 | [accessibility](features/accessibility.md) |  |
| FE-063 | Rename editing | implemented | acceptance T10 | [qa-core](features/qa-core.md) | F2 selects the base name; Escape cancels |
| FE-064 | Sequential rename | implemented | headless `editorcmd:`, `renametab` | [item-actions](features/item-actions.md) | Details and icon layouts |
| FE-065 | Drag initiation | implemented | code review | [icon-views](features/icon-views.md) | Pointer drags can't be scripted headless |
| FE-066 | Keyboard presets | implemented | unit; headless `key:` | [accessibility](features/accessibility.md) | Windows style by default, Mac style in Folder Options |
| FE-067 | Mac delete-key distinction | implemented | headless `key:` | [accessibility](features/accessibility.md) | ⌫ = Back, fn⌫ = Trash, ⇧fn⌫ = delete permanently (asks) |
| FE-068 | IME and international keyboards | implemented | unit; headless `compose:` | [accessibility](features/accessibility.md) |  |

## Home, special locations and collections

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-069 | Home page | implemented | headless; snapshots | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-070 | Quick access folders | implemented | unit; headless menus | [home-and-this-mac](features/home-and-this-mac.md) | Order can't be changed by dragging tiles |
| FE-071 | Favorite files | implemented | unit; headless | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-072 | Recent files and frequent folders | implemented | unit; acceptance T22 | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-073 | Recommended and shared content | macOS boundary | — | [home-and-this-mac](features/home-and-this-mac.md) | Needs Microsoft account insights; no Mac provider |
| FE-074 | This PC → This Mac | implemented | headless with a mounted disk image | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-075 | Gallery | implemented | unit; headless with generated photos | [gallery-libraries](features/gallery-libraries.md) |  |
| FE-076 | Libraries | implemented | unit; acceptance T21, T22 | [gallery-libraries](features/gallery-libraries.md) | No `.library-ms` import: its Windows paths don't resolve on a Mac (DEC-GL-16) |
| FE-077 | Recycle Bin → Trash | implemented | unit; headless | [trash](features/trash.md) | Original location known only for items Arbor trashed |
| FE-078 | Network root | implemented | headless (simulated servers) | [network](features/network.md) | Bonjour discovery not run against real servers |
| FE-079 | Special shell locations | macOS boundary | unit (address keywords) | [qa-core](features/qa-core.md) | Home, This Mac/This PC, Gallery, Network, Trash/Recycle Bin accepted; Control Panel, printers and device nodes have no Mac counterpart |
| FE-080 | Mac known folders | implemented | snapshots | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-081 | Finder tags and smart collections | implemented | unit; headless | [finder-tags](features/finder-tags.md) |  |
| FE-082 | Control Home clutter | implemented | headless toggles | [home-and-this-mac](features/home-and-this-mac.md) | Sections collapse; Recent/frequent can be turned off; "Open Arbor to" in Folder Options |

## File actions, clipboard and menus

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-083 | Open and Open With | implemented | behavior-checks `headless`, `recent` | [consistency](features/consistency.md) |  |
| FE-084 | Copy, cut and paste | implemented | core-checks; acceptance T11 | [qa-core](features/qa-core.md) |  |
| FE-085 | Copy path | implemented | unit; headless | [qa-core](features/qa-core.md) | Quoted, one per line |
| FE-086 | Rename rules | implemented | unit; acceptance T10 | [qa-core](features/qa-core.md) | Case-only rename, conflicts refused |
| FE-087 | New folder | implemented | unit; behavior-checks `undo` | [qa-core](features/qa-core.md) |  |
| FE-088 | New file templates | implemented | unit; headless | [item-actions](features/item-actions.md) | No Office/iWork items (can't be created validly) |
| FE-089 | Multi-file rename | implemented | unit; headless | [item-actions](features/item-actions.md) |  |
| FE-090 | Delete and permanent delete | implemented | acceptance T23 | [file-operations](features/file-operations.md) | Trash never silently becomes permanent |
| FE-091 | Undo and redo | implemented | behavior-checks `undo`, `undomove`; acceptance T17 | [qa-core](features/qa-core.md) | Shared across tabs; refuses rather than overwrite |
| FE-092 | Create shortcut and paste shortcut | implemented | headless | [item-actions](features/item-actions.md) | Mac aliases; symbolic links separate |
| FE-093 | Context menus per surface | implemented | headless `menu:` dumps | [consistency](features/consistency.md) |  |
| FE-094 | Command bar | implemented | snapshots; headless `log` | [visual-parity](features/visual-parity.md) |  |
| FE-095 | Modern and legacy menu variants | macOS boundary | — | [visual-parity](features/visual-parity.md) | AppKit has one menu style; no "Show more options" layer, icon row items are text |
| FE-096 | Send to and Share | implemented | headless with test folders | [item-actions](features/item-actions.md) | Bluetooth and Fax omitted |
| FE-097 | Print, rotate, set wallpaper | partial | unit; headless | [item-actions](features/item-actions.md) | Rotate and wallpaper built; Print omitted (no honest Mac API) |
| FE-098 | Open terminal here | implemented | behavior-checks `headless` | [qa-core](features/qa-core.md) | No shell strings |
| FE-099 | Properties | implemented | headless; snapshots | [properties](features/properties.md) |  |
| FE-100 | Pin to Start or taskbar | macOS boundary | — | [item-actions](features/item-actions.md) | No Mac counterpart without editing Dock preferences |
| FE-101 | Clipboard interoperability with Mac apps | partial | code review | [qa-core](features/qa-core.md) | File URLs to and from Finder; move intent only for Arbor's own cut |
| FE-102 | File promises and dropped attachments | partial | headless `promise:`; acceptance T12 | [archives](features/archives.md) | Promises received and sent (archive members); no per-promise progress or cancel |
| FE-103 | Advanced batch rename | implemented | unit; headless | [item-actions](features/item-actions.md) |  |

## Drag and drop

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-104 | Same- vs cross-volume defaults | implemented | unit (drop policy); code review | [item-actions](features/item-actions.md) | Pointer drags not scriptable |
| FE-105 | Modifier overrides | implemented | code review | [item-actions](features/item-actions.md) | ⌥ copy, ⌘ move, ⌥⌘ shortcut |
| FE-106 | Right-button drag menu | implemented | headless `simdrop:right`, `dropmenu:` | [item-actions](features/item-actions.md) | Starting a right-drag with a real mouse not tested |
| FE-107 | Tree and breadcrumb drop targets | implemented | behavior-checks `breadcrumb` | [item-actions](features/item-actions.md) |  |
| FE-108 | Hover expansion and autoscroll | implemented | unit; headless `springrow`/`springtree`/`springtab` | [item-actions](features/item-actions.md) |  |
| FE-109 | Drop into background | implemented | headless `simdrop:` | [item-actions](features/item-actions.md) |  |
| FE-110 | Cross-window and cross-app drag | implemented | code review | [item-actions](features/item-actions.md) | File URLs and file promises |
| FE-111 | Multi-item drag | implemented | unit; headless | [item-actions](features/item-actions.md) | Overlapping sources transferred once |
| FE-112 | Invalid drop prevention | implemented | unit | [qa-core](features/qa-core.md) |  |
| FE-113 | Packages and cloud drops | implemented | headless (simulated cloud) | [cloud](features/cloud.md) |  |

## Operations, progress, conflicts and recovery

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-114 | Copy and move progress | implemented | unit; snapshots | [file-operations](features/file-operations.md) |  |
| FE-115 | Pause, resume, cancel | implemented | unit; headless; acceptance T13 | [file-operations](features/file-operations.md) |  |
| FE-116 | Concurrent operations | implemented | headless; acceptance T30 | [file-operations](features/file-operations.md) |  |
| FE-117 | Replace, skip, compare, keep both | implemented | unit; acceptance T14 | [file-operations](features/file-operations.md) | Replace moves the old item to the Trash (DEC-010) |
| FE-118 | Folder merge | implemented | unit; acceptance T14 | [file-operations](features/file-operations.md) | Merges silently by default (Windows' "Hide folder merge conflicts"), prompt optional |
| FE-119 | Apply to remaining conflicts | implemented | unit | [file-operations](features/file-operations.md) |  |
| FE-120 | Permission and locked-file failures | implemented | unit; failure dialog snapshot | [file-operations](features/file-operations.md) |  |
| FE-121 | Out of space and destination loss | implemented | unit on a full disk image | [file-operations](features/file-operations.md) |  |
| FE-122 | Cross-volume move | implemented | unit; acceptance T13 | [file-operations](features/file-operations.md) |  |
| FE-123 | Metadata preservation | implemented | unit | [file-operations](features/file-operations.md) |  |
| FE-124 | Symlinks, hard links, sparse files | implemented | unit | [file-operations](features/file-operations.md) |  |
| FE-125 | Persistent job journal | implemented | unit; acceptance T16, T30 | [file-operations](features/file-operations.md) |  |
| FE-126 | Operation history | implemented | unit; headless | [file-operations](features/file-operations.md) |  |
| FE-127 | Queue controls | implemented | unit; behavior-checks `queue` | [file-operations](features/file-operations.md) | Off by default; labelled as an Arbor extra |
| FE-128 | Safe retry | implemented | unit; headless | [file-operations](features/file-operations.md) |  |
| FE-129 | Undo protection | implemented | unit; acceptance T17 | [file-operations](features/file-operations.md) |  |
| FE-130 | Optional copy verification | implemented | unit; headless | [file-operations](features/file-operations.md) |  |

## Search and filtering

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-131 | Current-folder search | implemented | acceptance T04, T18 | [search](features/search.md) |  |
| FE-132 | Whole-computer search | partial | code review | [search](features/search.md) | This Mac searches the Spotlight index (+ other local drives); not run headless to avoid real files |
| FE-133 | Name and content modes | implemented | unit | [search](features/search.md) |  |
| FE-134 | AQS property queries | implemented | unit (120+ assertions); acceptance T19 | [search](features/search.md) | Documented subset (compatibility table) |
| FE-135 | Search suggestions and history | implemented | unit; headless | [search](features/search.md) | History dropdown is pointer-only |
| FE-136 | Search options and refinement | implemented | unit; headless `searchmenu` | [search](features/search.md) |  |
| FE-137 | Search result details | implemented | snapshots; headless | [search](features/search.md) |  |
| FE-138 | Saved searches | implemented | unit; headless | [consistency](features/consistency.md) | `.arborsearch`, opens from Finder too |
| FE-139 | Search settings edge cases | implemented | unit; headless | [search](features/search.md) |  |
| FE-140 | Indexing integration | implemented | unit | [search](features/search.md) |  |
| FE-141 | Unindexed search | implemented | acceptance T18 | [search](features/search.md) |  |
| FE-142 | Semantic and cloud search | macOS boundary | — | [search](features/search.md) | No equivalent public API |
| FE-143 | Spotlight metadata adapter | implemented | unit (translation) | [search](features/search.md) | Live index results not observed headless |
| FE-144 | Why a result is absent | implemented | unit; acceptance T18 | [search](features/search.md) |  |
| FE-145 | Name-first ranking | implemented | unit (SearchRelevanceTests); acceptance T04 | [consistency](features/consistency.md) | Relevance is the default order of results |
| FE-146 | Search freshness | implemented | headless | [search](features/search.md) |  |

## Preview, metadata and properties

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-147 | Preview pane | implemented | snapshots | [properties](features/properties.md) |  |
| FE-148 | Details pane | implemented | unit; snapshots | [properties](features/properties.md) |  |
| FE-149 | Thumbnail providers | implemented | unit; headless counters | [icon-views](features/icon-views.md) |  |
| FE-150 | General properties | implemented | unit; headless | [properties](features/properties.md) |  |
| FE-151 | Detailed metadata | implemented | unit; headless | [properties](features/properties.md) |  |
| FE-152 | Metadata editing and removal | partial | unit | [properties](features/properties.md) | Embedded metadata read-only; "remove properties" makes a cleaned copy of images |
| FE-153 | Security and ownership | implemented | unit (real ACLs); headless | [properties](features/properties.md) |  |
| FE-154 | Sharing and customization properties | implemented | headless | [properties](features/properties.md) | Sharing hands off to System Settings |
| FE-155 | Previous Versions | implemented | unit (fake backups); headless | [properties](features/properties.md) | Real Time Machine disk not tested |
| FE-156 | Attribute check boxes | implemented | unit; headless | [properties](features/properties.md) |  |
| FE-157 | Version and signature tabs | implemented | unit | [properties](features/properties.md) |  |
| FE-158 | Downloaded-file unblock and provenance | partial | code review | [properties](features/properties.md) | An Unblock box removes the quarantine attribute (Explorer parity), which the spec asks not to copy; kept for owner review |
| FE-159 | Quick Look | implemented | headless `quicklook` | [consistency](features/consistency.md) |  |
| FE-160 | App bundles and packages | implemented | headless | [properties](features/properties.md) |  |
| FE-161 | Finder metadata | implemented | unit; headless | [properties](features/properties.md) |  |
| FE-162 | Cloud preview hydration control | implemented | acceptance T20 (simulated provider) | [cloud](features/cloud.md) |  |

## Archives and disk images

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-163 | ZIP browsing and extraction | implemented | unit; acceptance T12, T25 | [archives](features/archives.md) |  |
| FE-164 | ZIP creation | implemented | unit; acceptance T25 | [archives](features/archives.md) |  |
| FE-165 | Modify existing archives | not done | acceptance T25 (commands off inside) | [archives](features/archives.md) | Archives are read-only by decision (DEC-archives-3) |
| FE-166 | 7z, TAR and compressed TAR | implemented | unit; acceptance T25 | [archives](features/archives.md) |  |
| FE-167 | RAR extraction | partial | — | [archives](features/archives.md) | Read through the system libarchive; untested (no fixture can be built) |
| FE-168 | Archive compression options | implemented | unit; snapshots | [archives](features/archives.md) | No Zstandard writer |
| FE-169 | Encrypted archive behavior | implemented | unit | [archives](features/archives.md) | Detected and refused with an explanation, like Windows |
| FE-170 | Archive safety | implemented | unit; acceptance T25 | [archives](features/archives.md) |  |
| FE-171 | Mount and eject ISO | implemented | headless | [archives](features/archives.md) |  |
| FE-172 | Optical burn and disc tools | not done | — | [archives](features/archives.md) |  |
| FE-173 | Archive metadata portability | implemented | unit | [archives](features/archives.md) |  |

## Drives, devices, network and sharing

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-174 | Internal, external and removable volumes | implemented | headless with a disk image | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-175 | Safely eject | implemented | headless; acceptance T26 | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-176 | Network discovery and connect | implemented | headless (simulated servers) | [network](features/network.md) | Not run against a real server |
| FE-177 | Map and disconnect network locations | implemented | headless (simulated servers) | [network](features/network.md) | No drive letters (DEC-network-1) |
| FE-178 | Network credentials | implemented | unit | [network](features/network.md) | Keychain only via the system prompt |
| FE-179 | Offline and slow shares | implemented | unit; acceptance T26 | [network](features/network.md) |  |
| FE-180 | Local folder sharing controls | macOS boundary | headless | [properties](features/properties.md) | Handoff to System Settings › Sharing |
| FE-181 | Share sheet and nearby sharing | implemented | code review | [item-actions](features/item-actions.md) | System share sheet (AirDrop included) |
| FE-182 | Phone camera and portable devices | not done | — | — | No MTP/PTP browsing |
| FE-183 | Format, rename and disk tools | macOS boundary | headless | [properties](features/properties.md) | Handoffs to Disk Utility and Storage settings; volume rename where allowed |
| FE-184 | Encrypted and locked drives | macOS boundary | — | — | BitLocker has no Mac counterpart (DEC-019) |
| FE-185 | Offline Files and enterprise storage | macOS boundary | — | — | Sync Center/DFS have no Mac counterpart |
| FE-186 | Administrative file-operation prompts | not done | — | — | No privileged helper; permission failures are reported per item |
| FE-187 | Same-named shares | implemented | unit; acceptance T24 | [network](features/network.md) |  |
| FE-188 | Filesystem capabilities | implemented | unit; headless | [consistency](features/consistency.md) | Drive Properties › File System |

## Cloud and account integrations

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-189 | Cloud locations in navigation | implemented | unit; headless (test root) | [cloud](features/cloud.md) |  |
| FE-190 | Online-only, available, pinned states | implemented | unit; acceptance T20 | [cloud](features/cloud.md) | No pin state (no public API) |
| FE-191 | Download and free-space actions | implemented | headless | [cloud](features/cloud.md) |  |
| FE-192 | Sync errors and conflicts | partial | unit | [cloud](features/cloud.md) | Shown in the Status column; no provider handoff |
| FE-193 | Share links and permissions | not done | — | [cloud](features/cloud.md) |  |
| FE-194 | Cloud version history | not done | — | [cloud](features/cloud.md) |  |
| FE-195 | Multiple accounts | partial | unit | [cloud](features/cloud.md) | One node per account folder; no sign-in state |
| FE-196 | Home cloud recommendations | macOS boundary | — | [cloud](features/cloud.md) | No provider API |
| FE-197 | iCloud Drive | implemented | unit | [cloud](features/cloud.md) | Not checked against a signed-in account in tests |
| FE-198 | File Provider integration | partial | — | [cloud](features/cloud.md) | Uses the generic keys; unverified on real OneDrive/Dropbox/Google Drive |

## Accessibility, localization and preferences

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-199 | Keyboard-only operation | implemented | headless; acceptance T27 | [accessibility](features/accessibility.md) |  |
| FE-200 | VoiceOver | implemented | `axaudit:`/`axdump:` on 21 screens | [accessibility](features/accessibility.md) | No live VoiceOver session |
| FE-201 | Contrast, motion, transparency | implemented | snapshot with forced contrast | [accessibility](features/accessibility.md) |  |
| FE-202 | Text scaling and zoom | implemented | snapshots at 150 % | [accessibility](features/accessibility.md) |  |
| FE-203 | Focus after refresh and navigation | implemented | headless `focus:` | [accessibility](features/accessibility.md) |  |
| FE-204 | Localization and RTL | partial | `l10naudit:`; `extract-strings.sh --check`; RTL snapshots | [accessibility](features/accessibility.md) | String table and RTL mirroring in place; English only, no translations |
| FE-205 | Preferences persistence | implemented | two-launch headless run | [folder-options](features/folder-options.md) |  |
| FE-206 | Recent activity privacy | implemented | headless | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-207 | Permission guidance | implemented | headless (Trash, Time Machine, Local Network denied states) | [trash](features/trash.md) |  |
| FE-208 | Export and import preferences | implemented | unit; behavior-checks `settings` | [settings-transfer](features/settings-transfer.md) | Credentials and machine-specific paths stay out of the file |

## System integration and expansion boundary

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-209 | Third-party context actions | not done | — | — | No Mac action/provider contract yet |
| FE-210 | Third-party columns and property pages | not done | — | — |  |
| FE-211 | Namespace providers | implemented | unit; every location kind | [qa-core](features/qa-core.md) | `LocationProvider` registry (docs/ARCHITECTURE.md) |
| FE-212 | Preview and icon handlers | implemented | unit; headless | [icon-views](features/icon-views.md) | Quick Look; Windows-only handlers have no equivalent |
| FE-213 | Address commands and shell names | partial | unit; headless `address` | [address-entry](features/address-entry.md) | `shell:` names go to a Mac place or say why not; nothing launches, so hand-offs to System Settings, Font Book or Terminal are left out |
| FE-214 | WSL and developer storage nodes | macOS boundary | — | — | No Mac counterpart (DEC-019) |
| FE-215 | Windows shortcut file compatibility | implemented | unit; `windows-shortcut-checks.sh` | [windows-shortcuts](features/windows-shortcuts.md) | Read-only; Windows programs are never launched |
| FE-216 | Windows desktop, taskbar and Start host | macOS boundary | — | — | OS shell, out of scope |
| FE-217 | System Open and Save dialogs | macOS boundary | — | — | Other apps' dialogs can't be replaced |
| FE-218 | Reveal in Finder and Services | implemented | unit; behavior-checks `services` | [qa-core](features/qa-core.md) |  |
| FE-219 | Launch URLs and CLI entry | implemented | headless (path argument) | [qa-core](features/qa-core.md) | `Arbor <path>`; documents opened from Finder |
| FE-220 | Signed, notarized universal releases | partial | build checks | [distribution](features/distribution.md) | Universal build and DMG done; signing/notarization pipeline not run (no Developer ID yet) |
| FE-221 | Public open-source governance | implemented | — | [distribution](features/distribution.md) | MIT license, README, CONTRIBUTING, SECURITY, templates; this file is the roadmap |
| FE-222 | Privacy by default | implemented | code review (no telemetry, no own network calls) | — | No crash reporter |

## Reliability and acceptance coverage

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-223 | Unicode and normalization | implemented | unit (NFC/NFD, emoji) | [qa-core](features/qa-core.md) |  |
| FE-224 | Case sensitivity and case-only rename | implemented | unit on case-sensitive APFS, ExFAT, HFS+ images; acceptance T10 | [qa-core](features/qa-core.md) |  |
| FE-225 | Long and unusual paths | implemented | unit | [qa-core](features/qa-core.md) |  |
| FE-226 | Filesystem races | implemented | unit; acceptance T08, T15 | [qa-core](features/qa-core.md) |  |
| FE-227 | Symbolic link loops and packages | implemented | unit | [search](features/search.md) | Links never followed in copies or search; each folder visited once |
| FE-228 | Large directory responsiveness | implemented | `bench.sh --check`; acceptance T28 | [performance](features/performance.md) |  |
| FE-229 | Stable live updates | implemented | unit; acceptance T08, T28 | [performance](features/performance.md) |  |
| FE-230 | Failure-injection suite | implemented | unit (`FailureInjectionTests`) | [file-operations](features/file-operations.md) |  |
| FE-231 | Provider capability tests | implemented | unit (`ProviderCapabilityMatrixTests`); behavior-checks `capabilities` | [cloud](features/cloud.md) |  |
| FE-232 | Reference parity audit | not done | — | — | No Windows reference machine (see Known limitations) |
| FE-233 | User task validation | not done | — | — | No user studies run |
| FE-234 | Release completeness report | implemented | this file | — | Every FE-001…FE-258 row is listed |

## Additional research requirements (§21)

| ID | Capability | Status | How verified | Area | Notes |
|---|---|---|---|---|---|
| FE-235 | Multi-key view sorting | implemented | unit; acceptance T06 | [grouping](features/grouping.md) |  |
| FE-236 | Mixed AQS Boolean precedence | implemented | unit; acceptance T19 | [search](features/search.md) |  |
| FE-237 | Localized vs canonical query properties | implemented | unit; acceptance T19 | [search](features/search.md) |  |
| FE-238 | Virtual collection write destination | implemented | unit; acceptance T21 | [gallery-libraries](features/gallery-libraries.md) |  |
| FE-239 | Projection removal vs physical deletion | implemented | unit; acceptance T22 | [home-and-this-mac](features/home-and-this-mac.md) |  |
| FE-240 | Streamed and promised transfer negotiation | partial | acceptance T12 | [archives](features/archives.md) | Promises stream to disk; Finder-side interoperability not checked interactively |
| FE-241 | Execution success vs aborted/partial result | implemented | unit; acceptance T13 | [file-operations](features/file-operations.md) |  |
| FE-242 | Handler lifecycle and stale completion | implemented | unit | [icon-views](features/icon-views.md) |  |
| FE-243 | Decoded-image memory cost | implemented | unit; `bench.sh` media workload | [icon-views](features/icon-views.md) |  |
| FE-244 | Browser access to provider capabilities | implemented | documented API research | [cloud](features/cloud.md) |  |
| FE-245 | Attributes vs effective write permission | implemented | unit | [properties](features/properties.md) |  |
| FE-246 | Display ordering vs persistent identity | implemented | unit; core-checks; behavior-checks `selection` | [qa-core](features/qa-core.md) | Selection by item URL; file IDs for pins and favorites |
| FE-247 | Pinned reference environment manifest | not done | — | — | No Windows reference environment |
| FE-248 | Preference apply/reset scope | implemented | headless | [folder-options](features/folder-options.md) |  |
| FE-249 | Type-specific menu behavior | implemented | headless `menu:` dumps | [consistency](features/consistency.md) |  |
| FE-250 | Revalidation after a delayed decision | implemented | unit; acceptance T15 | [file-operations](features/file-operations.md) |  |
| FE-251 | Global cache and inactive-tab budgets | implemented | unit; `bench.sh` | [performance](features/performance.md) |  |
| FE-252 | Cold/warm and retained-growth benchmarks | implemented | `bench.sh --check` | [performance](features/performance.md) |  |
| FE-253 | Documentation-first reference procedure | implemented | — | — | Building authorized by DEC-000; all checks use disposable fixtures (TESTING.md) |
| FE-254 | Conditional namespace applicability | implemented | headless | [home-and-this-mac](features/home-and-this-mac.md) | Drives, shares and cloud nodes are listed only when present |
| FE-255 | Actual committed destination identity | implemented | unit | [file-operations](features/file-operations.md) |  |
| FE-256 | Promise completion vs partial output | partial | code review | [archives](features/archives.md) | Receiver errors are reported and nothing is copied from a failed promise; partial-file checks are bsdtar's |
| FE-257 | Progress callbacks vs pause capability | implemented | unit | [file-operations](features/file-operations.md) |  |
| FE-258 | Incomplete file-promise preflight metadata | implemented | code review | [archives](features/archives.md) | Drops accept promises without names; nothing is received before the drop |
