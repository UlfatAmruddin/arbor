# Properties and the Details pane

Code: `Sources/Arbor/Features/Properties/` (UI) and `Sources/ArborCore/Properties/` (logic, unit-tested in
`Tests/ArborCoreTests/PropertiesTests.swift`). Registered by `PropertiesFeature.register()` in `Features.swift`.

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-099 | Properties window | implemented | Non-modal window per selection (re-opening brings the same window forward), tabs + OK / Cancel / Apply, Return = OK, Esc = Cancel, ⌃Tab cycles tabs. Opened by ⌥↩ (Alt+Enter), ⌘I, and "Properties" in item, background, tree, "…" and File menus. Scripted: `menu:` logs, `click:file.properties`, snapshots light/dark |
| FE-148 | Details pane | implemented | Replaces the core "details" pane: large preview (`ThumbnailPolicy.panePreview`: QuickLook thumbnail for pictures and videos, a page with a hairline border for PDF, office, iWork and e-book documents, the type icon for text, source code, CSV, JSON, Markdown and logs, whose thumbnail was a nearly blank page; "Always show icons" shows icons; cancelled on change; unit tests `PanePreviewTests`, `log` line `preview:`, snapshots light/dark), name, type, property list, multi-select summary ("3 items selected", size of files, date range), folder summary when nothing is selected, availability (local / iCloud / network) and sharing (iCloud shared). Stale loads dropped by generation token. Scripted log + snapshots |
| FE-150 | General properties | implemented | Name (editable), type with extension, Opens with + Change… (sets the default app for the type), location, Size and Size on disk (allocated blocks), "Contains: N Files, M Folders" scanned in the background with live updates, Stop, cancel on close; Created/Modified/Accessed in Explorer's long format; multi-selection "2 Files, 1 Folder", "All of type …"/"Multiple types", "All in …". Unit + scripted |
| FE-151 | Detailed metadata | implemented | Details tab: Spotlight attributes grouped like Explorer (Description, Origin, Image, Camera, GPS, Media, Audio, Video, Content, File) with Explorer formatting; ImageIO fallback for unindexed images; app bundle info. Unit + scripted |
| FE-152 | Metadata editing/removal | partial | Details tab edits title, description, rating and date taken inside images, title, artist, album, year, track, genre and comment inside MP3, FLAC and M4A files, title, subject, authors and keywords inside PDFs, and those plus categories and comments inside Word, Excel and PowerPoint documents, per type as audited below; other embedded fields and other file kinds stay read-only. Written by lossless copy, verified, swapped in atomically; the previous version goes to the Trash and Undo brings it back. Unit: `EmbeddedMetadataTests` (generated images, one round trip per type, refusals, hostile values, undo) and `AudioMetadataTests`, `AudioMetadataSafetyTests` (hand-built and afconvert audio, hostile sizes, truncation, a verifier that refuses tampered files, a memory bound while streaming) and `DocumentMetadataTests`, `DocumentMetadataSafetyTests` (hand-built PDFs with tables, cross-reference and object streams, earlier updates, linearization, XMP and Quartz output; Office packages built by hand and by `zip`; hostile offsets, truncation, refusals with their reasons, verifiers that refuse tampered files, edit then undo, a memory bound while streaming). Scripted: `behavior-checks.sh embedded-metadata`, `behavior-checks.sh audio-metadata`, `behavior-checks.sh document-metadata`. "Remove Properties and Personal Information" is offered for JPEG/PNG/HEIC/TIFF only, as Explorer's "Create a copy with all possible properties removed": lossless copy, orientation kept, original untouched. Unit test checks EXIF/GPS gone, pixels and orientation kept |
| FE-153 | Security | implemented | Owner/group/everyone with POSIX bits as Allow check boxes (editable when you own the item; Deny disabled with explanation), ACL entries with Allow/Deny, mode in octal/symbolic, and **effective access tested with faccessat(AT_EACCESS)**. **Edit…** ("Permissions for <name>", `PermissionsEditorSheet.swift`): add (user or group, Allow/Deny, Full control · Modify · Read & execute · Read · Write, inheritance for folders) and remove access-list entries, change the group to one of the owner's groups; each change is shown as a summary to confirm, applied at once, and the last change can be undone (refused if the list changed since). Owner change is explained (administrator only). Unit tests: real ACL via `chmod +a`, Locked file reports no write despite mode 644, add/remove/undo/refusal, inheritance, group change; headless Edit… run with sheet snapshots |
| FE-154 | Sharing / Customize | implemented (boundary for sharing) | Customize: "Optimize this folder for" + "Also apply to all subfolders" persisted per folder (API below); folder icon change/restore via `NSWorkspace.setIcon`. Sharing tab hands off to System Settings › Sharing |
| FE-155 | Previous Versions | implemented | Document versions (`NSFileVersion`) with Open (read-only temp copy, removed when the app showing it quits), Restore (current kept as a version first, confirmed) and Restore To… (never overwrites; Save panel's replace moves the old item to Trash). Time Machine status and local snapshot dates via `tmutil` (read-only verbs, args array, timeout); "Browse in Time Machine" reveals the item in Finder then opens Time Machine; empty states say so. **Copies in Time Machine backups** (`TimeMachineVersionsView.swift`): the item's distinct copies in `tmutil listbackups` folders, newest first; Open (read-only temporary copy, removed when the app showing it quits; folders open in a new tab) and Restore… (confirmed, then a normal copy job into the item's folder, so Replace / Skip / Keep both is asked). Without Full Disk Access this is explained with a "Privacy Settings…" button. Unit tests on a fake backup tree; headless runs with `ARBOR_TM_BACKUPS` / `ARBOR_TM_ACCESS=denied` |
| FE-156 | Attributes | implemented | Read-only = Locked (`uchg`), Hidden = `UF_HIDDEN` (dot-names shown as always hidden, disabled), with a note explaining the mapping. Advanced… shows archive/index/compress/encrypt as disabled with the real Mac explanation (Time Machine inclusion is read from `tmutil isexcluded`). |
| FE-157 | Signatures / version | implemented | Digital Signatures tab for apps, packages and signed executables (SecStaticCode: status, signer, team ID, identifier, timestamp, certificate chain); app version in General and Details. "OK" only when the chain is anchored at Apple (Apple, Mac App Store, Developer ID, notarized), checked offline for every architecture slice; ad hoc code shows "Signed locally (ad hoc)" and the signer "Ad hoc (no certificate)", and self-signed code shows the signer as "Unknown developer (unverified name: …)", both with no team ID; when the signer isn't identified by an Apple-issued certificate (ad hoc, self-signed or invalid) and there is no secure timestamp, the signing time is labelled "stated by the signer, not verified". Unit tests `trustNeedsAnAppleAnchor`, `selfSignedIsNotPresentedAsOK`, `adHocSignatureIsNotVerified`, `universalBinaryWithAdHocSliceIsNotVerified`, `selfStatedSigningTimeIsLabelled` |
| FE-158 | Downloaded files | implemented | The General tab says a file came from another computer. The quarantine flag is never removed, so macOS still checks the file (DEC-025) |
| FE-160 | Packages | implemented (props) | Apps/packages get their own tab set, recursive size, version, signature |
| FE-161 | Finder tags/comments | implemented | Editable in the Details tab (own group, labelled "stored by macOS alongside the file, not inside it") and in the Details pane (Save/Cancel). Written as tags (`tagNamesKey`) and the comment xattr |
| FE-245 | Attributes vs effective access | implemented | Read-only never claims to control permissions; Security tab shows tested access and explains Locked separately |
| FE-183 | Drive tools | boundary | Drive General tab: name (renamable when the volume allows), type, file system, used/free/capacity in bytes + short form, purgeable note, pie chart, "Disk Cleanup" → Storage settings. Tools tab: Check → Disk Utility; defrag explained as unnecessary |

Scripted steps added (TESTING.md style): `propertiesof:<path>`, `proptab:<title>`, `proplog:<file>`, `propsnapshot:<png>`,
`propsheetsnapshot:<png>`, `propbutton:<title>`, `propset:<field>=<value>` (name, locked, hidden, mode, tags, comment,
template=Name:0|1), `propexternal:comment|hidden|name=…` (simulates another app), `propprincipal:<n>`,
`propremovemeta`, `propapply`, `propok`, `propcancel`, `paneedit:tags=…|comment=…|save`, `propembedded:title|subject|author|keywords|category|description|rating|date|artist|album|year|track|genre|comment=<value>`
and `propembedded:touch=1` (another app changed the file). The window logger adds the
Details pane's contents and the number of open Properties windows.

## Editing properties inside images (FE-152)

Code: `ArborCore/Properties/EmbeddedMetadata.swift` (fields, audit table, reading, validation), `EmbeddedMetadataEditor.swift`
(the write), `EmbeddedMetadataVerifier.swift` (the proof), `Features/Properties/EmbeddedMetadataSection.swift` (the rows).

**What each type can store**, from auditing ImageIO's lossless copy (`CGImageDestinationCopyImageSource`, macOS 26) on every
type it can write. "Yes" means an edit is applied to the XMP, IPTC and Exif copies alike and reads back; a field not listed for a
type is read-only because the copy leaves an older value behind or the type has no lossless copy at all.

| Type | Title | Description | Rating | Date taken |
|---|---|---|---|---|
| JPEG | yes | yes | yes | yes (removable) |
| HEIC | yes | no: the Exif and TIFF copies aren't rewritten | yes | no: same reason |
| TIFF | yes | no: the edit is not applied | yes | yes (can't be removed) |
| PNG | no | no | no | no: edits are dropped when the file already has XMP |
| GIF, BMP, WebP, JPEG 2000, AVIF, TGA, EXR, PDF, RAW | no lossless copy, or ImageIO can't write the type at all | | | |

A cleared title is written empty and a cleared rating as 0, because HEIC and TIFF don't honour removing a tag.

**Offered per field, and only when true.** A field is not offered (shown read-only if it has a value) when a rewrite would lose or
can't reproduce it: titles in several languages (the rewrite keeps only one), values with control or direction-override characters,
text over 1,024 characters (title) or 8,192 (description), a rating outside 0 to 5, a date Exif can't parse.
The whole file stays read-only, with the reason shown, when it is over 512 MB or 256 megapixels (64 frames at most), locked,
hard-linked (replacing it would split the names), unwritable, on a volume without atomic exchange (`VOL_CAP_INT_RENAME_SWAP`),
or a JPEG holding data ImageIO's copy drops: a camera MakerNote (every manufacturer tried, Apple included) or APP1 data other than the main Exif and XMP, such as Extended XMP or FLIR.

**Saving** reads the original through a held no-follow descriptor, bounded, re-checks its stamp (device, inode, size, modification
date), writes a copy into an `itemReplacementDirectory` on the same volume, verifies, copies permissions, owner, access list, flags, tags, comments and the creation date
onto it, and exchanges the two with `renamex_np(RENAME_SWAP)`. The stamps are checked again after the exchange, which is undone on a mismatch.
If another app moved or replaced the file in that moment, the exchange isn't undone over its file: the version set aside goes to the Trash (or, if that fails, stays in the staging folder), and the message says where it is.

**Verification** refuses unless: same type and frame count; every frame decodes identically (hashed, one frame at a time); depth, matte and gain-map
data are identical; the edited fields read back and no other field moved; every other ImageIO property and XMP tag survives; and, for JPEG, every segment that
isn't JFIF, the first Exif, the first main XMP, the Photoshop segment or the multi-picture index, and everything from the first scan to the end of the file, is byte-identical, and every IPTC dataset is still there with its value, bar those the edit rewrites (`IPTCStructure`: 2:5 for a title, 2:120 for a description, 2:55 and 2:60 for a date) and the character-set and version markers ImageIO always writes itself.
Segments are told apart by signature, not marker. `ExifStructure` also walks the original's Exif directories, because ImageIO doesn't show everything it drops: the
MakerNote must be byte-identical and every tag in the main, Exif and GPS directories must still be there, so a file with, say, Windows' XP title tags is refused. Padding and the interoperability directory are exempt.

**Undo** (Edit ▸ Undo, `OperationCenter`'s stack) exchanges the Trash copy back; Redo exchanges again. Each refuses if either file changed since (FE-129).

## Writable properties per file type (FE-152)

The audit behind what the Details tab offers. "Writable" means the change is verified and every other byte is proven intact; anything else is read-only, and a file of a writable type can still be refused for one of the reasons below.

| Type | Writable inside the file | Why the rest isn't |
|---|---|---|
| JPEG | Title, description, rating, date taken | ImageIO's lossless copy, audited above. Files holding data it drops stay read-only |
| HEIC | Title, rating | The copy leaves the Exif and TIFF description and date behind |
| TIFF | Title, rating, date taken (can't be removed) | The description edit isn't applied |
| PNG, GIF, BMP, WebP, JPEG 2000, AVIF, TGA, EXR, RAW | Nothing | ImageIO has no lossless copy for them, or drops edits |
| MP3 with an ID3v2.3 or 2.4 tag | Title, artist, album, year, track, genre, comment | See below for what makes a tag read-only. MP3 without an ID3v2 tag isn't offered: there is no tag to edit, and adding one is a separate decision |
| FLAC with a VORBIS_COMMENT block | Title, artist, album, year, track, genre, comment | A file without exactly one such block stays read-only |
| M4A (MPEG-4 audio with an iTunes-style metadata list) | Title, artist, album, year, track, genre, comment | Only when the audio doesn't move, see below |
| WAV, AIFF | Nothing | Their tags (RIFF INFO, ID3 chunks) have no audited lossless writer here yet |
| MP4 and MOV video | Nothing | Video atoms are not audited; a file with a video track is never treated as M4A |
| PDF | Title, subject, authors, keywords | Written as an incremental update, see below. Encrypted, signed, damaged or hybrid-reference files stay read-only, as do files whose XMP can't be updated safely |
| Word, Excel, PowerPoint (`docx`, `xlsx`, `pptx` and the macro-enabled `docm`, `xlsm`, `pptm`) | Title, subject, authors, keywords, categories, comments | Only `docProps/core.xml` changes, see below. Other core properties (last modified by, revision, dates) aren't offered: Office maintains them itself |
| Legacy `doc`, `xls`, `ppt` | Nothing | Compound files with their own property streams; no audited writer here |
| Plain text | Nothing | Has no place inside the file for properties; Finder tags and comments are alongside it |

## Editing properties inside audio files (FE-152)

Code: `EmbeddedFormat.swift` (the one protocol a format implements: what it can edit, read fields, produce new bytes, verify, and `EmbeddedFormats.all`, the list), `ImageEmbeddedFormat.swift`,
`TagRegionFormat.swift` (formats whose metadata sits in one region: parsing and streaming shared by audio), `TagRegionVerifier.swift` (the proof), `ID3Format.swift`, `FLACFormat.swift`, `M4AFormat.swift`. A later format is one new file and one line in that list.

**Same safety model as images.** Written beside the original in an `itemReplacementDirectory`, verified, attributes carried over, exchanged with `renamex_np(RENAME_SWAP)`, the original to the Trash for Undo, and refused if the file changed meanwhile.

**Streaming.** No format holds a file in memory: the parsers read headers through `EmbeddedFileReader` (checked offsets, at most 17 MiB in one read, used only for a whole FLAC comment block), pictures and other kept frames are copied by range, and the audio payload is streamed in 1 MiB chunks, both when writing and when comparing. Files up to 16 GiB are editable. Online-only files aren't opened at all.

**MP3.** Only `TIT2`, `TPE1`, `TALB`, `TYER` (2.3) or `TDRC` (2.4), `TRCK`, `TCON` and the `COMM` frame with no description (iTunes keeps its own data in described ones) change. Every other frame stays byte for byte, in order, as do the audio and any ID3v1 trailer. New text is ASCII or UTF-16 in 2.3 and UTF-8 in 2.4. A tag keeps its size when the new frames fit, so the audio doesn't move at all. A file counts as an MP3 only when MPEG audio follows a well-formed tag, so text, FLAC or AAC that merely begins with `ID3` isn't offered. The whole file is read-only, with the reason shown, for: an unsynchronised tag, an extended header, a footer, any compressed or encrypted frame (or 2.4's per-frame unsynchronisation and length prefix), more than one tag (also a `SEEK` frame or a trailing `3DI`), other ID3 versions, or a tag that can't be walked exactly. A single field stays read-only for a repeated frame, several values, a frame marked read-only or grouped, undecodable text, a genre mixing codes with text, or a year stored in the other version's frame.

**FLAC.** Only comments for the seven fields change (`TITLE`, `ARTIST`, `ALBUM`, `DATE` or `YEAR`, `TRACKNUMBER`, `GENRE`, `COMMENT` or `DESCRIPTION`), keeping each key's own spelling. Other comments, the vendor string, every other block and all frames are kept. Repeated keys are multiple values and stay read-only.

**M4A.** Only items in `moov/udta/meta/ilst` change, and unknown atoms are kept. The change must not move `mdat` or need any chunk offset rewritten, so it is possible only when `moov` comes after all media, or when enough `free` space sits directly beside `ilst` or `moov` to absorb the difference. If there is none at all the file is read-only with the reason; if there is some but too little for a particular value, that save is refused. A `free` atom always keeps its header, so the next edit still has somewhere to go. Fragmented files, a video track, QuickTime brands and a `meta` that isn't iTunes-style are read-only or not offered. A file too broken to examine its tracks is called damaged only when its brand is `M4A ` or `M4B `; with a brand video shares it isn't offered.

**Verification** knows nothing of how a file was written. It parses the original and the staged file afresh and refuses unless: both parse cleanly; every byte before and after the edited region is identical (compared streamed); nothing after the region moved if something there can't move; every kept frame, comment or atom inside the region is byte-identical and in the same order; and the re-parse shows exactly the requested values, compared by bytes, and every other field as it was. Any doubt leaves the file untouched.

## Editing properties inside documents (FE-152)

Code: `PDFFormat.swift` (the format), `PDFSyntax.swift` (objects, strings, text encodings), `PDFStructure.swift` (cross-reference chain and objects),
`PDFDocumentFacts.swift` (where the properties live, and the update), `PDFXMP.swift`, `PDFVerifier.swift`; `OfficeFormat.swift` (the format and its
verifier), `OfficePackage.swift` (the ZIP reader and rewrite), `OfficeCoreProperties.swift`; `SafeXML.swift` and `BoundedInflate.swift`, shared by both.
Labels follow Explorer's for documents (Title, Subject, Authors, Categories, Comments), except that keywords are "Keywords", because "Tags" is the Finder tags row.

**Same safety model as images and audio.** Written beside the original in an `itemReplacementDirectory`, verified, attributes carried over, exchanged with `renamex_np(RENAME_SWAP)`, the original to the Trash for Undo, and refused if the file changed meanwhile.

**PDF.** The edit is an incremental update appended after the last original byte, so the original stays in place and is proved an exact prefix. The update holds a replaced (or new) document information dictionary, keeping every other entry's bytes, and, when the catalog has an XMP stream, a replacement of that stream with the same object number, uncompressed. A new object is numbered above every number any section declares in `/Size` or lists, since a damaged file's newest `/Size` can be too small, and the verifier refuses an update that defines any number the original already knew other than the replaced ones. Its cross-reference section is of the kind the file's newest section is: a classic table, or an uncompressed cross-reference stream. The reader starts from the last `startxref` (within the last 2 KiB, followed only by `%%EOF` and white space), follows the `/Prev` chain (512 sections at most, loops refused), and checks that every offset holds the object it should (`N G obj` exactly there). Object streams and Flate-compressed cross-reference streams with PNG predictors are read; every read is in a bounded window, all reads together (windows, stream data filtered or not, and what is parsed inside object streams) are capped at 128 MiB, inflation at 256 MiB and the cross-reference rows held at 64 MiB, a form whose field tree queues more than 16,384 entries is read-only as if signed, and anything unexpected leaves the file read-only rather than guessed at. Values are read from XMP when it has them, as most readers do, and an edit writes both places. Read-only, with the reason shown: encrypted files, any signature field, `/SigFlags`, `/Perms` or `/ByteRange` (searched for literally across the whole file, on opening up to 64 MiB and always when saving), a hybrid file with `/XRefStm`, a damaged cross-reference chain or trailer, an object stream that can't be resolved, and XMP that isn't plain UTF-8, has a DTD, is nested deeper than 64 levels, is larger than 4 MiB or isn't RDF Arbor can follow. Linearized files are edited: an update leaves them valid but no longer optimised for the web, which is what readers expect of any later change (tested with Quartz). Titles in several XMP languages, several authors, and values that aren't plain text are shown but not offered.

In XMP, only `dc:title`, `dc:description` (Subject), `dc:creator` and `pdf:Keywords` change, and `dc:subject` when it is already there (its list follows the keywords, split at commas and semicolons). They are edited with a real XML parser (`XMLDocument`) that keeps every other element, attribute, namespace, comment and the `xpacket` wrapper; a single value keeps its language.

**Office.** Only `docProps/core.xml` changes (`dc:title`, `dc:subject`, `dc:creator`, `cp:keywords`, `cp:category`, `dc:description` for Comments), in place, with unknown elements, namespaces and every element not being edited kept. The package is rewritten streamed: every other entry's local header, data and data descriptor are copied byte for byte by range, core.xml is replaced (stored), and the central directory is rewritten with the shifted offsets; the archive comment is kept. The package is read strictly: exactly one end record, entries back to back from the first byte up to the directory, every local header agreeing with the directory, data descriptors checked, and `_rels/.rels` must name `docProps/core.xml` as the core properties. Read-only, with the reason shown: encrypted documents (a compound file, or an encrypted entry), a digital signature (`_xmlsignatures/`, or a digital-signature content type or relationship), ZIP64, several disks, two parts whose names differ only in case, a local header that disagrees with the directory, anything hidden before, between or after the entries, core.xml over 1 MiB compressed or 4 MiB uncompressed, no core.xml, and core.xml that fails the XML bounds below. Keywords split into language parts and repeated elements are shown but not offered.

**XML is hostile.** Before any parser sees it, text must be UTF-8 (a declared encoding other than UTF-8, UTF-16 or a NUL is refused) with no `<!DOCTYPE`, so no entity can be expanded or fetched; it is at most 4 MiB and 64 levels deep, and external entities are never loaded.

**Verification** knows nothing of how a file was written. PDF: the original is an exact prefix; both files re-parse cleanly; there is exactly one new section, pointing back at the old newest one, defining only the replaced objects (and itself); the root is the same; every other entry of the information dictionary is byte-identical; the XMP is the same as seen by a second, independent parser (`XMLParser` events) apart from the edited properties, and its stream dictionary is unchanged apart from length and filters; Quartz (`CGPDFDocument`) opens both, counts the same pages and shows exactly the requested values in the information dictionary and the XMP; and Arbor's own re-parse agrees. Office: both central directories are re-read; every other entry's record (bar its offset), checksum and bytes are identical; the end record and comment are unchanged; the new core.xml matches its checksum, shows exactly the requested values, and is otherwise the same to the second parser.

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
- **DEC-properties-4** Embedded metadata is never edited in place: an edit is a verified lossless copy exchanged atomically
  with the original, and "Remove Properties" only creates a cleaned copy.
- **DEC-properties-11** A rewritten image's previous version goes to the Trash (DEC-010: Replace trashes, never deletes), so Undo and
  the Trash can both bring it back. If it can't reach the Trash, the exchange is undone and the edit refused.
- **DEC-properties-12** Only fields whose audited write reads back are offered; the rest are shown read-only, and the audit
  stays honest through a unit test round-tripping each type. Apply's slow step (`PropertiesModel.slowApplier`) runs after the fast ones and off the main thread.
- **DEC-properties-13** Audio metadata is edited only where the file already has the tag, comment block or metadata list. Adding one to a file with none (an MP3 with no ID3v2 tag, say) is a separate decision, not a side effect of an edit.
- **DEC-properties-14** Year and track accept four digits and N or N/M; a fuller date already in a file (`2001-05-06`) is kept until it is changed. Track numbers are limited to M4A's sixteen bits for every format.
- **DEC-properties-15** The Details tab uses Explorer's labels for audio: Contributing artists, Album, Year, #, Genre and Comments.
- **DEC-properties-5** Finder comments are written to the `com.apple.metadata:kMDItemFinderComment` attribute (what
  Spotlight reads). No AppleScript to Finder (it would need Automation permission).
- **DEC-properties-6** Previous Versions = NSFileVersion document versions + Time Machine status; per-file Time Machine
  browsing is handed to the Time Machine app. Nothing is listed that isn't real.
- **DEC-properties-7** Sizes use Explorer's adaptive format (1024-based, 3 significant digits, truncated, unit switch at
  1000: "0.99 MB"); Properties appends exact bytes. Symlinks are counted, not followed; hard links counted per entry.
- **DEC-properties-8** Alerts are sheets on the Properties window (scripts can answer them; headless keeps them invisible).
- **DEC-properties-10** The Details pane's large preview shows the type icon for plain text and source code, like
  Explorer's Details pane, instead of a QuickLook page that is almost empty at 150 pt. Property names in the pane wrap
  to two lines instead of being cut off.
- **DEC-properties-9** Opens with › Change… sets the default app for the file's type (all files of that type), like
  Windows; unknown types change only that file.

## Known gaps

- Finder's Get Info may show an older comment cached in `.DS_Store` (only Finder writes that file).
- Multi-selection shows the General tab only. Tabs don't wrap to a second row; a window with 5 tabs is full width.
- Volume rename of the startup disk may be refused by macOS (error is shown). Time Machine backups (as opposed to local
  snapshots) can't be listed without Full Disk Access (the tab says so); local snapshots are counted, not browsed
  (mounting them needs root). Backup copies were checked on a fake backup tree, not a real Time Machine disk.
- Embedded properties beyond the audited fields, and those of video and documents, are read-only. The Details pane doesn't
  edit them. An MP3 with no ID3v2 tag, FLAC with no comment block and M4A with no metadata list aren't given one; an ID3v1 trailer is never read or changed, so it can disagree with an edited tag. ID3 genre codes past the original 80 are shown as numbers and left alone. HEIC and TIFF can't store a date or description change losslessly (audit above). Spotlight may show the old value until it reindexes.
  JPEG segments are checked byte for byte; HEIC containers can't be, beyond their frames, auxiliary data and properties. Folder "Read-only" doesn't mimic Windows'
  "only applies to files in folder" tri-state; it locks the folder itself, as explained in the window.
- Context-menu "Properties" for the Home/This Mac pages' own items depends on those pages exposing a selection.
