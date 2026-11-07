# Decision log

Format (spec §18.3): `ID | date | decision | alternatives | reason | affected requirements | status`.

**Status meanings:** *Confirmed* = explicitly decided by the project owner. *Provisional* = chosen by the implementer to unblock v0.1 and easy to change; it needs owner review.

| ID | Date | Decision | Alternatives | Reason | Affects | Status |
|---|---|---|---|---|---|---|
| DEC-000 | 2026-11-07 | Move from planning to building a first version | Keep planning | Project owner decision | FE-253 | **Confirmed** |
| DEC-001 | 2026-11-07 | Working name **Arbor**, bundle ID `io.github.arbor-files.Arbor`, original icon | Other names | Must not use Microsoft trademarks or artwork; tree = navigation tree | FE-221 | Provisional |
| DEC-002 | 2026-11-07 | **Swift + AppKit**, Swift Package Manager (no Xcode project) | SwiftUI, Rust core, Electron | Native tables/outlines/input, low memory, builds with only Command Line Tools | §15.2 | Provisional (matches spec recommendation) |
| DEC-003 | 2026-11-07 | **macOS 14+** | 13, 15 | Modern AppKit APIs; covers most Macs in use | FE-220 | Provisional |
| DEC-004 | 2026-11-07 | Distribution: direct download (GitHub Releases, later a Homebrew cask), Developer ID signed and notarized. **Not** the Mac App Store | App Store | A file manager needs broad file access that the App Store sandbox makes awkward. Notarization needs a $99/yr Apple Developer account; until then, build from source | FE-220 | Provisional; needs owner's Apple account decision |
| DEC-005 | 2026-11-07 | **MIT license** | Apache-2.0, GPL-3.0 | Simplest and widest reuse | FE-221 | Provisional |
| DEC-006 | 2026-11-07 | ~~Tabs are native macOS window tabs~~ (superseded by DEC-017) | Custom Explorer-style tab strip above the address bar | Free reordering, tear-off, merge and accessibility. **Known difference:** the tab strip sits below the toolbar, not above it as in Explorer | FE-017–FE-021 | Provisional |
| DEC-007 | 2026-11-07 | ~~Native Mac chrome~~ (superseded by DEC-017) with an Explorer *layout* (no Windows visual imitation) | Pixel imitation of Windows 11 | Maintainable, accessible, avoids trade-dress issues | §4.2 | Provisional |
| DEC-008 | 2026-11-07 | Defaults: Details view, Name ascending, folders first, extensions visible, hidden items off, ~~start in the home folder~~ (start location superseded by DEC-020) | Explorer's Home page, hidden extensions | Readability priority from the vision (spec §4.4 candidates) | FE-028, FE-044, FE-053 | Provisional |
| DEC-009 | 2026-11-07 | Keyboard: Mac ⌘ shortcuts plus Explorer keys in the file list (Return opens, F2 renames, Delete = Back, fn+Delete = Trash, ⌥←/→/↑, F5) | Separate Windows/Mac presets | Familiar without breaking text editing; plain Delete never deletes files | FE-066, FE-067 | Provisional |
| DEC-010 | 2026-11-07 | "Replace" moves the existing item to the **Trash** instead of erasing it | Erase like Explorer | Recoverable; safer | FE-117 | Provisional |
| DEC-011 | 2026-11-07 | Conflict dialog default is **Keep Both** | Replace | Non-destructive default | FE-117 | Provisional |
| DEC-012 | 2026-11-07 | Duplicate names follow Windows: `name - Copy.ext`, `name (2).ext`, `New folder (2)` | Finder's `name copy`, `name 2` | Familiar to the target users | FE-087, FE-117 | Provisional |
| DEC-013 | 2026-11-07 | Long names are shortened in the **middle**, keeping the extension visible | Tail truncation (Explorer) | Readability (FE-055) | FE-049, FE-055 | Provisional |
| DEC-014 | 2026-11-07 | Search box filters the **current folder** only in v0.1 | Recursive/indexed search | Keeps scope honest; recursive search is a later feature with visible coverage | FE-131–FE-146 | Provisional |
| DEC-015 | 2026-11-07 | App keeps running after the last window closes; quitting during a transfer asks first and cancels between items | Quit immediately | Mac convention; transfers aren't lost silently (T30) | FE-025, FE-116 | Provisional |
| DEC-017 | 2026-11-07 | Match **Windows 11 File Explorer visually and functionally** as closely as macOS allows | Native Mac look (DEC-007) | Project owner direction | All | **Confirmed**. Supersedes DEC-006 and DEC-007 |
| DEC-018 | 2026-11-07 | Visual parity uses Explorer's layout, spacing, colors and behaviors with **original artwork** (own drawn folder icons, SF Symbols) and the system font. Microsoft icons, fonts (Segoe) and logos are never copied | Copy Fluent assets | Copyright/trademark; keeps the project redistributable | §4.2, FE-221 | Confirmed by policy |
| DEC-019 | 2026-11-07 | Windows features with no Mac counterpart (BitLocker, WSL, Start/taskbar pinning, Control Panel, drive letters) get the closest Mac equivalent or an explicit documented boundary, never a fake button | Fake parity | Spec §13–14 | FE-079, FE-100, FE-184, FE-214, FE-216 | Confirmed by policy |
| DEC-016 | 2026-11-07 | Undo is shared across tabs, like Explorer | Per-tab undo | Matches the file system being shared | FE-091 | Provisional |
| DEC-020 | 2026-11-07 | New windows and new tabs open the **Home** location (Explorer's default "Open File Explorer to: Home"). A path given on the command line or dropped on the Dock still opens that folder | Home folder; This Mac | Explorer default; DEC-017 | FE-017, FE-069, FE-082 | Provisional (follows DEC-017) |
| DEC-021 | 2026-11-07 | Custom tab strip in the title-bar row, Explorer style; native window tabbing and NSToolbar removed. Close/minimize/zoom stay native and are centered in the tab row | Native window tabs (DEC-006) | DEC-017 visual parity; native tabs sit below the toolbar | FE-017–FE-020 | Provisional. Tear-off and merge by dragging a tab are built (docs/features/visual-parity.md) |
| DEC-022 | 2026-11-07 | Navigation row order is Windows 11's: Back, Forward, Up, **Refresh**, address bar, search box. Refresh is a separate button left of the address bar, not inside it | Refresh at the right end of the address box (Windows 10, and Arbor's first chrome) | docs/research/windows11-reference.md §1.1–§1.2: the documented button order is "Back, Forward, Up, Refresh, Search box" [W03], and since 22H2 Refresh sits left of the address bar (RECALL-h); DEC-017 | FE-011 | Provisional (follows DEC-017; supersedes the earlier right-end placement) |
| DEC-023 | 2026-11-07 | Features plug in through registries (locations, commands with menu slots, view modes, side panes, search) and register in `Features.swift`; see docs/ARCHITECTURE.md | One large window controller | Lets several contributors work in parallel with few merge conflicts | All | Provisional |

## Open questions for the owner

1. Name and icon: keep "Arbor"?
2. Apple Developer account for signed, notarized releases (DEC-004)?
3. ~~Tab strip position~~: answered by DEC-017; custom strip built (DEC-021).
4. ~~Starting location~~: Home page, like Explorer (DEC-020).
5. Is a Windows PC or virtual machine available for the reference audit (spec §2.2)? Without one, Arbor is "inspired by" Explorer and makes no claim of exact parity.
