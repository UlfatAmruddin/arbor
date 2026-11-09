# Windows shortcut files (FE-215)

Code: `Sources/ArborCore/WindowsShortcuts/` (parsers and policy, unit-tested in
`Tests/ArborCoreTests/WindowsShortcutsTests.swift`) and `Sources/Arbor/Features/WindowsShortcuts/` (opening, the
arrow, the Properties tab). Registered by `WindowsShortcutsFeature`.

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-215 | Windows shortcut file compatibility | **Implemented (read-only).** `.lnk` and `.url` show the shortcut arrow, "Windows shortcut" / "Internet shortcut" in Type, and a Shortcut tab in Properties. `.url` opens http and https addresses after a confirmation showing the real address. `.lnk` follows only a relative path that stays inside a floor and exists on this Mac; anything else gets an honest explanation. **No parity with Explorer is claimed**: there is no Windows observation yet (see below) | Unit tests (parsers, truncation and seeded mutation, policy with a recording probe, real-disk fixtures); `scripts/windows-shortcut-checks.sh` headless, in CI |

## Parsing, not converting

Arbor reads these files and writes nothing: no alias, `.webloc` or other file is created and the shortcut itself is
never changed. Mac aliases are still made only by `Shortcuts.createAlias` (FE-092). The word "Shortcut" in the Type
column keeps meaning a Mac alias, so the Windows types sort and group apart.

## What opening does

| Item | Result |
|---|---|
| `.url`, http or https | "Open this web address?" with the full address and its host; `SystemOpen.open` only after Open |
| `.url`, anything else | An explanation naming the scheme or the reason. `file:`, `smb:`, `javascript:`, `data:`, `mailto:`, `search-ms:` and app schemes are all refused |
| `.lnk` to a folder | Opens through `window.open`, so Folder Options still apply. Several selected shortcuts open as tabs |
| `.lnk` to a document | "Open this file?" with the real Mac path. Checked again after Open; opens only if nothing changed |
| `.lnk` to an app, script, installer or an unnamed type | Explains, and offers Show in Folder inside Arbor. Never opened |
| `.lnk` with arguments or to a Windows program | Explains. Never followed |
| `.lnk` to a drive letter, network path, `%VAR%` target or nothing | Explains. Nothing is probed or connected to |
| A shortcut inside an archive | Explains that it must be extracted first |
| A symbolic link that ends at a `.url` or `.lnk`, whatever the link is named or through an alias | Explains. The system would otherwise follow it and open the target unchecked. Judged by the name at the end of the chain, so a link named `x.url` to a PDF opens the PDF |
| A Mac alias to a `.url` or `.lnk` | The alias's target goes through the same checks, through the point `Shortcuts.openTarget` |

A file with a shortcut's extension that isn't one says so and is left alone. Any parsing problem refuses the whole
file; a partly parsed shortcut is never acted on.

## Limits

| What | Cap |
|---|---|
| `.lnk` file | 1 MiB |
| `.url` file | 64 KiB |
| `.url` lines | 4096 |
| Web address, after escaping | 1024 characters, the most the confirmation shows without cutting it off |
| Any string in a `.lnk` | 32,767 UTF-16 units |
| `.lnk` extra data blocks | 64 |
| Text shown from a shortcut | 1024 characters, with controls, bidi overrides and zero-width marks removed |
| Each value in the Shortcut tab | 280 characters, with the middle elided so the file name stays; the tooltip has it all |
| Opens at once | 8 shortcuts being read or waiting behind the prompt on screen, hung shares included; beyond that the status bar says so and those aren't opened |

## Evidence

- **`.lnk` format, DOC:** [MS-SHLLINK] Shell Link Binary File Format, Microsoft Open Specifications, revision 10.0.
  §2.1 header, §2.2 IDList, §2.3 LinkInfo (offsets from the start of LinkInfo), §2.3.2 CommonNetworkRelativeLink
  (offsets from the start of that structure), §2.4 StringData, §2.5 ExtraData.
