# Windows 11 File Explorer — behavior and appearance reference for Arbor

Version 0.1 · Compiled November 7, 2026 · Companion to `SPEC.md` (evidence rules in its §2, open questions in §18, source register in §19).

**Scope.** Stock Windows 11 File Explorer, targeting 24H2/25H2 general availability (builds 26100/26200), English (United States) UI, 100% scale, light theme, no shell extensions, local account unless noted. Nothing in this file was observed on a Windows installation. Every fact is documentation-derived or recalled, as labeled below.

## 0. How to read this file

| Label | Meaning | How to use it |
|---|---|---|
| **DOC** | Found in current Microsoft support, Learn, or Windows blog material. The source ID in brackets points to §17. | Treat as reference behavior, subject to the stated conditions. |
| **ROLLOUT** | Insider, Release Preview, or "gradually rolling out" text. | Conditional. Verify on the pinned reference build before you build it as default. |
| **RECALL** | Widely known Windows 11 behavior that I'm confident about but didn't find documented. **Unverified.** The suffix shows confidence: `RECALL-h` high, `RECALL-m` medium, `RECALL-l` low. | Candidate only. Each one needs a spec §2.3 observation record before anyone can claim parity. |

Rules applied: no third-party Windows tools (Files, PowerToys, ExplorerPatcher, StartAllBack) were used as evidence. Third-party how-to sites were read only for orientation and are never cited. A RECALL item is never upgraded because a third-party site agreed with it. Pixel metrics are approximate effective pixels (epx) at 100% scale and are always RECALL.

---

## 1. Window layout, top to bottom

### 1.1 Regions

| # | Region | Contents (left → right) | Approx. height | Label |
|---|---|---|---|---|
| 1 | Tab row (title bar) | Tabs (folder icon, title, ✕ close on hover or active), **+** "Add a new tab", drag area, then Minimize, Maximize/Restore, Close | ~40–48 epx | Tabs and "Add a new tab": DOC [W03]. Metrics: RECALL-m |
| 2 | Address / navigation row | Back, Forward, Up, Refresh, then the address bar (breadcrumb), then the search box | ~48 epx | Button set and order: DOC [W03] ("Back, Forward, Up, Refresh, Search box"). Metrics: RECALL-m |
| 3 | Command bar ("app bar") | New ▾ · Cut · Copy · Paste · Rename · Share · Delete · Sort ▾ · View ▾ · (Filter ▾, Home only) · "…" See more · right-aligned **Details** toggle | ~48 epx | New/Cut/Paste/Share/View/See more: DOC [W02][W03]. Exact order: RECALL-h. Filter: RECALL-l |
| 4 | Body | Navigation pane (left, resizable) · content pane · optional Details **or** Preview pane (right) | fills the rest | DOC [W03] |
| 5 | Status bar | Left: item and selection counts. Right: two view buttons | ~24 epx | DOC [W03] ("bottom right; buttons for changing view and layout"). Contents: RECALL-h |

- The address bar shows the location icon, then breadcrumb segments separated by "›". Each "›" opens a dropdown of sibling or child folders. Clicking empty space (or pressing Alt+D, Ctrl+L, or F4) switches it to an editable path. A chevron at the right end opens recent locations. **RECALL-h.** The address bar shows cloud status and the OneDrive quota flyout: **DOC [W08]**.
- The search box placeholder is `Search <location display name>`, for example "Search Home", "Search Downloads", or "Search Local Disk (C:)". **RECALL-h.**
- Navigation pane default width is about 200–240 epx, and it's drag-resizable. **RECALL-l.**
- Window chrome: Mica in the title/tab area, and the tab row uses the tabbed-title-bar pattern (Mica Alt guidance). The material is **DOC [W16]**. That Explorer uses this specific variant is **RECALL-m**.

### 1.2 Navigation buttons

| Button | Tooltip (approx.) | Enabled when | Label |
|---|---|---|---|
| ← Back | "Back to <name> (Alt + Left Arrow)" | history exists | RECALL-m |
| → Forward | "Forward to <name> (Alt + Right Arrow)" | forward history exists | RECALL-m |
| ↑ Up | "Up to "<parent>" (Alt + Up Arrow)" | not at the namespace root | RECALL-m |
| ⟳ Refresh | "Refresh "<name>" (F5)" | always | RECALL-m; F5 = refresh is DOC [W01] |

Since the 22H2 tabs update, Refresh sits to the left of the address bar, after Up. It is no longer inside the right end of the address box as in Windows 10. **RECALL-h** (order is consistent with DOC [W03]).

### 1.3 Command bar items (folder in Details view, nothing selected)

| Order | Item | Behavior | Label |
|---|---|---|---|
| 1 | **New ▾** | Split menu (see §1.4). Accessible name "New button, collapsed" | DOC [W03] |
| 2 | Cut (icon) | Disabled with no selection | RECALL-h |
| 3 | Copy (icon) | Disabled with no selection | RECALL-h |
| 4 | Paste (icon) | Enabled when the clipboard holds files | RECALL-h |
| 5 | Rename (icon) | Disabled with no selection | RECALL-h |
| 6 | Share (icon) | Opens the Windows share sheet. Files only | RECALL-h |
| 7 | Delete (icon) | Moves to the Recycle Bin | RECALL-h |
| 8 | **Sort ▾** | See §1.5 | RECALL-h |
| 9 | **View ▾** | See §1.6 | DOC [W02] |
| 10 | **Filter ▾** | Shown on Home only. File-kind filter (Documents, Spreadsheets, Presentations, PDFs…) | RECALL-l |
| 11 | **…** (See more) | See §1.7 | DOC [W02] ("See more" → "Options") |
| right | **Details** | Toggles the Details pane (Alt+Shift+P) | Pane and shortcut: DOC [W01][W08]. Button: RECALL-h |

Context-specific command bar items:
- Recycle Bin: "Empty Recycle Bin" and "Restore all items" / "Restore the selected items". A fixed bug left "Empty recycle bin" in the command bar after navigating away (**ROLLOUT [W22]**, which confirms the command lives there). Wording: RECALL-h.
- Inside a ZIP folder: "Extract all". RECALL-h.
- Gallery: "Collection ▾" and "Add Phone Photos". **DOC [W08]**.
- This PC: Map network drive is under "…" → "Map network drive" per the support doc's "More > Map network drive". **DOC [W05]**.
- Image selected: "Set as background", "Rotate left", "Rotate right". RECALL-m.
- Search results: "Search options ▾" and "Close search". RECALL-m (§12).

Icon-only buttons show a tooltip with the name and the shortcut, for example "Cut (Ctrl+X)". RECALL-m.

### 1.4 New ▾ menu (clean 24H2/25H2 install, no Office)

| Order | Item | Notes | Label |
|---|---|---|---|
| 1 | Folder | Shortcut text "Ctrl+Shift+N" shown in the menu | Ctrl+Shift+N = new folder: DOC [W01]. Menu text: RECALL-m |
| 2 | Shortcut | Launches the "Create Shortcut" wizard ("What item would you like to create a shortcut for?") | RECALL-h |
| — | separator | | RECALL-m |
| 3+ | Registered "ShellNew" types, **alphabetical by display name**: Bitmap image · (Contact) · Compressed (zipped) Folder · (Rich Text Document) · Text Document | Office adds Word/Excel/PowerPoint/Access items. WordPad, which registered **Rich Text Document**, was removed in 24H2, so that item is normally absent on 24H2+. "Contact" depends on Windows Contacts being present. | WordPad removal: DOC [W09]. List and sort: RECALL-m. RTF absence: RECALL-m. Contact: RECALL-l |

New items are created as "New folder", "New Text Document.txt", "New Bitmap image.bmp", or "New Compressed (zipped) Folder.zip". The name is immediately in inline-rename mode with the base name selected. If the name is taken: "New folder (2)". RECALL-h.

### 1.5 Sort ▾ menu

| Order | Item | Label |
|---|---|---|
| 1… | Radio list of sortable columns for the folder template. General items: Name, Date modified, Type, Size (plus Date created, Authors, Tags, Title when shown) | RECALL-m |
| — | "More ›" submenu with remaining sort keys and access to the column chooser | RECALL-l |
| — | separator | RECALL-m |
| | Ascending / Descending (radio) | RECALL-h |
| — | separator | RECALL-m |
| | Group by › (submenu: same column list, (None), Ascending, Descending) | RECALL-m |

Sorting puts folders before files in ascending Name order (folders stay first). The comparator is "logical" (numeric-aware): "file2" sorts before "file10". RECALL-h. For the API context see spec R07.

### 1.6 View ▾ menu

