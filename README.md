# Arbor

**A free, open-source file manager for macOS with the layout Windows users already know:** tabs, a folder tree beside the file list, a clickable path bar you can type into, a Details view with real columns, and a status bar.

> "Arbor" is a working name. This project isn't affiliated with or endorsed by Microsoft. "Windows" and "File Explorer" are Microsoft trademarks and are used here only to describe the layout the app is inspired by.

Status: **v0.2 foundation, early preview.** The window now follows Windows 11 File Explorer's layout and look (title-bar tabs, breadcrumb address bar, command bar, navigation pane, status bar). It browses and manages local files well. Many things Explorer does aren't built yet; see [What's not here yet](#whats-not-here-yet) and [docs/FEATURE-STATUS.md](docs/FEATURE-STATUS.md).

## Why

Finder is capable, but many people find its organization and readability hard: names get cut off, view settings feel unpredictable, there's no real cut-and-paste, and the path is hidden. Arbor keeps hierarchy, full file names, sizes, dates and the current location visible at all times, while respecting how macOS works.

## What works in v0.1

- **Tabs** in the title bar like Explorer: ⌘T new tab (opens Home), ⌘W close, ⌘1–⌘8 jump to a tab, ⌘9 last tab, ⌃Tab / ⌃⇧Tab or ⇧⌘] / ⇧⌘[ to cycle, middle-click a folder to open it in a new tab, drag tabs to reorder or down to move one to a new window. Right-click a tab for Duplicate, Close other tabs, Close tabs to the right and Move to new window. Each tab keeps its own history, selection, scroll position, search, sort and view.
- **Navigation**: Back, Forward, Up and Refresh. Back and Forward restore the selection and scroll position you left. Up from a disk goes to This Mac. The address bar shows breadcrumb segments; each › opens a menu of that folder's subfolders, and long paths collapse into «. Click empty space or press ⌘L (or ⌥D in the file list) to type a path or a place name such as Home or This Mac.
- **The address bar understands** `~/Documents`, relative paths, `"quoted paths"`, `file://` URLs, `smb://server/share`, and pasted Windows UNC paths (`\\server\share` becomes `smb://…`). It explains, rather than guesses, when you type a Windows drive letter like `C:\`. Typed text is never run as a command.
- **Home** shows your Quick access folders. **Navigation pane**: Home, Gallery, pinned folders (pin and unpin any folder), This Mac (all drives, with Eject) and Network. Gallery, Network and Trash pages say plainly that they aren't built yet. The arrow expands a folder; clicking the name opens it. Folders are only read when you expand them.
- **Details view**: Name, Date modified, Type and Size. Click a header to sort. Natural number order (file 2 before file 10). Folders first in either direction. Resize, reorder and hide columns (right-click the header). Long names are shortened in the middle so the extension stays visible; hover to see the full name.
- **Real cut and paste**: ⌘X marks files (they dim), ⌘V moves them. Originals are removed only after each copy succeeds. ⌘C/⌘V copies, and pasting into the same folder makes `name - Copy.ext`. Works with Finder's clipboard too.
- **Name conflicts**: Keep Both (default), Replace (the old file goes to the Trash, so it can be recovered), Skip or Cancel, with sizes and dates for both. Folders can be merged. You can apply one choice to all remaining conflicts.
- **Rename** with F2 or Rename. Only the name is selected, not the extension. You're warned before changing an extension, and case-only renames work. **New folder** (⇧⌘N) starts out ready to rename.
- **Trash**: ⌘⌫ or the Delete key. **Undo** (⌘Z) works across all tabs for rename, Trash, move and new folder, and never overwrites anything that has changed since. Permanent delete (⌥⌘⌫ or Shift+Delete) always asks first.
- **Drag and drop** inside the list, onto folders, onto the tree, and to and from other apps. Same drive moves, another drive copies; hold ⌥ to force a copy or ⌘ to force a move.
- **Preview pane** (⌥⌘P), a basic **Details pane** (⇧⌥⌘P; the two are exclusive, like Explorer) and **Quick Look** (Space). The preview won't silently download iCloud files.
- **Search box**: filters the current folder as you type, and the status bar shows how many items match.
- **Status bar**: item count, selection count and total size, plus transfer progress with a Cancel button.
- **Open With**, **Copy as Path** (⌥⌘C, each path in quotes like Explorer), **Open in Terminal**, **Share**, **Show in Finder**, **Show Package Contents**, **Select none / Invert selection**, **Compact view**, **Item check boxes**.
- Explorer-like light and dark themes with our own yellow folder icons (no Microsoft artwork). Core lists and text fields are native controls; the custom tab strip and buttons expose accessibility roles but haven't had a VoiceOver audit.

## Keyboard (Windows habit → Arbor)

| Windows | Arbor | |
|---|---|---|
| Enter | Return | Open |
| F2 | F2 | Rename |
| Backspace / Alt+← | Delete / ⌥← / ⌘[ | Back |
| Alt+→ | ⌥→ / ⌘] | Forward |
| Alt+↑ | ⌥↑ / ⌘↑ | Up |
| F5 | F5 / ⌘R | Refresh |
| Ctrl+L / Alt+D | ⌘L | Type a path |
| Ctrl+F / Ctrl+E | ⌘F | Search this folder |
| Ctrl+T / Ctrl+W | ⌘T / ⌘W | New / close tab |
| Ctrl+Tab / Ctrl+Shift+Tab | ⌃Tab / ⌃⇧Tab | Next / previous tab |
| Ctrl+Shift+1…8 | ⇧⌘1…8 | View modes (only Details is built) |
| Alt+Shift+P | ⇧⌥⌘P | Details pane |
| Ctrl+Shift+N | ⇧⌘N | New folder |
| Ctrl+X / C / V | ⌘X / C / V | Cut / copy / paste |
| Delete | fn+Delete or ⌘⌫ | Move to Trash |
| Shift+Delete | fn+Shift+Delete or ⌥⌘⌫ | Delete permanently (asks first) |
| Alt+P | ⌥⌘P | Preview pane |
| Ctrl+Shift+. (n/a) | ⇧⌘. | Show hidden items |

On a Mac keyboard, F2 and F5 may need **fn** unless "Use F1, F2, etc. keys as standard function keys" is turned on in System Settings → Keyboard.

## Install

Arbor needs **macOS 14 Sonoma or later** and runs natively on both Apple silicon and Intel Macs.

### Download

1. Download `Arbor-<version>.dmg` from the [latest release](https://github.com/ulfatamruddin/arbor/releases/latest).
2. Open it and drag **Arbor** onto the **Applications** folder.
3. Open Arbor from Applications or Launchpad.

**First launch of an unsigned build.** Until releases are signed with an Apple Developer ID and notarized (the release notes say which kind you have), macOS blocks the first launch with a message that it can't verify Arbor. To open it anyway, once:

- In Finder, right-click (or Control-click) Arbor in Applications, choose **Open**, then **Open** again. This works on macOS 14 Sonoma; macOS 15 and later no longer offer it, so use the next option there.
- Or try to open Arbor, then go to **System Settings → Privacy & Security**, scroll to Security, and click **Open Anyway** next to the message about Arbor. Confirm with your password.

After that, Arbor opens normally. The release page lists a SHA-256 checksum (`Arbor-<version>.dmg.sha256`) if you want to check the download: `shasum -a 256 Arbor-<version>.dmg`.

The first time you open Desktop, Documents or Downloads, macOS asks whether Arbor may access them. That's normal: Arbor only asks for what you open. From Terminal, `/Applications/Arbor.app/Contents/MacOS/Arbor ~/Projects` opens a specific folder.

### Build from source

It takes a few minutes and needs only Apple's free Command Line Tools:

```bash
xcode-select --install          # once, if you don't have the tools
git clone https://github.com/ulfatamruddin/arbor.git && cd arbor
scripts/build-app.sh            # creates build/Arbor.app for this Mac
open build/Arbor.app
```

Drag `build/Arbor.app` into `/Applications` to keep it. `scripts/build-app.sh release --universal` builds one app for both Apple silicon and Intel, and `scripts/make-dmg.sh` makes the disk image. Releases are described in [docs/RELEASING.md](docs/RELEASING.md).

## Development

```bash
scripts/test.sh                 # unit tests (works with Xcode or just Command Line Tools)
swift build                     # debug build
scripts/build-app.sh debug      # debug .app
```

- `Sources/ArborCore`: logic with no UI, fully unit-tested: listing, sorting, history, address resolution, naming, rename, and the copy/move engine with its conflict and safety rules.
- `Sources/Arbor`: the AppKit interface, organized as `Window/`, `Views/`, `Commands/`, `Locations/`, `Panes/`, `Support/`. Features plug in through registries; read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- `Sources/Arbor/DebugScript.swift`: a test harness that drives the real UI from a script (set `ARBOR_SCRIPT`; see the file). It's inactive in normal use.
- `docs/SPEC.md`: the product research and behavior specification, with requirement IDs (FE-001…FE-258).
- `docs/DECISIONS.md`: decisions made so far and which ones are still provisional.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## What's not here yet

Other view modes (icons, list, tiles, content; the menu lists them but only Details works), a real Home page (recent files), This Mac drive tiles, grouping, column filters, per-folder view settings, recursive and content search, archive browsing and creation, network browsing beyond `smb://` connect, cloud status badges, Gallery, Libraries, Properties dialog, batch rename, Trash browsing and Put Back for items trashed elsewhere, persistent transfer history, pause/resume, byte-level progress, saved sessions, localization, and a signed, notarized download. Every one of these is tracked by ID in [docs/FEATURE-STATUS.md](docs/FEATURE-STATUS.md).

## Privacy

Arbor has no telemetry and makes no network connections of its own.

## License

MIT. See [LICENSE](LICENSE).