- **`.url` format:** no published specification was found. Only `[InternetShortcut]` and `URL=` are read, as a de
  facto format, not DOC.
- **Explorer behaviour, AUDIT:** the only record is docs/research/windows11-reference.md §10.1, a "Shortcut (.lnk)"
  Properties tab, RECALL-h. Spec §14 lists LNK/URL import as unresolved. Everything else here is PROP.
- **macOS, measured on macOS 26:** `.lnk` is a dynamic type with no default app; `.url` is
  `com.microsoft.internet-shortcut` and a browser opens it with no prompt. `URL(string:)` puts a backslash in the user
  name, so `https://good.example\@evil.example` has the host `evil.example`, which is why backslashes and user names
  are refused. Host names come out in punycode.

## Decisions

Provisional unless the project owner confirms them.

| ID | Decision | Why |
|---|---|---|
| DEC-winlink-1 | Read-only: no conversion to a Mac alias or `.webloc`, no editing of Target or Start in | Distinct from FE-092; a conversion would be its own named command built on `Shortcuts.createAlias` |
| DEC-winlink-2 | Type names are "Windows shortcut" and "Internet shortcut" | "Shortcut" already means a Mac alias in Arbor |
| DEC-winlink-3 | `.url` opens only http and https, always after a confirmation. There is no "don't ask again" | Remembered trust would let a later edit of the file skip the check |
| DEC-winlink-4 | The address cap applies after escaping and is no higher than what the prompt shows, so the address opened is the address read | A prompt that cuts text off can hide the part that matters |
| DEC-winlink-5 | Only the first `URL=` of the first `[InternetShortcut]` section is used, for display and opening alike | A duplicate key can't disguise the target |
| DEC-winlink-6 | Only a `.lnk`'s relative path can reach the disk. Local base paths, UNC paths, environment targets, IDLists, working directories and icon locations are shown or skipped, never probed, expanded or fetched | A UNC icon path could otherwise cause an SMB connection and leak credentials |
| DEC-winlink-7 | The floor is the shortcut's own folder on the startup disk, and the volume root on another volume | A hostile `..` can't reach `/net`, `/Volumes` or `/dev`. A whole Windows tree copied to the startup disk may report "not found"; widening means changing this one rule |
| DEC-winlink-8 | The path is walked from the floor with one `lstat` per component. A symbolic link, another device, a non-folder in the middle, or a final item that isn't a regular file or folder is "not found" | Resolving links first would let a planted link trigger an automount before any check. A FIFO named `x.pdf` must never reach `NSWorkspace` |
| DEC-winlink-9 | Documents are a positive list: PDF, RTF, plain text, images, audio and video, Word, Excel, PowerPoint, OpenDocument text, sheets and slides, iWork. Everything else is Show in Folder only | A broad type with exclusions would pass the next dangerous type. Unnamed and dynamic types fail closed |
| DEC-winlink-10 | Inside those families these are refused: source code and scripts (they conform to plain text), anything executable (includes macro-enabled Office files), SVG (scripts in a browser), stream redirector and playlist files (M3U, PLS, ASX with WAX, WVX and WMX, and RAM, which shares its type with RA), because they name remote streams. iWork is allowed: it carries no macros and opens in Apple's own apps | Explicit answers for the formats that sit on the line. `WindowsShortcutPolicy.documentFamilies` holds them, and the tests pin both lists |
| DEC-winlink-11 | In the Open prompts no button takes Return, and Esc cancels. Show in Folder's Close also takes Esc | Return opens items in the list (DEC-009) and the prompt arrives after a background read, so a second press mustn't confirm unread text. Esc is set by hand because NSAlert gives it only to a button titled exactly "Cancel", which a translation isn't |
| DEC-winlink-12 | A result is dropped only if the tab the open began in has closed or that tab's own location changed | `window.location` follows the active tab, so one folder result opening a tab would otherwise discard the rest of a multi-selection |
| DEC-winlink-13 | A missing terminal block at end of file ends the extra data walk. Sizes 4 to 7 and overruns are damage | That section only feeds display and blocking |
| DEC-winlink-14 | Shortcut files inside archives are refused with an explanation rather than opened from the temporary copy | Archive members otherwise go straight to the system; a downloaded zip is the likeliest hostile case |
| DEC-winlink-15 | The Shortcut tab goes directly after General (PROP) | §10.1 of the reference lists the tab but not its position; see the observation tasks |

