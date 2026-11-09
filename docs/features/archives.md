# Archives and disk images (FE-163 – FE-173)

Code: `Sources/ArborCore/Archives/` (logic, unit-tested in `Tests/ArborCoreTests/ArchiveTests.swift`) and
`Sources/Arbor/Features/Archives/` (provider, commands, wizard, jobs, drag and drop). Registered by
`ArchiveFeature.register()` in the "archives" slot.

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-163 | ZIP browsing and extraction | **Implemented.** `.zip` opens as a folder (`.archive(file, inner)`); subfolders, breadcrumb `Archive.zip > folder` with chevrons listing folders inside the archive, Up leaves to the containing folder with the archive selected. Explorer's ZIP columns appear only inside ZIPs: Compressed size, Password protected, Ratio. "Extract all" in the command bar (archive selected or inside one), "Extract All…" in the item and background menus and File menu. Wizard: "Select a Destination and Extract Files", "Files will be extracted to this folder:", Browse…, "Show extracted files when complete" (opens the folder in a new tab). Individual members: Open (read-only temporary copy, status bar says so), Open With ▸, Copy (extracts to a temporary folder and puts the files on the clipboard, so Paste anywhere uses the normal conflict rules), drag out (file promise, extracted only when dropped) | Unit tests; headless runs: browse, wizard, extract, copy + paste, promise write, open member, nested ZIP; snapshots light and dark |
| FE-164 | ZIP creation | **Implemented.** Compress to ▸ ZIP File, Send to ▸ Compressed (zipped) folder, New ▸ Compressed (zipped) Folder (22-byte empty ZIP). Named after the first selected item (`report.docx` → `report.zip`, then `report (2).zip`), created next to it, then inline rename. Cancellable from the status bar. Undo moves the new archive to the Trash only if it hasn't changed | Unit tests (naming, round trip); headless runs (zip, 7z, tar, rename field, undo) |
| FE-165 | Modify existing archives | **Boundary (read-only).** Adding, deleting or renaming inside an archive is not offered; the status bar says the archive is read-only on entry, and Cut/Rename/Delete/Paste/New are disabled there | Headless log (command states) |
| FE-166 | 7z, TAR and compressed TAR | **Implemented.** Browse and extract: 7z, tar, tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz, tar.zst/tzst, cpio. Create: 7z and TAR (Compress to ▸) | Unit tests (create + list + extract 7z/tar); headless runs |
| FE-167 | RAR extraction | **Partial.** RAR (v4/v5) is read through the system libarchive like the other formats; never created. Not tested: no RAR fixture can be produced with built-in tools | — |
| FE-168 | Compression options | **Implemented.** Compress to ▸ Additional options opens "Create archive": Destination (Browse…), Archive name, Archive format (ZIP, 7z, TAR, TAR + gzip/BZip2/xz, single-file gzip/BZip2/xz), Compression method (ZIP: Deflate/Store; 7z: LZMA2/LZMA/BZip2/Deflate/Store), Compression level (Fastest/Normal/Maximum), "Include hidden files and folders". Written by bsdtar with `--options`; never overwrites (free name). No Zstandard (the system libarchive lacks it). Code: `ArborCore/Archives/ArchiveCreateOptions.swift`, `Features/FileOperations/CompressOptionsDialog.swift` | Unit tests (arguments, round trip per format with and without hidden items, store vs maximum, single-file gzip); headless runs, snapshots light + dark |
| FE-169 | Encrypted archives | **Boundary, like Windows.** Encrypted ZIP members are detected (central directory flag) and shown with Password protected = Yes; opening or extracting them is refused with an explanation. Other formats report bsdtar's passphrase error | Unit test (flag) |
| FE-170 | Archive safety | **Implemented.** See "Safety" below | Unit tests (sanitizer, planner, verifier, hostile ZIP end to end); headless hostile ZIP and zip-bomb runs |
| FE-171 | Mount and eject ISO | **Implemented.** "Mount" for .iso/.dmg/.img/.cdr/.sparseimage/.sparsebundle/.toast (`hdiutil attach -plist`, argument array) then opens the volume; errors are shown. Double-clicking an ISO mounts it like Explorer; if macOS can't mount it, its contents are browsed read-only instead. DMG/IMG double-click goes to macOS (DiskImageMounter handles licenses and passwords). Eject is the core command | Headless run: ISO mounted and opened, broken DMG error; volume detached afterwards |
| FE-172 | Optical burn and disc tools | **Not done.** No burn command (no drive to gate on here) | — |
| FE-173 | Metadata portability | **Implemented as documented behavior.** One item → ZIP via `ditto --sequesterRsrc`, which keeps Mac metadata (resource forks, extended attributes, Finder tags) in `__MACOSX` like Finder's Compress; extraction folds it back (libarchive's mac-ext). Several items, 7z and TAR are written by bsdtar without AppleDouble `._` members, so tags, resource forks and extended attributes are **not** kept; Unix permissions are. Extraction does not restore owners, file flags or ACLs; set-ID bits are cleared; folders stay owner-writable. A downloaded archive's quarantine attribute is copied to every extracted item | Unit tests (verifier, quarantine); listing checks |