| Order | Item | Shortcut shown | Label |
|---|---|---|---|
| 1 | Extra large icons | Ctrl+Shift+1 | Item: DOC [W03]. Key: RECALL-h (pattern DOC [W01]) |
| 2 | Large icons | Ctrl+Shift+2 | DOC [W01] ("2 is Large icons") |
| 3 | Medium icons | Ctrl+Shift+3 | RECALL-h |
| 4 | Small icons | Ctrl+Shift+4 | RECALL-h |
| 5 | List | Ctrl+Shift+5 | Item: DOC [W02] ("icons, lists, details"). Key: RECALL-h |
| 6 | Details | Ctrl+Shift+6 | DOC [W01] ("6 is Details") |
| 7 | Tiles | Ctrl+Shift+7 | Item: DOC [W03]. Key: RECALL-h |
| 8 | Content | Ctrl+Shift+8 | Item: DOC [W03]. Key: RECALL-h |
| — | separator | | RECALL-m |
| 9 | Compact view (check) | — | DOC [W02] ("Compact view" reduces spacing) |
| 10 | Show › | — | DOC [W02] |
| 10.1 | Navigation pane (check) | | DOC [W02] |
| 10.2 | Details pane (check; exclusive with Preview pane) | Alt+Shift+P | Pane: DOC [W01]. Placement: RECALL-h |
| 10.3 | Preview pane (check; exclusive with Details pane) | Alt+P | Pane: DOC [W01]. Placement: RECALL-h |
| 10.4 | Item check boxes | | DOC [W02] |
| 10.5 | File name extensions | | DOC [W02] |
| 10.6 | Hidden items | | DOC [W02] |

The current layout shows a bullet or highlighted radio. RECALL-h. Ctrl+mouse wheel changes icon size continuously: **DOC [W01]**.

### 1.7 "…" See more menu (folder, nothing selected)

| Item | Label |
|---|---|
| Undo (Ctrl+Z), when there is something to undo | RECALL-m |
| Pin to Quick access | RECALL-m |
| Select all · Select none · Invert selection | RECALL-h |
| Properties | RECALL-h |
| Options (opens Folder Options) | DOC [W02] |

Additions on **This PC**: Map network drive · Disconnect network drive · Add a network location. Map network drive: DOC [W05]. The others: RECALL-m.

### 1.8 Status bar

| State | Left text | Label |
|---|---|---|
| No selection | `27 items` | RECALL-h |
| One file selected | `27 items    1 item selected  2.35 KB` (size shown for files only) | RECALL-h |
| Several | `27 items    3 items selected  14.2 MB` (no size if any folder is included) | RECALL-m |
| Cloud folder | may add an availability state (e.g., "Available on this device") | RECALL-l |

Right side, two toggle buttons: **Details** ("Displays information about each item in the window.") and **Large icons** ("Display items by using large thumbnails."). Status bar visibility follows Folder Options "Show status bar". Buttons: RECALL-h. Tooltips: RECALL-m.

---

## 2. Navigation pane and tabs

### 2.1 Default navigation pane (24H2/25H2, signed in with a personal Microsoft account)

| Order | Node | Notes | Label |
|---|---|---|---|
| 1 | Home | Landing page by default | DOC [W02][W18] |
| 2 | Gallery | | DOC [W08][W19] |
| 3 | OneDrive – Personal (or "OneDrive – <Org>") | Only if OneDrive is signed in | DOC [W03] (OneDrive in pane). Position: RECALL-h |
| — | separator | | RECALL-m |
| 4–9 | Desktop, Downloads, Documents, Pictures, Music, Videos | Pinned to Quick access by default (pin glyph shown on hover or right edge) | Set: DOC [W02]. Order: RECALL-m |
| 10… | User-pinned folders (append order) | | RECALL-m |
| — | separator | | RECALL-m |
| 11 | This PC | Expands to drives. Known folders no longer appear under This PC | DOC [W02] |
| 12 | Network | | RECALL-h |
| 13 | Linux | Only with WSL installed | RECALL-m |
| — | Mobile device (Android) | Only with "Show mobile device in File Explorer" on. One device at a time | DOC [W07] |

Hidden by default: Libraries ("Show libraries"), the full tree including Control Panel and Recycle Bin ("Show all folders"), and auto-expand ("Expand to open folder"). The options are **DOC [W02]** (Show libraries) and RECALL-h for the others (§11.2).

Selected node: a subtle filled rounded rectangle plus a short vertical accent "pill" at the left edge. Hover: lighter fill. RECALL-m.

### 2.2 Navigation pane context menus

| Target | Modern menu items (order) | Label |
|---|---|---|
| Pinned folder | Open in new tab · Open in new window · Unpin from Quick access · Pin to Start · Copy as path · Properties · — · Open in Terminal · — · Show more options | Unpin wording: DOC [W02]. Rest: RECALL-m |
| Any folder or drive node | Open in new tab · Open in new window · Pin to Quick access · Pin to Start · Copy as path · Properties · Show more options (plus Expand/Collapse in the legacy menu) | RECALL-m |
| Pane background (empty area) | Legacy menu: Show libraries · Show all folders · Expand to open folder (checkable) | RECALL-m |
| Home / Gallery nodes | Open in new tab · Open in new window · Pin to Start (Home also: Options) | RECALL-l |

Show more options from the navigation pane exists. A fixed bug confirmed this: **DOC [W18]** (HIST, 2022).

### 2.3 Tabs

| Behavior | Detail | Label |
|---|---|---|
| New tab | Ctrl+T, or the "+" button. Opens to the default start location (Home or This PC) | DOC [W01] for Ctrl+T. Start location: RECALL-h |
| Close tab | Ctrl+W. Closes the window if it is the last tab. The tab ✕ or a middle-click on the tab also closes it | Ctrl+W: DOC [W01]. Middle-click close: RECALL-h |
| Switch | Ctrl+Tab / Ctrl+Shift+Tab. Ctrl+1…9 jumps to tab N | DOC [W01] |
| Open folder in new tab | Context menu "Open in new tab". Middle-click a folder (also in the address bar or on Home) | Menu: RECALL-h. Middle-click in address bar and Home: ROLLOUT [W24] |
| Tear off / merge | Drag a tab out to make a window, or into another window's tab row | DOC [W08] |
| Tab context menu | Duplicate tab · Close tab · Close other tabs · Close tabs to the right (Move tab to new window: verify) | Duplicate: ROLLOUT→shipped [W23]. Others and order: RECALL-m |
| Session restore | Tabs aren't restored after closing. "Restore previous folder windows at logon" restores windows | RECALL-m |
| Tab title | Display name of the location. Tooltip shows the same | RECALL-m |
| Per-tab state | Each tab has its own history (Back/Forward) and selection | RECALL-h |

---

## 3. Special pages

### 3.1 Home

| Section | Content | Columns / layout | Label |
|---|---|---|---|
| Recommended | Carousel of file cards. Historically for Entra ID (Azure AD) accounts. Extended to personal Microsoft accounts and local accounts (not EEA). Can be turned off in Folder Options, which then shows Quick access instead | Card carousel | Carousel and AAD: DOC [W08]. MSA/local extension: ROLLOUT [W20] |
| Quick access | Pinned and frequent folders | Grid of folder tiles (icon + name + location subtitle) | Name and meaning: DOC [W18] |
| Favorites | Files added with "Add to Favorites" (previously "Pinned files") | List, same columns as Recent | Rename: DOC [W18]. Columns: RECALL-m |
| Recent | Recently opened files (local and, with an account, cloud) | List: Name · Date modified (or Date accessed) · Activity · File location | Activity column with people icons: ROLLOUT (search excerpt of a 2025 Dev/Beta post). Columns: RECALL-l |

- Home section headers are collapsible, and Home remembers each section's expanded or collapsed state. **ROLLOUT [W21]**.
- Hovering a file on Home shows commands such as "Open file location". **ROLLOUT [W20]**.
- Recent and Favorites items in Home are searchable from Home's search box. **DOC [W18]** (HIST).
- File item context menu on Home: Open · Open with › · Open file location · Add to Favorites / Remove from Favorites · Remove from Recent (older doc wording: "Remove from Quick access") · Copy as path · Share · Properties · Show more options. "Remove from Quick access": DOC [W02]. Rest: RECALL-m.
- Folder tile context menu: Open in new tab · Open in new window · Pin to Quick access / Unpin from Quick access · … **DOC [W02]** for the pin/unpin wording.
- To restore unpinned known folders: Home → Up arrow → right-click the folder → Pin to Quick access. **DOC [W02]**.

### 3.2 This PC

| Element | Detail | Label |
|---|---|---|
| Sections | "Devices and drives" and, if any, "Network locations". Known folders are gone since 22H2 | Folders gone: DOC [W02]. Section names: RECALL-h |
| Drive tile (Tiles layout) | Drive icon · label "Local Disk (C:)" · horizontal capacity bar · text `120 GB free of 476 GB` | RECALL-h |
| Capacity bar color | Accent blue normally. Red when free space is below ~10% | RECALL-m |
| Optical / removable | Media-specific icon. Empty card readers are hidden by "Hide empty drives" | Setting: DOC [W10]. Icons: RECALL-h |
| Details columns | Name · Type · Total Size · Free Space | RECALL-m |
| Mapped drive label | `share (\\server) (Z:)` | RECALL-m |
| Open to This PC | Folder Options → General → "Open File Explorer to: This PC" → Apply | DOC [W02] |

### 3.3 Gallery

| Element | Detail | Label |
|---|---|---|
| Content | Same set as the Photos app "All Photos" view. Newest first. Phone photos (OneDrive Camera Roll Backup) appear at top | DOC [W08][W19] |
| Collection ▾ | Choose which folders are included. Subfolders may be added to filter | DOC [W19] |
| Add Phone Photos | Opens a QR-code page to connect a phone | DOC [W08] |
| Layout | Justified rows of thumbnails without file names, grouped under month/year headers. Scrollbar shows a date timeline | RECALL-m |
| File dialogs | Gallery also appears in the file picker | DOC [W08][W19] |
| Collection management | "Collection ▾ → Manage collection" opens a folder list with Add/Remove | RECALL-m |

### 3.4 Recycle Bin