The Windows program list in `WindowsShortcutPolicy` only ever refuses, and a real folder inside the floor is followed even if its name looks like a program (`next.js`), since navigating runs nothing. The document list is the security gate for files.

## Shared-file changes

- `Features.swift`: one line.
- `Properties/MoreTabs.swift`: new point `PropertiesTabs.extraTabs`; `Support/ExtensionCatalog.swift` lists it.
- `ArborCore/ExplorerFormat.swift`: `ExplorerTypeName.name` takes `windowsShortcut:`; `FileItem.windowsShortcutKind` feeds it from `GeneralTab` and `DetailsTab`.
- `ArborCore/Search/SearchEvaluator.swift`: `SearchCandidate` uses the same two type names for `.lnk` and `.url`.
- `ItemActions/Shortcuts.swift`: new point `Shortcuts.openTarget`, called with the alias's already-resolved target.
- `ItemActions/Shortcuts.swift`: badge compositing extracted as `Shortcuts.withArrowBadge`, no behaviour change.
- `ArborCore/Archives/ArchiveEntry.swift`: `ArchivePath.resolvedLink` extracted; `linkStaysInside` calls it.
- `ArborCore/Search/ContentReaders.swift`: the SF_DATALESS value named as `stat.isDataless`.

## Known gaps

- ⌘-opening one shortcut doesn't open a new tab: `InteractionHooks.openFile` doesn't carry that detail.
- ANSI strings are decoded as Windows-1252, because a `.lnk` doesn't record the writer's code page. Non-Latin ANSI text may display wrongly; the Unicode fields are preferred.
- No `.lnk` written by real Windows has been tested. Fixtures are built from MS-SHLLINK.
- SF_DATALESS is verified by code path only (it needs a real cloud placeholder). The 5-second deadline is that of `SlowWorkQueue`, not exercised against a hung share.
- `type:` queries answered by Spotlight only see the macOS type text, so `type:windows` finds nothing from the index; a folder scan (`DirectSearch`) matches the Type column.
- Following a symbolic link to judge it happens on the main thread when it is opened, like the alias check beside it.
- Not done, on purpose: drive-letter or UNC mapping to mounted volumes (needs an identity guess a hostile file could exploit; `MountedShare` would be the place to start), IDList targets, advertised links, icons from the shortcut or its target (reading per row would hurt listing speed).
- macOS cannot run Windows executables, resolve drive letters, or apply Start in, Run window state or global shortcut keys.

## Observation tasks (spec §2.3)

Needs a pinned Windows reference. Disposable fixtures: a `.lnk` to a file, to a folder, to a missing target and with arguments; a `.url` to https and to a `file:` address.

1. **Properties, .lnk.** Open Properties on each `.lnk`. Record the tab order and every field on the Shortcut tab.
2. **Properties, .url.** Record which tab a `.url` has and its fields (Web Document?).
3. **Missing target.** Open the `.lnk` whose target was removed. Record the dialog title, text and buttons.
4. **Extensions.** With "Hide extensions for known file types" off, record whether `.lnk` and `.url` still hide theirs.
5. **Type column.** Record the Type text for each.

## Scripted checks

`scripts/build-app.sh debug && scripts/windows-shortcut-checks.sh` builds a fixture with `perl` and drives the app
headless and in CI: prompts, Open, Cancel, Esc and Return (the `sheetkey:` step sends a key to the sheet), every refusal,
Show in Folder, one and two folder shortcuts, a folder named `next.js`, links to shortcuts under other names, an archive
member, an alias to a `.url`, the cap on a large selection, Home ▸ Recent and the Shortcut tab. The `log:` step adds a
`windows shortcuts:` line with the last alert's text.
