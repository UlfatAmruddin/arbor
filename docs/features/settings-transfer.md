# Export and import of settings

Code: `Sources/Arbor/Features/SettingsTransfer/` (registered by `SettingsTransferFeature`), logic in
`Sources/ArborCore/PortableSettings/`, tests in `Tests/ArborCoreTests/PortableSettingsTests.swift` and
`Tests/ArborTests/SettingsTransferTests.swift`, scripted checks in the `settings` group of `scripts/behavior-checks.sh`.

Arbor ▸ Export Settings… writes one small JSON file. Arbor ▸ Import Settings… reads one, shows every change with its old
and new value, and changes nothing until you press Import. Windows File Explorer has no such feature: FE-208 is a
proposed improvement, and nothing here claims parity.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-208 | Export and import preferences as one portable file | Implemented | Unit tests for the allowlist, the file format, the reader and the plan; app tests that an import reaches the preferences their owners read with the same defaults, and that the preview list scrolls from the keyboard; scripted checks for export, preview, keyboard focus, Page Down, Return, Escape, Cancel, Import and refused or crafted files; preview snapshots at normal length and pseudo-localized, `l10naudit` with `ARBOR_PSEUDO_LOC=1` and `ARBOR_TEXT_SIZE=150`, `axaudit`. The open and save panels aren't drivable headless (see Known gaps) |

## What a file can hold

Exactly the entries of `PortableSettingsCatalog.all`, each a key plus a closed list of allowed values:

- **Folder Options (17):** Open Arbor to, Browse folders, compact view, full path in title bar, hidden files, Hide empty
  drives, pop-up descriptions, status bar, sync provider notifications, item check boxes, typing mode, the file list keys and the navigation
  pane options.
- **Other preferences (5):** navigation pane, text size, swipe navigation and the two transfer queue options.

Everything else stays on the Mac, because it isn't listed:

- `PortableSettingsCatalog.localOnlyFolderOptions`, each group with its reason: hiding extensions (hides a file's real
  type, DEC-008), click behavior and the underline style that depends on it (changes how many clicks launch a file,
  DEC-settings-3), protected system files and folder merge conflicts (remove a warning or prompt), recent files, frequent
  folders and window restore (turn activity recording on), preview handlers, thumbnails and the two search options that
  parse file contents (decide which file contents Arbor reads), and the two search options nothing reads yet
  (DEC-settings-4).
- Delete confirmation, verify-after-copy, Quick access pins, Home state, Gallery folders, libraries, folder templates,
  mapped network drives, search history, column sets, per-folder views, session and window geometry, the side pane.
- Every `ARBOR_*` name: those are environment variables read only through `Automation`, and an import writes only the
  preference keys in this catalog.

## Decisions

Statuses are as in `docs/DECISIONS.md`.

- **DEC-settings-1** (Provisional) Every portable value comes from a closed list. There is no free-text or range type in
  the format, so a path, a credential or an unbounded number can't pass validation. The spec allows paths as an opt-in
  ("excluded by default"); there is no opt-in, because a file that could hold paths would lose this guarantee.
- **DEC-settings-2** (Provisional) One audited catalog with deny by default, and no extension point: a contribution point
  would let any feature widen what an import can write. A unit test requires every Folder Options control to be classified
  as portable or local-only, so a new control can't go unclassified. The local-only list is deliberately conservative:
  relaxing it later is one line, tightening it after release is not.
- **DEC-settings-3** (Provisional; **needs the owner**) "Click items as follows" stays on the Mac. It changes how many
  clicks launch a file, and opening has no further confirmation, so a file must not be able to set it (FE-208 forbids an
  import from setting anything security relevant). Underline icon titles stays with it, because underlining shows only with
  single-click. If the owner wants them portable (open question 6 in `docs/DECISIONS.md`), that is moving those two keys.
- **DEC-settings-4** (Provisional) A setting an import couldn't visibly change isn't in the file, because the preview would
  claim otherwise (DEC-019). The last-used view, sort, sort direction and folders first are left out: every folder takes
  its view from `ViewSettingsResolver`, whose bottom layer is the built-in default and not these preferences, and making
  it read them first is a separate behavior decision. "Don't use the index" and "Include system directories" are left out
  because search doesn't read them yet; they return to the portable list when it does.
- **DEC-settings-5** (Provisional) The header is decoded before `settings`, so a future version may change that shape and
  still be reported as newer. `version` must be exactly 1. Unknown keys are ignored, so additions need no new version.
- **DEC-settings-6** (Provisional) An import is all or nothing after the preview, with no undo and no automatic backup: the
  preview shows the old values, and you can export first.
- **DEC-settings-7** (Provisional) File work goes through `SlowWorkQueue` with a 15-second deadline, so a hung share ends in
  a message and a retry shares the blocked thread. An export is keyed by path and content: a retry of the same bytes shares
  a hung write, but changed settings don't get reported as saved by an older write.
- **DEC-settings-8** (Provisional) One import at a time app-wide. Export and Import are disabled while the active window
  has a sheet, and Import while any window has an import in progress: a second preview would queue with a stale "Now" column.
  Only the window an import started on can end it, so a closed window's late reply can't end a newer import elsewhere.
- **DEC-settings-9** (Provisional) No file type and no open-file handler: double-clicking or dropping a file can never
  start an import. The file is unsigned JSON that anyone can edit; the allowlist and the preview are the protection, and
  the interface makes no claim that a file is trusted.
- **DEC-settings-10** (Provisional) Files key Folder Options by their catalog name, independent of how they are stored. For
  plain preferences the catalog key is both the file key and the preference key, so renaming such a preference later
  needs a separate file key on that one entry.
- **DEC-settings-11** (Provisional) The preview's list takes the keyboard focus and scrolls with the arrow, Page Up, Page
  Down, Home and End keys, because the preview is the only safeguard before a change with no undo. Escape answers Cancel.
  Return answers nothing: there is no default button, so it can't confirm a list the keyboard hasn't been through.

## Mac boundaries (DEC-019)

Privacy grants (Full Disk Access, Local Network and others) belong to each Mac and only the user can change them in System
Settings, so they aren't offered. Passwords stay in the Keychain and this feature never reads them.

## Known gaps

- The open and save panels can't be driven headless. Scripts skip only the panel (`settingsexport:`, `settingsimport:`);
  a run through the real panels by hand still has to be recorded here.
- The preview's focus ring and Tab order with Full Keyboard Access on need a real, key window, so they aren't covered by the
  headless checks; a run by hand still has to be recorded here.
- The preview in dark appearance hasn't been checked by eye; a run by hand still has to be recorded here.
- The 15-second deadline on a hung share (DEC-settings-7) hasn't been exercised end to end for an export or an import; a run
  against a share that stops responding still has to be recorded here.
- Column sets and Apply to Folders defaults are structured values that would need their own validator.
- `gallery.size` and `gallery.newestFirst` are left out: Gallery updates only on its own notification, so a generic write
  would look broken. Add them once Gallery observes `Prefs.changed`.
- Choosing individual rows in the preview, cloud sync and automatic import are out of scope.

## Shared files touched (small, additive)

`Sources/Arbor/Features.swift` (one line) and `scripts/behavior-checks.sh` (the `settings` group). The feature reads
`FolderOptionsPrefs` and `Prefs` at run time and adds no extension point.