| Element | Detail | Label |
|---|---|---|
| Default columns | Name · Original Location · Date Deleted · Size · Item type · Date Modified | RECALL-h |
| Command bar | Empty Recycle Bin · Restore all items (no selection) / Restore the selected items (selection) · Recycle Bin properties (in "…") | Empty in command bar: ROLLOUT [W22]. Wording: RECALL-h |
| Item context menu | Restore · Cut · Delete · Properties | "Restore" returns the item to its original folder: DOC (OneDrive support page, see §17 W28). Rest: RECALL-h |
| Empty prompt | "Delete Multiple Items" — "Are you sure you want to permanently delete these 12 items?" Yes / No | RECALL-h |
| Properties dialog | Per-location list (Location, Space available) · "Custom size: Maximum size (MB)" · "Don't move files to the Recycle Bin. Remove files immediately when deleted." · "Display delete confirmation dialog" | Confirmation setting exists: DOC [W10]. Rest: RECALL-h |
| Not in navigation pane by default | Only with "Show all folders". Normally reached from the Desktop icon or the address bar | RECALL-h |
| Android phone deletes | Go to "Recycle bin – Connected device" on the phone and stay 30 days | DOC [W07] |

---

## 4. Context menus (Windows 11 modern menu, 24H2/25H2)

Common structure. **RECALL-h** unless noted:
- Top action row: Cut · Copy · (Paste) · Rename · Share · Delete. Win11 introduced these as icons: **DOC [W02]**. 24H2 "Labels were added to the context menu icons for actions like copy, paste, delete, and rename": **DOC [W09]**. Whether labels appear as text or tooltips: AUDIT.
- Then a vertical list, separators, app-extension entries, then **Show more options** (Shift+F10 opens the modern menu, Shift+right-click opens the legacy menu directly). **DOC [W01][W02]**.
- Items show right-aligned shortcut text, for example "Enter", "Alt+Enter", or "Ctrl+Shift+C". Copy as path shows Ctrl+Shift+C: DOC-excerpt (build 22543, search excerpt, §17 W25). Others: RECALL-m.

### 4.1 Single file (e.g., .txt)

| Order | Item | Label |
|---|---|---|
| icons | Cut · Copy · Rename · Share · Delete | DOC [W02] (set). Order: RECALL-m |
| 1 | Open (Enter) | RECALL-h |
| 2 | Open with › (default app list · Search the Microsoft Store · Choose another app). The chooser offers "Always" / "Just once" | "Open with", "Choose another app", "Always", "Just once": DOC [W03] |
| 3 | (Open file location: search results, Home, and Recent only) | RECALL-h |
| — | separator | |
| 4 | Compress to › ZIP File · 7z File · TAR File · Additional options | Formats and Additional options: DOC [W09]. Submenu wording: RECALL-m |
| 5 | Copy as path (Ctrl+Shift+C). Copies `"C:\full\path.txt"` with quotes | Command: RECALL-h. Shortcut: DOC-excerpt [W25]. Quotes: RECALL-h |
| 6 | Add to Favorites (or Remove from Favorites) | DOC-excerpt (build 22610, search excerpt, §17 W26). RECALL-h |
| 7 | Pin to Start (executables, shortcuts, some types) | RECALL-m |
| 8 | Properties (Alt+Enter) | Alt+Enter = properties: DOC [W01] |
| — | separator · app extensions (e.g., Edit in Notepad, OneDrive ›, Send with Nearby Share) | RECALL-m |
| last | Show more options | DOC [W02] |

Images add Set as desktop background · Rotate right · Rotate left. RECALL-h.

**ROLLOUT [W22]** (Insider, Nov 2025): a "Manage file" flyout gathers Compress to ZIP file, Copy as Path, Set as Desktop Background, Rotate Right, and Rotate Left. Cloud provider actions (Always keep on this device, Free up space) move into each provider's flyout. "Open folder location" moves next to Open / Open with. The name "Manage file" may change.
**ROLLOUT [W24]** (Insider, Aug 2026): a slimmer default menu with a "Customize menu" entry → Settings > Personalization > Context Menu. Built-in commands (Send to, Create shortcut, Print) can be toggled. The icon row can become inline text. Properties can move to the bottom.

### 4.2 Single folder

| Order | Item | Label |
|---|---|---|
| icons | Cut · Copy · Rename · (Share: cloud folders only) · Delete | RECALL-m |
| 1 | Open in new tab | RECALL-h |
| 2 | Open in new window | RECALL-h |
| 3 | Pin to Quick access / Unpin from Quick access | DOC [W02] |
| 4 | Pin to Start | RECALL-h |
| 5 | Compress to › | DOC [W09] |
| 6 | Copy as path | RECALL-h |
| 7 | Properties | RECALL-h |
| — | Open in Terminal (if Windows Terminal is installed) | RECALL-h |
| last | Show more options | DOC [W02] |

Double-click or Enter opens the folder in the current tab: **DOC [W03]** ("Enter: opens the selected item"). Default "Open each folder in the same window": RECALL-h.

### 4.3 Multiple items

| Item | Notes | Label |
|---|---|---|
| icons | Cut · Copy · Rename · Share (files only) · Delete | RECALL-m |
| Open | Files only. Opens each | RECALL-m |
| Compress to › | One archive named after the right-clicked item | RECALL-m |
| Copy as path | One quoted path per line (CRLF) | RECALL-m |
| Properties | Combined dialog: "N Files, M Folders", "All of type …" or "Multiple types", "All in …" location, summed Size and Size on disk | RECALL-h |
| Show more options | | DOC [W02] |

Multi-rename: F2 with several items selected renames them all to `Base (1).ext`, `Base (2).ext` … in sort order. RECALL-h.

### 4.4 Empty background of a folder

| Order | Item | Label |
|---|---|---|
| 1 | View › (same layouts as §1.6, plus Compact view?) | RECALL-m |
| 2 | Sort by › (columns · More… · Ascending · Descending) | RECALL-h |
| 3 | Group by › (columns · (None) · More… · Ascending · Descending) | RECALL-h |
| 4 | Refresh (verify; reliably present on the Desktop, verify inside folders) | RECALL-l |
| — | separator | |
| 5 | Undo <Action> (Ctrl+Z), e.g., "Undo Rename", "Undo Delete", "Undo Move", "Undo Copy" · Redo <Action> (Ctrl+Y) | RECALL-h |
| 6 | Paste / Paste shortcut (Paste shortcut only in the legacy menu) | RECALL-m |
| — | separator | |
| 7 | New › (as §1.4) | RECALL-h |
| — | separator | |
| 8 | Properties | RECALL-h |
| — | Open in Terminal | RECALL-h |
| last | Show more options | DOC [W02] |

### 4.5 Drive (in This PC)

| Item | Label |
|---|---|
| icons: Copy · Rename (Cut, Share, and Delete absent) | RECALL-l |
| Open in new tab · Open in new window · Pin to Quick access · Pin to Start | RECALL-m |
| Format… (non-system drives) · Eject (removable/optical) · Turn on BitLocker / Manage BitLocker (editions with BitLocker) | RECALL-m |
| Properties · Show more options | RECALL-h |
| Mapped drive: Disconnect (legacy menu, or "…" Disconnect network drive) | RECALL-h |

### 4.6 ZIP file

| Item | Label |
|---|---|
| Open (browses inside it like a folder) · Open with › | RECALL-h |
| **Extract All…** | DOC [W04] |
| Pin to Start · Copy as path · Add to Favorites · Properties · Show more options | RECALL-m |

Native read support also covers .tar, .tar.gz, .tar.bz2, .tar.zst, .tar.xz, .tgz, .tbz2, .tzst, .txz, .rar, and .7z. Password-encrypted archives aren't supported. **DOC [W08][W04]**.

### 4.7 "Show more options" legacy menu (file), for completeness

Open · Edit · Print · Open with › · Give access to › · Restore previous versions · Send to › (Bluetooth device · Compressed (zipped) folder · Desktop (create shortcut) · Documents · Fax recipient · Mail recipient · removable drives) · Cut · Copy · Create shortcut · Delete · Rename · Properties.
- "Send to › Compressed (zipped) folder": **DOC [W04]**.
- "Restore previous versions": DOC (File History page, spec R30).
- "Give access to": **DOC [W05]**.
- Order and the rest: RECALL-m.

---

## 5. Details view

### 5.1 Default columns by folder template ("Optimize this folder for")

| Template | Default columns, in order | Default sort / group | Label |
|---|---|---|---|
| General items | Name · Date modified · Type · Size | Name ascending, no grouping | RECALL-h |
| Documents | Name · Date modified · Type · Size | Name | RECALL-h |
| Pictures | Name · Date · Type · Size · Tags | Name | RECALL-m |
| Music | Name · # · Title · Contributing artists · Album | Name | RECALL-m |
| Videos | Name · Date · Type · Size · Length | Name | RECALL-m |
| Downloads (special) | General items columns | **Grouped by Date modified**, sorted by Date modified descending | RECALL-m |
| OneDrive / cloud folders | Name · Status · Date modified · Type · Size | Name | Status column: RECALL-h |
| Search results | Name · Date modified · Type · Size · Folder (path) | Relevance | RECALL-m |
| This PC | Name · Type · Total Size · Free Space | Grouped by Type ("Devices and drives") | RECALL-m |
| Recycle Bin | §3.4 | | RECALL-h |