## Safety (FE-170)

1. **Names**: entries with `..`, absolute paths (`/x`, `C:\x`), empty names, NUL, names over 1024 bytes or components over 255 are never extracted and are hidden in the listing (the status bar names the reason and how many). Listing rows bsdtar prints that Arbor can't read, including link rows whose name or target contains the separator, are kept as unnamed stand-ins: hidden, rejected ("couldn't read its line"), and they force file-by-file extraction. Listings over 256 MB of output, 2,000,000 entries or 4,000,000 implied paths are refused ("The archive lists more items than Arbor can show"); ZIP64 offsets and sizes are bounds-checked and declared sizes capped at 2 TiB each.
2. **Links**: symlinks must resolve inside the extracted folder (relative to the folder being extracted, not just the staging root), following other links before `..` as the file system does; loops and chains over 32 links deep count as escaping. The planner matches names with Unicode case folding (so "ſ" is "s", like APFS); the verifier reads every link on disk, so the volume's own name matching decides. Hard links must point at another safe member. Members stored "inside" a link or file, devices, FIFOs, sockets and members of unknown type are rejected; names that differ only by case keep the first.
3. **Plan, then extract**: bsdtar runs with literal include patterns (whole subtrees when nothing in scope is rejected, otherwise file by file), `--no-same-owner --no-fflags --no-acls`, and bsdtar's own refusal of `..`/absolute/through-symlink writes as a second line of defense.
4. **Staging**: extraction goes into a temporary folder on the destination's volume (`itemReplacementDirectory`), is verified there (a walk with `lstat` removes escaping links and special files), then moved in with `FileTransfer` and the app's conflict prompt (Keep Both default, Replace = Trash). Nothing is overwritten without a decision.
5. **Expansion**: before writing, declared size vs free space (minus 256 MB) and a hard 1 TiB cap; ≥ 512 MB at ≥ 200× its size asks "Extract Anyway" (default Cancel). While extracting, a watchdog stops the tool if it writes 10% (min 64 MB) more than declared or the disk nearly fills, and the verifier rejects the result if actual bytes exceed that limit.
6. Every tool runs through `Process` with an argument array and stdin from `/dev/null`; never a shell string.

## Decisions

