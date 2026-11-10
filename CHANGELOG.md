# Changelog

All notable user-visible changes. Versions follow `VERSION`; requirement IDs refer to [docs/SPEC.md](docs/SPEC.md) and
their status is in [docs/FEATURE-STATUS.md](docs/FEATURE-STATUS.md).

## 0.3.0

### New
- Address bar: path suggestions while typing, and `shell:` names such as `shell:downloads` that go to the matching Mac
  place or say why there is none.
- Breadcrumbs: middle-click opens a segment in a new tab, and segments take file drops by the same rules as the tree.
- Saved workspaces: named sets of tabs to save, reopen, rename and delete.
- Export and import settings as one file, with a preview of what changes. Credentials and machine-specific paths stay out.
- Windows `.lnk` and `.url` files show as shortcuts. Web addresses open after a confirmation showing the real address,
  and Windows programs are never launched.
- Tags section in the navigation pane.
- Mac Services: "Open in Arbor" from other apps and a Services menu on files.
- Column filters: a calendar for dates, and "Filtered" in the address bar with a way to clear it.
- Details view: full drag-to-select from empty space.
- Libraries: create your own, rename and delete them without touching their folders, and "Optimize library for".
- Keyboard: a Mac-style set of file list keys in Folder Options, alongside the Windows-style default.
- Address bar history is remembered between launches and appears in suggestions; Clear history erases it.
- Details: "Wrap long file names" in Folder Options shows up to three lines and keeps the extension readable.
- Files promised by other apps show progress, can be cancelled, say so when the app stops responding, and go through
  the normal copy rules. Nothing counts as received until the app reports it delivered.
- Searching This Mac says which drives and folders were included, which were left out, and why.
- Properties: edit the title, description, rating and date taken inside images, for the fields a type can store without
  re-encoding. The picture itself isn't touched, the original goes to the Trash for Undo, and photos holding data a
  rewrite would lose stay read-only.
- Clipboard: files copied in other apps paste as a copy, and Option-Command-V moves them here.
- Address bar: Windows words such as `control`, `cmd` and `shell:Fonts` offer to open the matching Mac tool, after one
  question. Anything typed after the word is refused, and typed text is never passed on.
- Cloud folders: sync failures show the provider's own message and offer to open its app; accounts are labelled Personal or
  Work/School where the folder name says so; a signed-out provider says so; commands a provider doesn't support explain why.
- Properties: edit the title, artist, album, year, track, genre and comment inside MP3, FLAC and M4A files. The audio isn't
  touched, the original goes to the Trash for Undo, and files that can't be changed safely stay read-only.
- Long and right-to-left languages: layouts, numbers, sizes and paths now adapt, ready for translations.
- Properties: edit the title, subject, authors and keywords inside PDF files, and the same fields plus categories and
  comments inside Word, Excel and PowerPoint files. Signed or encrypted documents stay read-only.

### Removed
- Properties no longer offers Unblock on downloaded files. It still says a file came from another computer, and
  macOS keeps checking the file before it opens.

### Files and reliability
- RAR: encrypted, split and damaged archives now say so instead of extracting wrong or incomplete files.
- Permanent delete stops at a volume mounted inside the folder instead of erasing it.
- Items past the system's path limit are listed, and actions on them explain why they can't run.
- Actions a location doesn't support say why instead of doing nothing.
- A tag or search text with a quote joined to another character can no longer crash a Spotlight search.

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
- Releases are ad-hoc signed, without an Apple Developer ID: macOS asks once, on first launch (see the README).
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
