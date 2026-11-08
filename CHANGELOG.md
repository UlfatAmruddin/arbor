# Changelog

All notable user-visible changes. Versions follow `VERSION`; requirement IDs refer to [docs/SPEC.md](docs/SPEC.md) and
their status is in [docs/FEATURE-STATUS.md](docs/FEATURE-STATUS.md).

## Unreleased

### Privacy
- Clear Arbor history (Folder Options and Home) now also clears recent searches, operation history, the address bar's
  recent locations, recent documents (Open Recent) and open tabs' Back/Forward.
- Copies opened from Previous Versions are read-only and are removed when the app showing them quits.

### Digital Signatures
- A signature shows as OK only when it chains to Apple (Apple, Mac App Store, Developer ID, notarized), and every
  architecture slice has to pass.
- Ad hoc code shows as "Signed locally (ad hoc)" with the signer "Ad hoc (no certificate)"; self-signed code shows its
  signer as "Unknown developer (unverified name: …)".
- When the signer isn't identified by an Apple-issued certificate and there is no secure timestamp, the signing time is
  labelled "stated by the signer, not verified".

### Files
- Archives: unknown member types and unreadable listing rows are kept out of whole-archive extraction, link loops and
  very long link chains count as escaping, and listings too large to show are refused ("The archive lists more items
  than Arbor can show."). Links in extracted items are checked on disk, so names the volume treats as equal
  (such as "ſ" and "s") can't point a link outside the destination. Crafted ZIP64 values no longer crash Arbor.
- The time-remaining text no longer crashes on very long estimates.
- Empty Trash only deletes from real Trash folders, without following links.
- A copy or move keeps the original and the target when either changed while the job ran.
- Access-list and group edits apply only to the item the editor opened, and are refused if it was moved or replaced or
  a folder above it became a link.
- Content search reads only regular files and never waits on pipes or devices.
- Very large or malformed sizes, durations and years in file metadata no longer crash Arbor; size totals stop at the
  largest value instead.
- Network addresses with unusual host names no longer crash Arbor.

### Distribution
- Distribution builds ignore the `ARBOR_*` test variables.
- Ad-hoc signed releases use the hardened runtime.

## 0.2.0

The window now follows Windows 11 File Explorer's layout and behavior, and most of Explorer's places, views and dialogs
exist.

### Window and navigation
- Explorer-style title-bar tabs: equal widths with overflow arrows, drag to reorder, drag out to a new window, drop on
  another window's tab row to merge.
- Navigation row in Windows 11 order (Back, Forward, Up, Refresh, address bar, search box); tooltips name the target.
- Recent-locations list in the address bar; `\\server\share` and `smb://` addresses connect and open the share.
- Folder Options (General, View, Search) with every Advanced setting, per-folder views remembered across launches,
  folder types (General items, Documents, Pictures, Music, Videos), Apply to Folders / Reset Folders, and restoring
  windows and tabs at launch.

### Views
- Extra large, Large, Medium and Small icons, List, Tiles and Content, with thumbnails, check boxes and marquee
  selection.
- Details: Group by, column header filters, Choose Details with more metadata columns, multi-column sort order.
- Explorer's size formats (whole KB in Details), "Shortcut" as the type of aliases, sentence-case menus in the window.
- Text size (⌘+ / ⌘−), increased contrast, right-to-left layout support.

### Places
- Home with Quick access, Favorites and Recent; This Mac with drive tiles and capacity bars.
- Gallery (photos by month with a date rail) and Libraries (merged folders with a save location).
- Trash with Original Location, Date Deleted, Restore and Empty Trash.
- Network: discovered computers, server share lists, Map / Disconnect network drive, timeouts that never freeze the
  window.
- Cloud folders (iCloud Drive and File Provider folders) with a Status column, Download and Free up space.

### Files
- Search: subfolders, Spotlight plus a direct scan, Explorer's query syntax (AQS subset), search options, history,
  saved searches, relevance order and an explanation when results may be incomplete.
- Archives: browse and extract ZIP, 7z and TAR families; create ZIP, 7z and TAR with options; mount ISO images; unsafe
  members are never extracted.
- Copy and move: byte progress with speed and time left, pause and resume, Replace or Skip and compare dialogs,
  property-loss warning, optional verification, a transfer queue, Operation history with retry, and recovery of
  interrupted jobs after a crash.
- Properties: General, Security (with access-list editing), Details, Previous Versions (document versions and Time
  Machine copies), Customize, Digital Signatures; drive Properties with File System details.
- New ▸ templates, shortcuts (Mac aliases), Send to, rotate images, set desktop background, multi-item and batch rename.
- Undo and Redo for New folder, rename, Trash, move, copy and rotate, refusing whenever a change made elsewhere would
  be overwritten.

### Accessibility and quality
- Full keyboard operation (F6 regions, ⇧F10 context menus, type-to-select through input methods); VoiceOver names for
  every control.
- Memory and responsiveness budgets with a benchmark script; 100,000-entry folders open in under a second.
- Fixes found in acceptance runs: showing or hiding a column no longer clears the selection; ⇧-arrow range selection
  keeps its anchor when files appear inside the range; the extension warning for dotfiles (".env" → ".env.local") is
  worded correctly.

### Known limitations
- No Windows reference machine was used: parity is based on Microsoft documentation and recalled behavior.
- English only; ad-hoc signed builds until a Developer ID is available.

## 0.1.0

First version: tabs, folder tree, editable address bar, Details view, cut/copy/paste with conflict handling, rename,
Trash with undo, Preview pane and Quick Look.
