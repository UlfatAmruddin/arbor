# File operations: copy/move engine, progress, conflicts, delete, recovery

Area slot: "file-operation progress dialog" (`FileOperationsFeature.register()`).
Code: `Sources/ArborCore/{FileTransfer,CopyEngine,TransferControl,TransferDiscovery,TransferFailure,TransferRate,JobJournal}.swift`,
`Sources/Arbor/Features/FileOperations/`. Tests: `Tests/ArborCoreTests/TransferEngineTests.swift` (33 tests) plus the
original `FileSystemTests.swift` transfer tests (all unchanged and passing).

## Status

| FE | Requirement | Status | Verified by |
|---|---|---|---|
| FE-114 | Progress: counts, bytes, speed, time, graph | implemented | unit (200 MB byte progress, many small files, estimator wording); headless snapshots of compact/expanded/paused dialog, light + dark |
| FE-115 | Pause / resume / cancel | implemented | unit (pause blocks with no bytes moving, resume completes identical file; cancel mid-file leaves no partial; cancel while paused) ; headless `oppause`/`opcancel` |
| FE-116 | Concurrent operations | implemented | panels stack in one window ("2 operations running"); headless run with two jobs |
| FE-117 | Replace / skip / compare / keep both | implemented | unit (batch decisions, committed names); headless snapshots of "Replace or Skip Files" and "N File Conflicts" |
| FE-118 | Folder merge | implemented | unit; "Confirm Folder Replace" snapshot |
| FE-119 | Apply to remaining | implemented | unit (once per kind, per job); "Do this for all current items" |
| FE-120 | Permission / in-use failures | implemented | unit (destination access denied → Try Again succeeds; skip-for-all; cancel); failure dialog snapshot |
| FE-121 | Out of space / destination loss | implemented | unit on a real 6 MB HFS+ disk image: ENOSPC → "Not Enough Space", original kept, no partial file |
| FE-122 | Cross-volume move | implemented | unit: injectable volume check + real disk image; each original deleted only after its own copy succeeded; failed originals kept |
| FE-123 | Metadata preservation | implemented | unit: xattrs, Finder tags, permissions, flags (hidden), creation + modification dates, folder dates/permissions, with and without clone |
| FE-124 | Symlinks, hard links, sparse | implemented | unit: links copied as links (never followed, also in discovery), hard links become independent files, 200 MB sparse file stays sparse |
| FE-125 | Persistent job journal | implemented | unit (completed / not done / uncertain, torn last line, live-process journals left alone); headless crash simulation → review sheet |
| FE-126 | Operation results | partial | per-item results + end-of-job problem summary; no persistent history list |
| FE-127 | Queue controls | not done | jobs run concurrently; no ordering/defer/concurrency limit UI |
| FE-128 | Safe retry | implemented | "Retry remaining" starts a normal job: destinations re-checked, conflicts asked; missing sources not offered |
| FE-129 | Undo protection | implemented | Undo Copy removes (to Trash) only copies whose fingerprint is unchanged (unit: edited, replaced-same-size, Finder .DS_Store, deleted); redo restores |
| FE-130 | Optional copy verification | not done | no checksum pass yet |
| FE-241 | Per-item success vs aborted | implemented | per-item outcomes incl. `partial` and `copiedButSourceRemains`; journal per item |
| FE-250 | Revalidation after delayed decision | implemented | unit: destination edited while dialog open → asked again; vanished conflict → plain copy |
| FE-255 | Actual committed name | implemented | unit: keep-both name recorded in report and journal |
| FE-257 | Pause capability honesty | implemented | see "What pause means" |

## What pause means (FE-115, FE-257)

The worker blocks at its next checkpoint: between files and between ~1 MB chunks inside a file (copyfile's
progress callback). The file stays open and continues from the same byte offset on resume. A same-volume move
(a rename) and an APFS clone are instant and are never "half done". Pausing lasts only while Arbor runs; quitting
cancels the job (removing the file being copied) and keeps the journal for review at the next launch.

