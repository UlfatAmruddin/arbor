# Trash (Explorer's Recycle Bin)

Spec: spec §12.4, FE-077, FE-090 (Trash side). Reference: windows11-reference.md §3.4, §9.5.
Code: `Sources/Arbor/Features/Trash/`, `Sources/ArborCore/TrashJournal.swift`, `Sources/ArborCore/TrashRestore.swift`.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-077 | Trash location: nav pane entry (after Network, empty/full icon), Go ▸ Trash, address keywords "Trash"/"Recycle Bin", items from `~/.Trash` and every local volume's Trash | Implemented | Headless run (light/dark snapshots), `log` |
| FE-077 | Details columns Name · Original Location · Date Deleted · Size · Item type · Date Modified | Implemented (columns not sortable, see gaps) | Snapshots; `trash:` logger prints the column set |
| FE-077 | Original Location and Date Deleted from Arbor's trash journal; "Unknown" otherwise | Implemented | Unit tests (`TrashJournalTests`), headless run with a Finder-style item |
| FE-077 | Restore the selected items / Restore all items (command bar), Restore (item menu) | Implemented | Headless: restore recreated a deleted parent folder; conflict prompt → Keep Both gave `a (2).txt` |
| FE-077 | Empty Trash (command bar, background and tree menus, File menu, ⇧⌘⌫) with Explorer's "Are you sure you want to permanently delete these N items?" | Implemented | Headless: sheet text logged, Yes emptied the test Trash |
| FE-090 | Delete in the Trash = permanent delete with "Are you sure you want to permanently delete this file?" (Yes/No, No is default) | Implemented | Headless: sheet text logged, item removed |
| FE-077 | Properties (item: original location, date deleted, size measured on request; location: per-volume Trash usage and free space) | Implemented | Built; manual reading of code paths (alerts are modal, not snapshotted) |
| FE-077 | Full Disk Access boundary: honest page with "Open Full Disk Access Settings", "Try Again", "Show the Trash in Finder" | Implemented | Headless with `ARBOR_TEST_TRASH_DENIED=1` (snapshot) |
| — | Undo of Restore (⌘Z moves the items back to the Trash; redo restores) | Implemented | Code path reuses `OperationCenter.registerUndoTrash` |
| — | Recycle Bin settings (max size, "Don't move files to the Recycle Bin") | Boundary | macOS has no such per-volume settings; Properties says so and points to Finder's 30-day option |

## Decisions

- **DEC-trash-1** Mac name "Trash" for the location and commands ("Empty Trash"), Explorer phrasing elsewhere ("Restore the selected items", "Restore all items", "Original Location", "Date Deleted", "Item type", confirmation questions). Same pattern as "This PC" → "This Mac".
- **DEC-trash-2** Original location is known only for items Arbor trashed: `SystemTrash.trash` notifies observers and the journal (`~/Library/Application Support/Arbor/TrashJournal.json`; headless: next to the test Trash) stores trashed path → original path, date, inode/device. A record is only used while the inode still matches, so a different item at the same Trash path never inherits it. Finder's private Put Back data (.DS_Store) is not parsed (spec §12.4).
- **DEC-trash-3** Date Deleted for items Arbor didn't trash uses the public `addedToDirectoryDate` (the moment the item entered the Trash folder); "Unknown" only if that is missing too.
- **DEC-trash-4** The Name column shows the original name (as Windows does) when it is known and unique in the listing, else the name inside the Trash; names stay unique because rows are identified by name.
- **DEC-trash-5** Restore conflicts offer Keep Both (default, "name (2).ext", DEC-012 naming) / Skip / Cancel with "Do this for all current items"; never Replace. A missing original folder chain is recreated, like Windows.
- **DEC-trash-6** Permanent-delete confirmations use Explorer's Yes/No wording but make **No** the default button (Return never destroys), consistent with the core permanent-delete dialog.
- **DEC-trash-7** In the Trash, Delete and Shift+Delete delete permanently after confirmation (Explorer behavior); Cut is enabled so Paste moves an item out (like dragging it out). Rename and New are disabled.
- **DEC-trash-8** Network volumes are not scanned for a Trash folder (no usable per-user Trash and the query can stall).
- **DEC-trash-9** Headless runs (`ARBOR_HEADLESS`) only ever show `SystemTrash.testDirectory`.

## Testing

```bash
ROOT=$(mktemp -d); FX="$ROOT/fixture"; mkdir -p "$FX/Docs"; echo hi > "$FX/Docs/a.txt"
ARBOR_HEADLESS=1 ARBOR_APPEARANCE=light ARBOR_TEST_TRASH="$ROOT/trash" \
ARBOR_SCRIPT="wait:1;location:$FX/Docs;select:a.txt;click:file.trash;event;wait:1;location:trash;wait:1.5;log:$ROOT/s.txt;snapshot:$ROOT/t.png;select:a.txt;click:trash.restoreSelected;wait:1.5;click:trash.empty;wait:1;log:$ROOT/s.txt;button:Yes;wait:1;quit" \
  build/Arbor.app/Contents/MacOS/Arbor "$FX"
```
Extra environment: `ARBOR_TEST_TRASH_DENIED=1` simulates macOS refusing to list the Trash.
Extra script steps (registered by the feature): `sheetshot:/path.png` (draws the attached sheet); the `log` step gains
`trash:` (layout, columns, each row's original location and date) and `sheet text:` (the open alert's texts and buttons).
Command ids: `trash.empty`, `trash.restoreSelected`, `trash.restoreAll`, `trash.itemProperties`, `trash.properties`.

## Known gaps

- Original Location / Date Deleted columns can't be sorted: `SortKey` (ArborCore, shared) has no extension point.
- Items deleted in Finder show "Unknown" origin and can't be restored by Arbor (no public API for Put Back data).
- Reading `~/.Trash` needs Full Disk Access on recent macOS; without it the page explains and links to Settings.
- Folder sizes in the Size column are blank (no recursive scan); Properties measures on request.
- Dropping files onto the Trash node/view to delete them isn't implemented.
- The Delete button's tooltip still says "Delete (move to the Trash)" while in the Trash (tooltips are fixed at command-bar build time).