Templates are auto-detected from content ("folder type discovery") until the user sets one in Properties → Customize. RECALL-m.

### 5.2 Columns, headers, and values

| Topic | Behavior | Label |
|---|---|---|
| Click header | Sorts by that column. Clicking again reverses | DOC [W03] (sorting buttons Name, Date modified). Toggle: RECALL-h |
| Sort indicator | Small chevron centered above the header text (▲ ascending / ▼ descending) | RECALL-h |
| Filter dropdown | Hovering a header shows a ▾ at its right edge. It opens a checklist of the column's group buckets (§6) and, for dates, a calendar picker. A checked filter marks the header with a ✓ and changes the address bar to "<folder> › Filtered" style | RECALL-m |
| Right-click header | Size column to fit · Size all columns to fit · — · checked list of common columns (Name, Date modified, Type, Size, Date created, Authors, Categories, Tags, Title) · More… | RECALL-h |
| Ctrl+Plus | Size all columns to fit (numeric keypad) | DOC [W01] |
| Resize / reorder | Drag the header divider. Double-click the divider to autosize. Drag a header to reorder. Name can't be hidden | RECALL-h |
| Choose Details dialog ("More…") | Title "Choose Details". Text "Select the details you want to display for the files in this folder." "Details:" checklist (~300 properties) · Move Up · Move Down · Show · Hide · "Width of selected column (in pixels):" · OK · Cancel | RECALL-h |
| Date format | System short date + short time without seconds, e.g. `11/7/2026 3:45 PM`. Follows the locale | RECALL-h |
| Size format | **Always in KB** in the Details Size column, rounded **up**, thousands separators (e.g., `1 KB` for 1 byte, `0 KB` for empty, `4,520,112 KB`). Folders blank. 1 KB = 1024 bytes | RECALL-h |
| Size elsewhere | Status bar, tooltips, Properties, and the Details pane use adaptive units with 3 significant digits (`2.35 KB`, `14.2 MB`, `4.31 GB`). Properties appends exact bytes `(1,290,240 bytes)` | RECALL-h |
| Type column | Friendly type name (e.g., "Text Document", "PNG File", "File folder", "Application", "Compressed (zipped) Folder") | RECALL-h |
| Status column | Cloud state glyphs: blue cloud (online-only), green check outline (locally available), solid green check (always keep on this device), sync arrows (syncing), red ✕ (error), people icon (shared) | Placeholder vs downloaded concept: DOC (spec R29). Glyph vocabulary: RECALL-h |
| Name column | Icon (16 px) + name. Truncates with ellipsis. Extension hidden by default for known types | Hide extensions default on: RECALL-h (setting DOC [W10]) |
| Row height | ~30 epx normal, ~22–24 epx in Compact view | RECALL-l |
| Hover tip | Pointing at an item shows "Type: … Size: … Date modified: …" (Show pop-up description) | RECALL-h |

---

## 6. Grouping

### 6.1 Buckets

| Grouped by | Buckets (display order, ascending) | Label |
|---|---|---|
| Date (modified/created/…) | Today · Yesterday · Earlier this week · Last week · Earlier this month · Last month · Earlier this year · A long time ago (future dates appear in forward-looking groups such as "Later this week" / "Next week" / "In the future": verify) | Past buckets: RECALL-h. Future: RECALL-l |
| Size | Empty (0 KB) · Tiny (0 – 16 KB) · Small (16 KB – 1 MB) · Medium (1 – 128 MB) · Large (128 MB – 1 GB) · Huge (1 – 4 GB) · Gigantic (> 4 GB) · Unspecified (folders) | RECALL-m (older Windows used 10 KB / 100 KB / 1 MB / 16 MB / 128 MB boundaries. Verify the current build) |
| Name | A – H · I – P · Q – Z · 0 – 9 · Other (symbols / non-Latin) | RECALL-l (verify. Grouping may instead use single initial letters) |
| Type | One group per friendly type name ("File folder", "Text Document"…) | RECALL-h |
| Date AQS equivalents | `date:today`, `date:yesterday`, `date:this week`, `date:last week`, `date:past month`, … | DOC [W12] (historical WDS reference) |

### 6.2 Group header appearance and behavior

| Aspect | Behavior | Label |
|---|---|---|
| Header text | `Today (3)`. Name plus count in parentheses | RECALL-h |
| Rule | Thin horizontal line extends to the right of the text | RECALL-h |
| Collapse | Chevron at the left (Win11) collapses or expands. Clicking the header selects all items in the group | RECALL-m |
| Keyboard | With a header focused: Left collapses, Right expands | RECALL-m |
| Header context menu | Collapse group · Collapse all groups / Expand all groups | RECALL-m |
| Sort within group | Items keep the current sort inside each group | RECALL-h |
| Persistence | Group-by is part of the per-folder view state | RECALL-h |

---

## 7. View layouts

| Layout | Icon size (100% scale) | Metadata shown | Label |
|---|---|---|---|
| Extra large icons | 256 px | Name below (wraps up to ~3 lines, ellipsis) | RECALL-h |
| Large icons | 96 px | Name below | RECALL-h |
| Medium icons | 48 px | Name below | RECALL-h |
| Small icons | 16 px | Name to the right. Flows in rows (left→right) | RECALL-h |
| List | 16 px | Name only. Flows in **columns** (top→bottom, then right) | RECALL-h |
| Details | 16 px | Columns (§5) | RECALL-h |
| Tiles | 48 px | Name · Type · Size (2–3 lines, to the right of the icon). Drives: name, bar, free-of-total | RECALL-h |
| Content | 32–48 px | One wide row per item: name + type/author/dimensions (left), Date modified + Size (right) | RECALL-m |
| Ctrl+wheel | Continuous size steps between the presets | DOC [W01] |

Thumbnails replace icons at Medium and above for images, videos, and documents with a thumbnail handler. A file-type badge overlays thumbnails ("Display file icon on thumbnails"). Folders show a "content peek" thumbnail. RECALL-h. Disable this with "Always show icons, never thumbnails" (§11.2).

---

## 8. Keyboard and selection

### 8.1 File Explorer shortcuts (verbatim set from Microsoft's Windows 11 page) — DOC [W01]

