# Properties and the Details pane

Code: `Sources/Arbor/Features/Properties/` (UI) and `Sources/ArborCore/Properties/` (logic, unit-tested in
`Tests/ArborCoreTests/PropertiesTests.swift`). Registered by `PropertiesFeature.register()` in `Features.swift`.

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-099 | Properties window | implemented | Non-modal window per selection (re-opening brings the same window forward), tabs + OK / Cancel / Apply, Return = OK, Esc = Cancel, ⌃Tab cycles tabs. Opened by ⌥↩ (Alt+Enter), ⌘I, and "Properties" in item, background, tree, "…" and File menus. Scripted: `menu:` logs, `click:file.properties`, snapshots light/dark |
| FE-148 | Details pane | implemented | Replaces the core "details" pane: thumbnail (QuickLook, cancelled on change), name, type, property list, multi-select summary ("3 items selected", size of files, date range), folder summary when nothing is selected, availability (local / iCloud / network) and sharing (iCloud shared). Stale loads dropped by generation token. Scripted log + snapshots |
| FE-150 | General properties | implemented | Name (editable), type with extension, Opens with + Change… (sets the default app for the type), location, Size and Size on disk (allocated blocks), "Contains: N Files, M Folders" scanned in the background with live updates, Stop, cancel on close; Created/Modified/Accessed in Explorer's long format; multi-selection "2 Files, 1 Folder", "All of type …"/"Multiple types", "All in …". Unit + scripted |
| FE-151 | Detailed metadata | implemented | Details tab: Spotlight attributes grouped like Explorer (Description, Origin, Image, Camera, GPS, Media, Audio, Video, Content, File) with Explorer formatting; ImageIO fallback for unindexed images; app bundle info. Unit + scripted |
| FE-152 | Metadata editing/removal | partial | Embedded metadata is read-only (never rewritten in place). "Remove Properties and Personal Information" is offered for JPEG/PNG/HEIC/TIFF only, as Explorer's "Create a copy with all possible properties removed": lossless copy, orientation kept, original untouched. Unit test checks EXIF/GPS gone, pixels and orientation kept |
| FE-153 | Security | implemented | Owner/group/everyone with POSIX bits as Allow check boxes (editable when you own the item; Deny disabled with explanation), ACL entries with Allow/Deny, mode in octal/symbolic, and **effective access tested with faccessat(AT_EACCESS)**. **Edit…** ("Permissions for <name>", `PermissionsEditorSheet.swift`): add (user or group, Allow/Deny, Full control · Modify · Read & execute · Read · Write, inheritance for folders) and remove access-list entries, change the group to one of the owner's groups; each change is shown as a summary to confirm, applied at once, and the last change can be undone (refused if the list changed since). Owner change is explained (administrator only). Unit tests: real ACL via `chmod +a`, Locked file reports no write despite mode 644, add/remove/undo/refusal, inheritance, group change; headless Edit… run with sheet snapshots |
| FE-154 | Sharing / Customize | implemented (boundary for sharing) | Customize: "Optimize this folder for" + "Also apply to all subfolders" persisted per folder (API below); folder icon change/restore via `NSWorkspace.setIcon`. Sharing tab hands off to System Settings › Sharing |
| FE-155 | Previous Versions | implemented | Document versions (`NSFileVersion`) with Open (read-only temp copy), Restore (current kept as a version first, confirmed) and Restore To… (never overwrites; Save panel's replace moves the old item to Trash). Time Machine status and local snapshot dates via `tmutil` (read-only verbs, args array, timeout); "Browse in Time Machine" reveals the item in Finder then opens Time Machine; empty states say so. **Copies in Time Machine backups** (`TimeMachineVersionsView.swift`): the item's distinct copies in `tmutil listbackups` folders, newest first; Open (locked temporary copy; folders open in a new tab) and Restore… (confirmed, then a normal copy job into the item's folder, so Replace / Skip / Keep both is asked). Without Full Disk Access this is explained with a "Privacy Settings…" button. Unit tests on a fake backup tree; headless runs with `ARBOR_TM_BACKUPS` / `ARBOR_TM_ACCESS=denied` |
| FE-156 | Attributes | implemented | Read-only = Locked (`uchg`), Hidden = `UF_HIDDEN` (dot-names shown as always hidden, disabled), with a note explaining the mapping. Advanced… shows archive/index/compress/encrypt as disabled with the real Mac explanation (Time Machine inclusion is read from `tmutil isexcluded`). Unblock removes `com.apple.quarantine` on Apply |
| FE-157 | Signatures / version | implemented | Digital Signatures tab for apps, packages and signed executables (SecStaticCode: status, signer, team ID, identifier, timestamp, certificate chain); app version in General and Details |
| FE-160 | Packages | implemented (props) | Apps/packages get their own tab set, recursive size, version, signature |
| FE-161 | Finder tags/comments | implemented | Editable in the Details tab (own group, labelled "stored by macOS alongside the file, not inside it") and in the Details pane (Save/Cancel). Written as tags (`tagNamesKey`) and the comment xattr |
| FE-245 | Attributes vs effective access | implemented | Read-only never claims to control permissions; Security tab shows tested access and explains Locked separately |
| FE-183 | Drive tools | boundary | Drive General tab: name (renamable when the volume allows), type, file system, used/free/capacity in bytes + short form, purgeable note, pie chart, "Disk Cleanup" → Storage settings. Tools tab: Check → Disk Utility; defrag explained as unnecessary |

Scripted steps added (TESTING.md style): `propertiesof:<path>`, `proptab:<title>`, `proplog:<file>`, `propsnapshot:<png>`,
`propsheetsnapshot:<png>`, `propbutton:<title>`, `propset:<field>=<value>` (name, locked, hidden, mode, tags, comment,
unblock, template=Name:0|1), `propexternal:comment|hidden|name=…` (simulates another app), `propprincipal:<n>`,
`propremovemeta`, `propapply`, `propok`, `propcancel`, `paneedit:tags=…|comment=…|save`. The window logger adds the
Details pane's contents and the number of open Properties windows.

## Folder template API (for Folder Options / views)

`FolderTemplateStore(defaults: Prefs.store)` in ArborCore. Key `folderTemplates`: dictionary keyed by the standardized
folder path (no trailing slash) → `["template": "generalItems|documents|pictures|music|videos", "subfolders": Bool]`.
`effectiveTemplate(for:)` returns the folder's choice, else the nearest ancestor's with subfolders on, else nil (not
chosen). After a change the app posts `PropertiesFeature.folderTemplateChanged` (`"ArborFolderTemplateChanged"`, object =
folder URL) and `Prefs.changed` with `key == "folderTemplates"`. Choosing "General items" without subfolders clears the entry.

## Decisions

- **DEC-properties-1** Read-only maps to Finder's Locked (`uchg`), Hidden to `UF_HIDDEN`. Locked items are temporarily
  unlocked to apply other edits and re-locked (also after a failure).
- **DEC-properties-2** Apply writes only changed fields; before writing it re-reads the item. Fields the user didn't
  touch follow the disk silently; a field the user edited that another app changed to a different value triggers
  "Apply Anyway / Cancel". Missing items stop Apply. Refreshed again whenever the window becomes key.
- **DEC-properties-3** Security edits POSIX bits (with OK/Apply) and, through Edit…, access-list entries and the group,
  only for the owner (ACL changes apply at once after a confirmation summary, with undo of the last change). A Deny
  entry never removes readattr/readsecurity/writesecurity/chown, so the owner can't lock themselves out of the list.
  Owner change isn't offered (needs root). Access is shown as tested, never inferred.
- **DEC-properties-4** Embedded metadata is never edited in place; removal only creates a cleaned copy of images.
- **DEC-properties-5** Finder comments are written to the `com.apple.metadata:kMDItemFinderComment` attribute (what
  Spotlight reads). No AppleScript to Finder (it would need Automation permission).
- **DEC-properties-6** Previous Versions = NSFileVersion document versions + Time Machine status; per-file Time Machine
  browsing is handed to the Time Machine app. Nothing is listed that isn't real.
- **DEC-properties-7** Sizes use Explorer's adaptive format (1024-based, 3 significant digits, truncated, unit switch at
  1000: "0.99 MB"); Properties appends exact bytes. Symlinks are counted, not followed; hard links counted per entry.
- **DEC-properties-8** Alerts are sheets on the Properties window (scripts can answer them; headless keeps them invisible).
- **DEC-properties-9** Opens with › Change… sets the default app for the file's type (all files of that type), like
  Windows; unknown types change only that file.

## Known gaps

- Finder's Get Info may show an older comment cached in `.DS_Store` (only Finder writes that file).
- Multi-selection shows the General tab only. Tabs don't wrap to a second row; a window with 5 tabs is full width.
- Volume rename of the startup disk may be refused by macOS (error is shown). Time Machine backups (as opposed to local
  snapshots) can't be listed without Full Disk Access (the tab says so); local snapshots are counted, not browsed
  (mounting them needs root). Backup copies were checked on a fake backup tree, not a real Time Machine disk.
- Writing embedded properties (title, rating, authors) isn't supported. Folder "Read-only" doesn't mimic Windows'
  "only applies to files in folder" tri-state; it locks the folder itself, as explained in the window.
- Context-menu "Properties" for the Home/This Mac pages' own items depends on those pages exposing a selection.