| ID | Decision | Why |
|---|---|---|
| DEC-archives-1 | Use the system `/usr/bin/bsdtar` (libarchive 3.7) through `Process`; parse `-tv --numeric-owner` output in `en_US.UTF-8` | libarchive headers aren't in the SDK; `--format=mtree` listing was rejected because it normalizes and drops hostile names (and crashed on one) |
| DEC-archives-2 | ZIP listings come from Arbor's own central-directory reader | Gives compressed size, encryption flag, ZIP64, Unicode names without reading data; bsdtar's names are still used for extraction patterns |
| DEC-archives-3 | Archives are read-only, including ZIP | Safe in-place rewriting needs a full rewrite-and-replace path; not worth the risk in this pass |
| DEC-archives-4 | `__MACOSX` members are hidden in ZIP listings | They hold Mac metadata that extraction folds back into the files, as Finder does |
| DEC-archives-5 | "Show extracted files when complete" opens the folder in a new tab (Explorer opens a new window) | Keeps one window; tabs are Arbor's default for new folders |
| DEC-archives-6 | Opened members are read-only copies in a per-launch temporary folder; folders of earlier launches are removed at next use | Matches Explorer's temporary copy; read-only makes apps offer "Save As" instead of silently losing edits |
| DEC-archives-7 | Single-item ZIPs use `ditto` (Finder-compatible, keeps metadata); several items, 7z and TAR use bsdtar with `COPYFILE_DISABLE=1` | `ditto -c` takes one source; portable archives without `._` files for other platforms |
| DEC-archives-8 | Double-click on ISO mounts (Explorer behavior) with archive browsing as fallback; DMG/IMG open with macOS | DiskImageMounter handles license agreements and passwords that `hdiutil` can't ask for |
| DEC-archives-9 | Zip-bomb thresholds: confirm at ≥ 512 MB and ≥ 200×; refuse > 1 TiB, or when space is short; stop when actual writes exceed declared + max(10%, 64 MB) | Legitimate archives rarely exceed 200× at that size; lying headers are always hostile |
| DEC-archives-10 | Progress shows in the status bar (entries extracted / files compressed), cancellable with its ✕ | Uses the app's existing job surface; no fabricated byte ETA |
| DEC-archives-11 | Type column inside archives comes from the extension (UTType) and is capitalized | The member isn't on disk, so the Finder "kind" isn't available (".txt" shows "Text", not "Plain Text Document") |

## Shared-file changes (all additive)

- `Features.swift`: `ArchiveFeature.register()` in the archives slot.
- Uses main's hooks: `DetailsColumns` (layout `archive.zip`: Name, Type, Compressed size, Password protected, Size, Ratio, Date modified, restored on leaving), `InteractionHooks.openFile` (chained in front of the shortcut handler after registration finishes, since it is a single slot), Send to ▸ runs `archive.compress.zip`, New ▸ uses `MenuSection.newFileTypes` order 20.
- New `Support/ItemHooks.swift` (drag and drop only): drag writers (archive members become file promises) and drop handlers for drops without file URLs (file promises are received into staging, then copied in with the conflict rules). Called from `DetailsViewController` (pasteboard writer, validate/accept drop, dragged types) and `IconViews/ItemGridView` (drag items, drop operation, perform drop, dragged types): one or two lines each.
- `OperationCenter`: `Activity` (non-transfer jobs in the status bar, cancelled by Cancel and on quit).
- `IconProvider.fileIcon`: items not on disk get their type's icon.
- `ArchiveFeature.adaptCoreCommands` adjusts commands at runtime inside archives: Copy extracts; Share, Terminal unavailable/disabled; Pin, Add to Favorites, Send to hidden; Show in Finder reveals the archive; Open With extracts first.

## Script steps

`archivesheet:/out.png` (render the Extract All sheet), `sheetpath:/dest`, `sheetshow:on|off`,
`promise:<member>:/folder` (perform a drag-out file promise), `pasteinto:/folder`. The `log:` step adds an
`archive:` line (visible columns and their values for the first file, running activities, last alert,
last extraction/mount, clipboard). Headless runs record archive alerts instead of showing them, and the
zip-bomb confirmation takes the safe answer (Cancel).

## Known gaps

- Modifying archives (FE-165), burning (FE-172).
- RAR untested (no fixture). Non-ZIP dates are minute-precise (bsdtar's listing).
- Promise drops are described in [promised-files.md](promised-files.md); the tab strip does not accept them. Right-button drags (ItemActions' DragPolish) skip archive members.
- Properties on an archive member shows what the Properties feature can find for a path that isn't on disk. Drag-out to Finder was verified through the promise code path, not an interactive drag.
- Quick Look and the Preview/Details panes don't show archive members (they have no file on disk).
- Conflict prompts from extraction are the core sheet; in headless runs they would appear on screen, so the scripted runs avoid conflicts.