| Keys | Action |
|---|---|
| Alt+D | Select the address bar |
| Alt+Enter | Display properties for the selected item |
| Alt+Left arrow / Backspace | Navigate to the previous folder |
| Alt+mouse drag a file | Create a shortcut at the drop location |
| Alt+P | Show or hide the preview pane |
| Alt+Right arrow | View the next folder |
| Alt+Shift+P | Show or hide the details pane |
| Alt+Up arrow | Move up a level in the folder path |
| Ctrl+Arrow (move) + Spacebar | Select multiple individual items |
| Ctrl+D / Delete | Delete the selected item and move it to the Recycle Bin |
| Ctrl+E / Ctrl+F | Select the search box |
| Ctrl+L | Focus on the address bar |
| Ctrl+mouse drag a file | Create a copy at the drop location |
| Ctrl+mouse scroll wheel | Change the size and appearance of file and folder icons |
| Ctrl+N | Open a new window |
| Ctrl+Number (1–9) | Move to that tab number |
| Ctrl+Plus (+) | Resize all columns to fit text (numeric keypad) |
| Ctrl+Shift+E | Expand all folders from the tree in the navigation pane |
| Ctrl+Shift+N | Create a new folder |
| Ctrl+Shift+Number (1–9) | Change the view style (2 = Large icons, 6 = Details) |
| Ctrl+Shift+Tab / Ctrl+Tab | Previous / next tab |
| Ctrl+T | Open a new tab and switch to it |
| Ctrl+W | Close the active tab (closes the window if it's the only tab) |
| End / Home | Scroll to the bottom / top of the active window |
| F2 | Rename the selected item |
| F3 | Search for a file or folder |
| F4 | Select the address bar to change the current path |
| F5 | Refresh the window |
| F6 | Cycle through elements in the window |
| F11 | Maximize or minimize the active window |
| Left arrow | Collapse the current selection, or select the parent folder (tree) |
| Right arrow | Expand the current selection, or select the first subfolder (tree) |
| Shift+Arrow keys | Select multiple items |
| Shift+Delete | Permanently delete without moving to the Recycle Bin |
| Shift+F10 | Display the context menu for the selected item |
| Shift+mouse drag a file | Move it to the drop location |
| Shift+right-click | Display the Show more options context menu |
| Windows+E | Open File Explorer |

Additional documented keys:
- Shift+F6 cycles regions backward. Tab moves within toolbar and app bar elements and the Add a new tab icon. Alt moves focus to the app bar. Enter opens. **DOC [W03]**.
- Dialog keys (Ctrl+Tab between property-sheet tabs, Alt+underlined letter, Space toggles a check box, Backspace goes up a level in Open/Save dialogs): **DOC [W01]**.
- Ctrl+Shift+C = Copy as path: DOC-excerpt [W25].

Common shortcuts that apply in Explorer (generic Windows set, behavior in Explorer RECALL-h): Ctrl+A select all · Ctrl+C / Ctrl+X / Ctrl+V · Ctrl+Z / Ctrl+Y undo/redo · Ctrl+click toggle · Shift+click range · Ctrl+Space toggle the focused item · Num * expands the tree node fully · Num − / Num + collapse/expand · Enter on a group header toggles it (RECALL-l) · Esc clears a pending cut (RECALL-l).

### 8.2 Selection and rename behaviors

| Behavior | Detail | Label |
|---|---|---|
| F2 on a file | Inline edit box selects the **base name only** (not ".ext"), even with extensions shown | RECALL-h |
| F2 on a folder | Selects the whole name | RECALL-h |
| Tab / Shift+Tab during rename | Commits and starts rename on the next / previous item in view order | RECALL-h |
| Enter / click elsewhere | Commits. Esc cancels | RECALL-h |
| Slow double-click | Click a selected item's name again after a pause to start rename | RECALL-h |
| Type-to-select | Typing a prefix selects the first item whose name starts with it. The buffer resets after ~1 s idle. Repeating one letter cycles through matches. Option "When typing into list view" can send keystrokes to the search box instead | RECALL-h |
| Click on empty space | Clears the selection. Drag from empty space starts a marquee (rubber-band) selection | RECALL-h |
| Check boxes | With "Item check boxes" on: hover shows a check box at the top-left of each item, and a header select-all check box in Details | DOC [W02] (option). Visuals: RECALL-h |
| Cut visual | Cut items render semi-transparent until pasted | RECALL-h |
| After paste/move | Pasted items are selected in the destination | RECALL-m |
| Up navigation | After Up, the folder just left is selected | RECALL-h |

### 8.3 Rename and name validation messages

| Situation | Text | Label |
|---|---|---|
| Invalid character typed | Balloon tip: "A file name can't contain any of the following characters: \ / : * ? " < > \|". The keystroke is rejected | Reserved set: DOC [W13]. Balloon wording: RECALL-h |
| Change of extension | Dialog "Rename": "If you change a file name extension, the file might become unusable." / "Are you sure you want to change it?" Yes / No | RECALL-h |
| Empty name | "You must type a file name." | RECALL-m |
| Name ends with a space or period | Trailing spaces/periods are silently stripped (the shell doesn't support them) | Shell limitation: DOC [W13]. Stripping: RECALL-m |
| Reserved device name (CON, PRN, AUX, NUL, COM1–9, LPT1–9, also with extension) | "The specified device name is invalid." | Names: DOC [W13]. Message: RECALL-l |
| Name already exists (file) | "Rename File": "There is already a file with the same name in this location." With an offer to rename to "name (2).ext" (Yes/No) | RECALL-m |
| Name already exists (folder) | "Confirm Folder Replace"-style merge prompt (see §9.4) | RECALL-l |
| Path too long | "The file name(s) would be too long for the destination folder…" | MAX_PATH 260 legacy limit: DOC [W13]. Message: RECALL-l |

---

## 9. File-operation dialogs

### 9.1 Copy/move progress

| State | Content | Label |
|---|---|---|
| Title | `37% complete` (and window title in the taskbar) | RECALL-h |
| Compact ("Fewer details") | "Copying 12 items from **Source** to **Destination**" (links) · "37% complete" · progress bar · Pause (‖) and Cancel (✕) buttons · "More details" chevron | RECALL-h |
| Expanded ("More details") | Throughput graph (green area chart; turns yellow when paused) with "Speed: 45.2 MB/s" · Name: <current file> · Time remaining: About 1 minute · Items remaining: 10 (1.20 GB) · "Fewer details" | RECALL-h |
| Multiple operations | Stacked in one dialog: "2 operations running" with one panel each | RECALL-h |
| Calculating | "Calculating…" / "Discovering items…" before totals are known | RECALL-m |
| Same-volume move | Usually instant, no dialog unless it takes over ~1 s | RECALL-m |
| Dark mode | The copy dialog has a dark-mode variant (known issue mentions "dark mode copy dialog") | ROLLOUT [W22] |
| Verb variants | Copying / Moving / Deleting / Discarding / Extracting | RECALL-m |

### 9.2 Replace or Skip Files

| Element | Text | Label |
|---|---|---|
| Title | "Replace or Skip Files" | RECALL-h |
| Header | "Copying 3 items from **Src** to **Dst**" | RECALL-h |
| Prompt (1 conflict) | The destination already has a file named "report.docx" | RECALL-h |
| Prompt (n conflicts) | The destination has 3 files with the same names | RECALL-h |
| Option 1 | ✓ Replace the file in the destination / Replace the files in the destination | RECALL-h |
| Option 2 | ↷ Skip this file / Skip these files | RECALL-h |
| Option 3 | Compare info for both files (1) / Let me decide for each file (n) | RECALL-h |
| Footer | "More details" / "Fewer details" | RECALL-m |

### 9.3 "Let me decide" compare dialog

| Element | Text / behavior | Label |
|---|---|---|
| Title | "3 File Conflicts" | RECALL-m |
| Heading | "Which files do you want to keep?" | RECALL-h |
| Hint | "If you select both versions, the copied file will have a number added to its name." | RECALL-h |
| Columns | "Files from <Src>" ☐ and "Files already in <Dst>" ☐ (column header check boxes select all) | RECALL-h |
| Per row | File name, then on each side: thumbnail, date (+ "(newer)"), size (+ "(larger)") | RECALL-m |
| Extra check box | "Skip N files with the same date and size" | RECALL-h |
| Buttons | Continue · Cancel | RECALL-h |
| Both kept | Copied file renamed "name (2).ext" | RECALL-h |
| Same-folder copy | Pasting into the source folder yields "name - Copy.ext", then "name - Copy (2).ext" | RECALL-h |

### 9.4 Folder merge

Folders with the same name **merge silently** by default. Only conflicting files trigger §9.2. Turning off "Hide folder merge conflicts" (§11.2) shows **"Confirm Folder Replace"**: "This destination already contains a folder named 'X'." / "If the files in the existing folder have the same name as files in the folder you're moving or copying, they will be replaced. Do you still want to move or copy the folder?" · ☐ "Do this for all current items" · Yes / No / Cancel. RECALL-m (the option name is RECALL-h).

### 9.5 Delete confirmations

The default for "Display delete confirmation dialog" is **off** in Windows 11 (setting exists: DOC [W10]. Default off: RECALL-h). When it's on:

| Case | Title | Text | Buttons | Label |
|---|---|---|---|---|
| Recycle one file | Delete File | "Are you sure you want to move this file to the Recycle Bin?" (with icon, name, type, size, date) | Yes / No | RECALL-h |
| Recycle one folder | Delete Folder | "Are you sure you want to move this folder to the Recycle Bin?" | Yes / No | RECALL-h |
| Recycle many | Delete Multiple Items | "Are you sure you want to move these 5 items to the Recycle Bin?" | Yes / No | RECALL-h |
| Permanent (Shift+Delete), always shown | Delete File | "Are you sure you want to permanently delete this file?" | Yes / No | RECALL-h |
| Permanent many | Delete Multiple Items | "Are you sure you want to permanently delete these 5 items?" | Yes / No | RECALL-h |
| Too big to recycle / no Recycle Bin on the volume (network, some removable) | Delete File | "This file is too big to recycle. Do you want to permanently delete it?" / network: "Are you sure you want to permanently delete this file?" | Yes / No | RECALL-m |

### 9.6 Other operation dialogs

| Dialog | Text | Buttons | Label |
|---|---|---|---|
| File In Use | "The action can't be completed because the file is open in <App>" · "Close the file and try again." | Try Again · Cancel (+ "More details") | RECALL-h |
| Folder In Use | "The action can't be completed because the folder or a file in it is open in another program" | Try Again · Cancel | RECALL-h |
| Destination Folder Access Denied | "You'll need to provide administrator permission to copy to this folder" · ☐ Do this for all current items | 🛡 Continue · Skip · Cancel | RECALL-h |
| File Access Denied | "You'll need to provide administrator permission to delete this file" | 🛡 Continue · Skip · Cancel | RECALL-h |
| Not enough space | "There is not enough space on <Drive>. <N> MB is needed to copy these items. Delete or move files so you have enough space." | Try again · Cancel | RECALL-m |
| Properties lost | "Are you sure you want to copy this file without its properties?" | Yes · Skip · Cancel | RECALL-m |
| Item Not Found | "Could not find this item. This is no longer located in <path>. Verify the item's location and try again." | Try Again · Cancel | RECALL-m |
| Interrupted action | "An unexpected error is keeping you from copying the file. If you continue to receive this error, you can use the error code to search for help with this problem." + "Error 0x…" | Try Again · Skip · Cancel | RECALL-m |
| Large archive extract failure (fixed) | "Catastrophic Error (0x8000FFFF)" on 1.5 GB+ archives | — | ROLLOUT [W20] (as a fix) |

---

## 10. Properties dialogs

### 10.1 File → General tab

| Row | Example | Label |
|---|---|---|
| Icon + name box | editable name | RECALL-h |
| Type of file | `Text Document (.txt)` | RECALL-h |
| Opens with | `Notepad` [Change…] | RECALL-h |
| Location | `C:\Users\Ana\Documents` | RECALL-h |
| Size | `1.23 KB (1,264 bytes)` | RECALL-h |
| Size on disk | `4.00 KB (4,096 bytes)` | RECALL-h |
| Created / Modified / Accessed | `Saturday, November 7, 2026, 10:21:33 AM` (long date + time with seconds) | RECALL-h |
| Attributes | ☐ Read-only · ☐ Hidden · [Advanced…] | RECALL-h |
| Security (downloaded files only) | "This file came from another computer and might be blocked to help protect this computer." ☐ Unblock | RECALL-h |
| Buttons | OK · Cancel · Apply | RECALL-h |

**Advanced Attributes**: "File attributes:" ☐ File is ready for archiving · ☐ Allow this file to have contents indexed in addition to file properties · "Compress or Encrypt attributes:" ☐ Compress contents to save disk space · ☐ Encrypt contents to secure data [Details]. RECALL-h.

Tabs, in order: General · Security · Details · Previous Versions. Plus Compatibility (executables), Digital Signatures (signed files), Shortcut (.lnk). RECALL-h.

| Tab | Contents | Label |
|---|---|---|
| Security | "Object name:" · "Group or user names:" list · [Edit…] · "Permissions for <name>": Allow/Deny for Full control, Modify, Read & execute, Read, Write, Special permissions · [Advanced] | RECALL-h |
| Details | Property / Value grid grouped as Description (Title, Subject, Rating ★, Tags, Comments), Origin (Authors, Date created…), Content, File (Name, Item type, Folder path, Date created, Date modified, Size, Attributes, Availability, Offline status, Shared with, Owner, Computer). Link "Remove Properties and Personal Information" | RECALL-h |
| Previous Versions | "Previous versions come from File History or from restore points." List (Name, Date modified) · Open ▾ · Restore ▾ (Restore / Restore To…) | Restore and Restore to concept: DOC (spec R30). Wording: RECALL-m |

### 10.2 Folder

| Tab / row | Content | Label |
|---|---|---|
| General | Type: File folder · Location · Size · Size on disk · Contains: `12 Files, 3 Folders` · Created · Attributes: ▣ Read-only (Only applies to files in folder) (tri-state) · ☐ Hidden · [Advanced…] | RECALL-h |
| Tabs | General · Sharing · Security · Previous Versions · Customize | RECALL-h |
| Sharing | "Network File and Folder Sharing" · [Share…] · "Advanced Sharing" · [Advanced Sharing…] · "Password Protection" link | RECALL-h |
| Customize | "What kind of folder do you want?" · "Optimize this folder for:" [General items ▾ / Documents / Pictures / Music / Videos] · ☐ Also apply this template to all subfolders · "Folder pictures": [Choose File…] [Restore Default] · "Folder icons": [Change Icon…] | RECALL-h |

### 10.3 Drive

| Tab | Content | Label |
|---|---|---|
| General | Label box · Type: Local Disk · File system: NTFS · Used space / Free space (bytes + GB, color swatches) · Capacity · **pie chart** captioned "Drive C:" · [Details] (opens Storage settings) · [Disk Cleanup] (verify) · ☐ Compress this drive to save disk space · ☐ Allow files on this drive to have contents indexed in addition to file properties | RECALL-m |
| Other tabs | Tools (Error checking [Check] · Optimize and defragment drive [Optimize]) · Hardware · Sharing · Security · Previous Versions · Quota · (ReadyBoost: removable) | RECALL-h |

---

## 11. Folder Options

Opened from "…" → Options (**DOC [W02]**) or View › Options › "Change folder and search options" (**DOC**, search excerpt of the "View hidden files" support page). Title: "Folder Options". Tabs: General · View · Search. RECALL-h.

### 11.1 General tab

| Control | Options / default | Label |
|---|---|---|
| Open File Explorer to: | [Home ▾] / This PC | DOC [W02] |
| Browse folders | (•) Open each folder in the same window · ( ) Open each folder in its own window | RECALL-h |
| Click items as follows | ( ) Single-click to open an item (point to select): ( ) Underline icon titles consistent with my browser · ( ) Underline icon titles only when I point at them · (•) Double-click to open an item (single-click to select) | Setting exists: DOC [W10]. Layout: RECALL-h |
| Privacy | ☑ Show recently used files · ☑ Show frequently used folders · ☑ Show recommended section (Home) · ☑ Include account-based insights, recent, favorite, and recommended files · "Clear File Explorer history" [Clear] | "Include account-based…": DOC [W06]. Recommended checkbox exists: DOC [W08][W20]. Others: RECALL-m |
| Button | [Restore Defaults] | RECALL-h |
| Bottom | OK · Cancel · Apply | RECALL-h |

### 11.2 View tab

"Folder views": "You can apply this view (such as Details or Icons) to all folders of this type." [Apply to Folders] [Reset Folders]. Then "Advanced settings:" tree, then [Restore Defaults]. RECALL-h. Apply to Folders copies the current folder's view to all folders with the same template. Reset Folders discards saved per-folder views. RECALL-h.

Advanced settings, in display order (alphabetical within groups), with defaults:

| Item | Default | Label |
|---|---|---|
| **Files and Folders** | | |
| Always show icons, never thumbnails | ☐ | RECALL-h |
| Always show menus | ☐ | RECALL-m |
| Decrease space between items (compact view) | ☐ (☑ on some non-touch upgrades; verify) | Setting: DOC [W10]. Default: RECALL-m |
| Display file icon on thumbnails | ☑ | RECALL-h |
| Display file size information in folder tips | ☑ | RECALL-h |
| Display the full path in the title bar | ☐ | Setting: DOC [W10]. Default: RECALL-h |
| Enable window preloading for faster launch times | ☑ when present | ROLLOUT [W22] |
| Hidden files and folders: (•) Don't show hidden files, folders, or drives · ( ) Show hidden files, folders, and drives | Don't show | DOC [W10] + search-excerpt support page |
| Hide empty drives | ☑ | Setting: DOC [W10]. Default: RECALL-h |
| Hide extensions for known file types | ☑ | Setting: DOC [W10]. Default: RECALL-h |
| Hide folder merge conflicts | ☑ | RECALL-h |
| Hide protected operating system files (Recommended) | ☑ (unchecking warns: "You have chosen to display protected operating system files…") | RECALL-h |
| Launch folder windows in a separate process | ☐ | RECALL-h |
| Restore previous folder windows at logon | ☐ | RECALL-h |
| Show drive letters | ☑ | RECALL-h |
| Show encrypted or compressed NTFS files in color | ☐ | RECALL-h |
| Show pop-up description for folder and desktop items | ☑ | RECALL-h |
| Show preview handlers in preview pane | ☑ | RECALL-h |
| Show status bar | ☑ | RECALL-h |
| Show sync provider notifications | ☑ | RECALL-h |
| Use check boxes to select items | ☐ (☑ on touch-first devices) | Setting: DOC [W10]. Default: RECALL-m |
| Use Sharing Wizard (Recommended) | ☑ | RECALL-h |
| When typing into list view: ( ) Automatically type into the Search Box · (•) Select the typed item in the view | Select | RECALL-h |
| **Navigation pane** | | |
| Always show availability status | ☐ | RECALL-m |
| Expand to open folder | ☐ | RECALL-h |
| Show all folders | ☐ | RECALL-h |
| Show libraries | ☐ | DOC [W02] (option). Default: RECALL-h |

Settings > System > For developers > File Explorer mirrors: Show file extensions · Show hidden and system files · Show full path in title bar · Show empty drives. **DOC [W10]**.

### 11.3 Search tab

| Group | Control | Default | Label |
|---|---|---|---|
| How to search | ☐ Don't use the index when searching in file folders for system files (searches might take longer) | ☐ | RECALL-h |
| When searching non-indexed locations | ☑ Include system directories | ☑ | RECALL-h |
| | ☐ Include compressed files (ZIP, CAB…) | ☐ | RECALL-h |
| | ☐ Always search file names and contents (this might take several minutes) | ☐ | RECALL-h |
| Button | [Restore Defaults] | | RECALL-h |

---

## 12. Search

| Topic | Behavior | Label |
|---|---|---|
| Entry | Ctrl+E / Ctrl+F / F3 focus the box | DOC [W01][W03] |
| Scope | The current folder and its subfolders. Home searches relevant PC and cloud files. This PC is a slower, in-depth search | DOC [W06] |
| Live results | Results stream into the content pane as you type (after a short debounce). Suggestions drop down below the box | Suggestions below box: DOC (search excerpt of a Microsoft Search page). Streaming: RECALL-h |
| Address bar | Shows "Search Results in <location>" | RECALL-h |
| Progress | Green progress fill in the address bar while searching | RECALL-h |
| Non-indexed notice | Info bar: "Searches might be slow in non-indexed locations: <path>. Click to add to index…" | RECALL-m |
| Indexing | Classic vs Enhanced under Settings > Privacy & security > Searching Windows. Copilot+ PCs add semantic indexing | DOC [W06] |
| Wildcards | `*.doc` style wildcard search is supported | DOC (search excerpt). DOS wildcards DOC [W11] |
| Result columns | Name · Date modified · Type · Size · Folder (path). Matching text may be highlighted | RECALL-m |
| Exit | "Close search" (✕ in box) or Esc returns to the folder | RECALL-h |

### 12.1 Search options menu (command bar during search)

| Item | Submenu | Label |
|---|---|---|
| Current folder / All subfolders | scope radio | DOC (search excerpt: "limit results to the current folder or to all subfolders") |
| Date modified › | Today · Yesterday · This week · Last week · This month · Last month · This year · Last year | Item: DOC (excerpt). Values: RECALL-m |
| Kind › | Calendar · Communication · Contact · Document · E-mail · Feed · Folder · Game · Instant Message · Journal · Link · Movie · Music · Note · Picture · Playlist · Program · Recorded TV · Saved search · Task · Video · Web history · Unknown | Item: DOC (excerpt). Values: RECALL-m |
| Size › | Empty (0 KB) · Tiny (0 – 16 KB) · Small (16 KB – 1 MB) · Medium (1 – 128 MB) · Large (128 MB – 1 GB) · Huge (1 – 4 GB) · Gigantic (> 4 GB) | Item: DOC (excerpt). Values: RECALL-m |
| Other properties › | Type · Name · Folder path · Tags (inserts `type:`, `name:`, `folderpath:`/`folder:`, `tags:`) | RECALL-m |
| Advanced options › | Change indexed locations · File contents · System files · Zipped (compressed) folders | "system, or zipped files": DOC (excerpt). Rest: RECALL-m |
| Open file location | (with a result selected) | RECALL-h |
| Save search | Saves a `.search-ms` file to the Searches folder | RECALL-h |

### 12.2 Documented AQS (for parity tests)

| Construct | Documented example | Label |
|---|---|---|
| Implicit AND, OR, NOT (uppercase) | `social security` · `social OR security` · `social NOT security` | DOC [W12] |
| Left-to-right binding | "apple AND pear OR plum" = "(apple AND pear) OR plum". Use parentheses | DOC [W11] |
| Phrase | `"last quarter"` | DOC [W11] |
| Property query | `author:(theresa OR lee) folder:MyDocs` | DOC [W11] |
| Comparison / range | `size:>500` · `date:>11/13/21` · `date:11/13/21..11/15/21` · `System.Size:5kb..10kb` | DOC [W11][W12] |
| Relative dates | `date:today` · `date:yesterday` · `date:this week` · `date:last week` · `date:past month` · `modified:last week` | DOC [W12] |
| Kind | `kind:docs` · `kind:pics` · `kind:music` · `kind:videos` · `kind:folders` | DOC [W12] (historical WDS table) |
| Extension / name | `ext:.txt` · `filename:MyResume` · `folder:downloads` | DOC [W12] |
| Canonical | `System.Size:>1kb` · `System.FileName:~"Mic?osoft W*d"` (DOS wildcards) · `System.Author:~!"sanjay"` | DOC [W11] |
| Localization | Mnemonic keywords work only in the current UI language. Canonical names are language-independent | DOC [W11] |
| Empty value | `System.Keywords:=[]` (no value) | DOC [W11] |

---

## 13. ZIP and archives

| Topic | Behavior | Label |
|---|---|---|
| Create (classic) | Right-click → Show more options → Send to → Compressed (zipped) folder. Creates a same-named .zip in place | DOC [W04] |
| Create (24H2) | Compress to › ZIP / 7z / TAR. "Additional options" also offers gzip, BZip2, xz, Zstandard for individual files | DOC [W09] |
| Additional options dialog | "Create archive": Destination · Archive format · Compression method · Compression level · [Create] | RECALL-l |
| Browse | Opening a .zip shows its contents as a folder (read-only browsing. Drag out to extract one item). Command bar shows "Extract all" | Drag out: DOC [W04]. Button: RECALL-h |
| Extract All wizard | Title "Extract Compressed (Zipped) Folders" · heading "Select a Destination and Extract Files" · "Files will be extracted to this folder:" [<parent>\<zipname>] [Browse…] · ☑ "Show extracted files when complete" · [Extract] [Cancel] | Command name: DOC [W04]. Wizard text: RECALL-h |
| Read formats | ZIP, RAR, 7z, TAR (+ .tar.gz/.bz2/.zst/.xz, .tgz, .tbz2, .tzst, .txz) | DOC [W04][W08] |
| Limits | No encrypted or password archives. Encrypted files lose encryption when zipped | DOC [W04][W08] |
| Large archives | Extraction of 1.5 GB+ archives could fail (fixed) | ROLLOUT [W20] |

---

## 14. Network

| Topic | Behavior | Label |
|---|---|---|
| Network node | Lists discovered computers, media devices, and network infrastructure, grouped by category | RECALL-m |
| Discovery off | Banner "Network discovery is turned off." Prompt "Turn on network discovery and file sharing" | DOC [W05] |
| Own shares | Type `\\localhost` in the address bar | DOC [W05] |
| Share a folder | Give access to › Specific people (Everyone available) · Remove access | DOC [W05] |
| Map network drive (entry) | This PC → … (More) → Map network drive, or right-click This PC | DOC [W05] |
| Map Network Drive dialog | Heading "What network folder would you like to map?" · "Specify the drive letter for the connection and the folder that you want to connect to:" · **Drive:** [Z: ▾] (any unused letter) · **Folder:** [▾] [Browse…] · "Example: \\server\share" · ☑ **Reconnect at sign-in** · ☐ **Connect using different credentials** · link "Connect to a Web site that you can use to store your documents and pictures." · [Finish] [Cancel] | Drive, Folder, Browse, Reconnect at sign-in, Finish: DOC [W05]. Other text, defaults, Z: preselect, credentials check box: RECALL-h |
| Failure | Target computer may be off or permissions lacking. Contact admin | DOC [W05] |
| Disconnect | Right-click the mapped drive → Show more options → Disconnect, or This PC "…" → Disconnect network drive | RECALL-h |
| Add a network location | Wizard for FTP/WebDAV locations. Appears under This PC "Network locations" | RECALL-m |
| SMB defaults (24H2) | SMB signing is required by default. Guest/legacy shares may fail to connect | DOC [W09] |

---

## 15. Visual tokens (Fluent, Windows 11)

No assets copied. Values are documented design-system values unless marked.

| Token | Value | Label |
|---|---|---|
| Window corner radius | 8 px (0 when maximized or snapped) | DOC [W14] |
| Flyouts, menus, dialogs | 8 px (OverlayCornerRadius) | DOC [W14] |
| In-page controls, list item backplates, buttons, text boxes | 4 px (ControlCornerRadius) | DOC [W14] |
| Tooltips | 4 px | DOC [W14] |
| Bars (progress, scroll, slider) | 4 px | DOC [W14] |
| Adjacent segments (split button halves) | 0 px between them | DOC [W14] |
| UI font | Segoe UI Variable (weight + optical-size axes). Mac substitute: SF Pro, or Selawik (metric-compatible with Segoe UI, open source) | DOC [W15] |
| Type ramp | Caption 12/16 · Body 14/20 · Body Strong 14/20 semibold · Body Large 18/24 · Subtitle 20/28 semibold · Title 28/36 · Title Large 40/52 · Display 68/92 (size/line-height epx) | DOC [W15] |
| Minimums | 12 px Regular, 14 px Semibold. Sentence case. Ellipsis truncation | DOC [W15] |
| Explorer body text | ~14 epx (12 epx for secondary text such as drive free space) | RECALL-m |
| Icons | Segoe Fluent Icons glyph font for commands | DOC [W15] |
| Backdrop | Mica (opaque, wallpaper-tinted, sampled once). Mica Alt for tabbed title bars. Falls back to solid `SolidBackgroundFillColorBase` when transparency is off, in Battery Saver, on low-end hardware, or when the window is **inactive** | DOC [W16] |
| Layering | Base Mica → commanding layer (`LayerOnMicaBaseAltFillColorDefaultBrush`) → content layer (`LayerFillColorDefaultBrush`) | DOC [W16] |
| Accent | User accent color (default Windows blue). Used sparingly for state: selection indicator pill, focus, primary buttons, capacity bars | Principle: DOC [W17]. Explorer usage: RECALL-m |
| Content selection (file list) | Light theme: pale accent-tinted fill with a thin accent-tinted border on the rounded (4 px) item rect. Hover is a lighter, neutral fill. Dark theme: gray-blue equivalents | RECALL-l. **Sample from the reference.** Don't use Windows 10's #CCE8FF / #E5F3FF without verifying |
| Navigation pane selection | Neutral subtle fill + 3 × ~16 px accent pill on the left edge | RECALL-m |
| Focus visual | Two-ring focus rectangle (outer dark/white, inner contrasting) on keyboard focus only | RECALL-m |
| High contrast | Mica replaced by the user's chosen background color | DOC [W16] |

---

## 16. Mac mapping notes (no direct macOS equivalent)

| Windows concept | Why it has no equivalent | Suggested handling (PROP, not evidence) |
|---|---|---|
| Drive letters (C:, Z:), "Show drive letters" | macOS mounts volumes under /Volumes. No letters | Show volume names. Never invent letters (spec FE-013) |
| This PC "free of total" tiles | Finder has no unified drives page | Build from mounted-volume capacity APIs |
| Recycle Bin per volume, "Original Location" column, Restore | Mac Trash has "Put Back" but limited original-location metadata via public API | Feasibility audit. Restore may be partial (spec §12) |
| Shift+Delete permanent delete | Finder: ⌥⌘⌫ "Delete Immediately" | Map with confirmation |
| Ctrl+X cut-then-paste | Finder: ⌘C then ⌥⌘V move | Implement cut intent internally. Pasteboard has no cut flag |
| "Show more options" legacy menu, shell extensions, Open in Terminal | No shell-extension model. Finder Sync/Services differ | Single menu. Offer Services/Quick Actions |
| Folder templates (General items, Documents, Pictures, Music, Videos) and "Apply to Folders" | Finder has per-folder view settings but no content templates | Implement own template inference and view store |
| Libraries, Gallery collection, Home "Recommended" (account insights, Office.com) | No equivalent. Account-specific Microsoft services | Gallery from user-chosen folders. Omit Recommended or replace with local Recents |
| Quick access frequent folders | Finder sidebar Favorites (manual) + Recents (files) | Own frequency tracker (privacy toggle mirrors §11.1) |
| Details-column "Size always in KB" | Finder uses adaptive units | Offer an Explorer-parity format option |
| Hidden/System/Read-only/Archive attributes, "Advanced Attributes" (compress, encrypt, index) | macOS has hidden flag, locked flag, permissions, xattrs, no per-file EFS/NTFS compression | Map Hidden→UF_HIDDEN/dotfile, Read-only→locked. Omit others (spec FE-245) |
| "Hide protected operating system files" | SIP-protected paths, different semantics | Single "Show hidden" toggle plus system-path filter |
| Security tab (NTFS ACL Allow/Deny grid) | POSIX permissions + ACLs. Finder shows Sharing & Permissions | Show Mac permission model, not an NTFS clone |
| Previous Versions (File History / restore points) | Time Machine. No public per-file version browsing API comparable to Explorer's tab | Link to Time Machine or document-versions where available |
| Map network drive (letter, "Reconnect at sign-in") | Finder "Connect to Server" (⌘K). Login Items for reconnect | Connect dialog with "reconnect at login" via saved mount |
| UNC paths `\\server\share` | smb:// URLs | Translate pasted UNC to smb:// (spec FE-014) |
| Network discovery banner, "Give access to" sharing | System Settings > Sharing | Hand off to System Settings |
| AQS (`kind:`, `date:last week`, `System.*` canonical names) | Spotlight uses NSPredicate/MDQuery syntax and kMDItem attributes | Translate a documented AQS subset. Flag unsupported terms |
| Windows Search index options (Folder Options → Search) | Spotlight privacy/indexing in System Settings | Explain coverage. Fallback crawl (spec R26) |
| Compress to 7z/TAR/gzip/xz/zstd, RAR reading | Archive Utility handles zip/tar/gz. No 7z/RAR built in | Bundle libarchive or similar (license check) |
| Mobile device node (Android via Link to Windows) | No Mac equivalent | Out of scope unless a provider exists |
| Mica / Mica Alt materials | NSVisualEffectView materials differ (vibrancy, not wallpaper-sampled opaque tint) | Approximate with window-background material. Accept difference |
| Segoe UI Variable, Segoe Fluent Icons | Licensing prevents bundling | SF Pro + SF Symbols, or Selawik + own icons |
| Ctrl-based shortcuts, F-keys (F2, F5, Alt+Up) | Mac uses ⌘, and F-keys often map to media keys | Keyboard preset decision is open (spec §1.2) |
| Single-click-to-open option | Finder lacks it | Can be implemented in-app |
| Sharing Wizard, "Use Sharing Wizard" option | No equivalent | Omit |
| "Launch folder windows in a separate process" | Process model differs | Omit (resource-budget concern) |
| Status column cloud glyphs (OneDrive) | File Provider decorations. Third-party access limited | Show only what public File Provider APIs expose (spec FE-244) |

---

## 17. Source register

All Microsoft first-party sources were retrieved November 7, 2026 unless marked "excerpt" (seen only as a search-result excerpt, page not opened).

| ID | Source | Type | Used for |
|---|---|---|---|
| W01 | [Keyboard shortcuts in Windows](https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec) | DOC | §8.1, panes, tabs, view shortcuts |
| W02 | [File Explorer in Windows](https://support.microsoft.com/en-us/windows/experience/fileexplorer/file-explorer-in-windows) | DOC | Home, pins, View/Show, Options, context-menu icon row |
| W03 | [Use a screen reader to explore and navigate File Explorer](https://support.microsoft.com/en-us/windows/use-a-screen-reader-to-explore-and-navigate-file-explorer-in-windows-e7d3a548-87dd-459f-a991-9fde3f7ce927) | DOC | Regions, toolbar order, layouts list, Open with |
| W04 | [Zip and unzip files](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/zip-and-unzip-files) | DOC | §13 |
| W05 | [File sharing over a network in Windows](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/file-sharing-over-a-network-in-windows) | DOC | §14 |
| W06 | [Find your files and apps in Windows](https://support.microsoft.com/en-us/windows/find-your-documents-in-windows-5c7c8cfe-c289-fae4-f5f8-6b3fdba418d2) | DOC | Search scope, privacy option, indexing |
| W07 | [Setting up and using your phone in File Explorer](https://support.microsoft.com/en-gb/windows/experience/fileexplorer/setting-up-and-using-your-phone-in-file-explorer) | DOC | Mobile device node |
| W08 | [September 26, 2023 Windows configuration update](https://support.microsoft.com/en-gb/servicing/os/configuration-updates/2023/08/september-26-2023-windows-configuration-update) | DOC (22H2 release notes; current behavior assumed carried forward) | Home, Gallery, Details pane, archives, tab tear-off |
| W09 | [What's new in Windows 11, version 24H2](https://learn.microsoft.com/en-us/windows/whats-new/whats-new-windows-11-version-24h2) | DOC | Compress to formats, menu labels, WordPad removal, SMB |
| W10 | [Windows settings backup and restore catalog](https://learn.microsoft.com/en-us/windows/configuration/windows-backup/catalog) | DOC | Names of Folder Options and For developers settings |
| W11 | [Using Advanced Query Syntax programmatically](https://learn.microsoft.com/en-us/windows/win32/search/-search-3x-advancedquerysyntax) | DOC/SDK | §12.2 |
| W12 | [Advanced Query Syntax (WDS 2.x)](https://learn.microsoft.com/en-us/windows/win32/lwef/-search-2x-wds-aqsreference) | DOC (marked obsolete by Microsoft; HIST) | Keyword examples |
| W13 | [Naming Files, Paths, and Namespaces](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file) | DOC/SDK | Reserved characters and names, trailing period/space |
| W14 | [Geometry in Windows 11](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/geometry) | DOC | Corner radii |
| W15 | [Typography in Windows](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/typography) | DOC | Font, ramp |
| W16 | [Mica material](https://learn.microsoft.com/en-us/windows/apps/design/style/mica) | DOC | Backdrop and layering |
| W17 | [Color in Windows](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/color) | DOC | Accent principles (no hex values published there) |
| W18 | [Insider build 22593](https://blogs.windows.com/windows-insider/2022/04/06/announcing-windows-11-insider-preview-build-22593/) | ROLLOUT→shipped (HIST) | Home / Quick access / Favorites naming |
| W19 | [Insider build 23435](https://blogs.windows.com/windows-insider/2023/04/14/announcing-windows-11-insider-preview-build-23435/) | ROLLOUT→shipped (HIST) | Gallery |
| W20 | [Release Preview 26100.7015 / 26200.7015](https://blogs.windows.com/windows-insider/2025/10/21/releasing-windows-11-builds-26100-7015-and-26200-7015-to-the-release-preview-channel/) | ROLLOUT | Recommended for MSA/local accounts, Home hover commands |
| W21 | [Release Preview 26100.9539 / 26200.9539](https://blogs.windows.com/windows-insider/2026/09/10/announcing-windows-11-release-preview-builds-26100-9539-26200-9539/) | ROLLOUT | Home section collapse memory, Details pane reorganization, Preview pane "Preview anyway" |
| W22 | [Insider build 26220.7271](https://blogs.windows.com/windows-insider/2025/11/21/announcing-windows-11-insider-preview-build-26100-7271-dev-beta-channels/) | ROLLOUT | Manage file flyout, window preloading option, Recycle Bin command bar |
| W23 | [Insider build 26120.1330](https://blogs.windows.com/windows-insider/2024/07/26/announcing-windows-11-insider-preview-build-26120-1330-dev-channel/) | ROLLOUT | Duplicate tab |
| W24 | [Improving the File Explorer context menu (Aug 2026)](https://blogs.windows.com/windows-insider/2026/08/17/improving-file-explorer-context-menu-faster-simpler-and-more-customizable/) | ROLLOUT | Customizable menu, middle-click new tab |
| W25 | [Insider build 22543](https://blogs.windows.com/windows-insider/2022/01/27/announcing-windows-11-insider-preview-build-22543/) | excerpt (HIST) | Ctrl+Shift+C next to Copy as path |
| W26 | [Insider build 22610](https://blogs.windows.com/windows-insider/2022/04/29/announcing-windows-11-insider-preview-build-22610/) | excerpt (HIST) | "Add to Favorites" on file menu |
| W27 | [Insider build 22631.2048](https://blogs.windows.com/windows-insider/2023/07/13/announcing-windows-11-insider-preview-build-22621-2048-and-22631-2048/) | excerpt (HIST) | Gallery "Add Phone Photos" |
| W28 | [Restore deleted files or folders in OneDrive](https://support.microsoft.com/en-us/office/restore-deleted-files-or-folders-in-onedrive-949ada80-0026-4db3-a953-c99083e6a84f) | excerpt (DOC) | Recycle Bin "Restore" returns item to original folder |

Not found in current Microsoft documentation, so it stays RECALL:
- Exact Sort/View/"…" menu order.
- The modern context-menu item order.
- Copy, conflict, and delete dialog wording.
- Properties layouts.
- The full Folder Options Advanced list and defaults.
- Group bucket boundaries.
- Icon pixel sizes.
- Details-view KB formatting.
- Map Network Drive secondary text.
- Explorer selection colors.

These are the highest-value items for the first observation pass on a pinned 24H2/25H2 reference (spec §2.2–2.3, FE-247).