## Decisions

| ID | Decision | Why |
|---|---|---|
| DEC-fileops-1 | Copy with `copyfile(3)` per file (`COPYFILE_ALL | CLONE | DATA_SPARSE | NOFOLLOW | EXCL`), own folder traversal | Byte progress, mid-file cancel/pause, per-file errors, folder metadata applied after contents. `EXCL` means nothing is ever written over. Creation date restored after non-clone copies (copyfile doesn't) |
| DEC-fileops-2 | A copyfile data error (`COPYFILE_ERR`) returns `COPYFILE_QUIT` | copyfile retries a failed write forever if the callback continues (seen with ENOSPC on HFS+) |
| DEC-fileops-3 | Folder merge is confirmed ("Confirm Folder Replace") by default; `Prefs.hideFolderMergeConflicts` merges silently | Explorer's default is to merge silently; owner task asked for the prompt. Wording says files with the same name are asked about, because Arbor never replaces them silently |
| DEC-fileops-4 | Conflicts at one folder level are found first and asked together | Explorer's "The destination has N files with the same names"; enables the compare dialog. Each answer is re-checked before use (FE-250) |
| DEC-fileops-5 | Cross-volume move removes each original file right after its own copy; folders only when empty; packages as a unit after the whole package copied | Cancelling never leaves an item in neither place; originals are never removed recursively except a fully copied package |
| DEC-fileops-6 | Cancel keeps finished files, removes only the file being copied; a cancelled folder is reported `partial` | Spec §9.3: cancellation doesn't imply rollback |
| DEC-fileops-7 | Progress window appears after 0.8 s; closing it hides it (jobs continue; Window ▸ Show File Operations) | Explorer shows no dialog for quick jobs; hiding avoids accidental cancel |
| DEC-fileops-8 | Journal = append-only JSON lines in `~/Library/Application Support/Arbor/Jobs`, top-level item granularity, not fsync'd | O(1) per change; survives app crashes (not power loss, which errs toward "uncertain"/"not done", and retry re-checks) |
| DEC-fileops-9 | Undo Copy moves unchanged copies to the Trash (not permanent delete) | Recoverable, matches DEC-010 |
| DEC-fileops-10 | Delete confirmation for Trash follows Windows (off by default, `Prefs.displayDeleteConfirmation`); permanent delete always asks, default button No | windows11-reference §9.5 |
| DEC-fileops-11 | Disk full and read-only destination offer Try Again / Cancel only (no Skip) | Skipping can't help when the whole destination can't be written |
| DEC-fileops-12 | Compare dialog shows type icons, not thumbnails | Thumbnails would need disk reads for every row; icons are free |

## Scripted checks (headless)

Steps added (append-only, from `FileOperationsFeature`): `opstart:copy|move:/a|/b:/dest`, `opsnap:progress|dialog|sheet:/x.png`,
`opdetails:on|off`, `opshow`, `oppause`, `opresume`, `opcancel`, `opbutton:<title>`, `opcompare:source|existing|both|skipsame`,
`opprefs:deleteconfirm=on|mergeprompt=off`, `recovery`. `log:` gains `operations:`, `operations window:`, `file-op dialogs:` and
`undo action:` lines. Environment: `ARBOR_JOURNAL_DIR` (journal folder; headless runs default to a private temp folder) and,
headless only, `ARBOR_TRANSFER_THROTTLE=<bytes/s>` to slow jobs down for snapshots.

## Known gaps

- No operation history window (FE-126), no queue controls (FE-127), no verification pass (FE-130).
- "File In Use" is rare on macOS (EBUSY/ETXTBSY); locked (uchg) items are reported as "File Access Denied … locked".
- Metadata a destination can't store (e.g. xattrs on some SMB/exFAT volumes) is dropped by copyfile without the Windows
  "copy without its properties?" prompt.
- Pause doesn't survive quitting; a retried item restarts from the beginning.
- The header counts top-level items ("Copying 2 items"), not every file inside folders; "Items remaining" counts every entry.
