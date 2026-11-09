# File operations: copy/move engine, progress, conflicts, delete, recovery

Area slot: "file-operation progress dialog" (`FileOperationsFeature.register()`).
Code: `Sources/ArborCore/{FileTransfer,CopyEngine,TransferControl,TransferDiscovery,TransferFailure,TransferRate,JobJournal}.swift`,
`Sources/ArborCore/{OperationHistory,TransferScheduler,CopyVerifier,VolumeCapabilities}.swift`, `Sources/Arbor/Features/FileOperations/`.
Tests: `Tests/ArborCoreTests/TransferEngineTests.swift` (33 tests), `OperationExtrasTests.swift` (history, queue,
verification, capabilities, archive options, ACL editing, Time Machine versions) plus the original `FileSystemTests.swift`
transfer tests (all unchanged and passing).

The extras (history, queue, verification, property-loss prompt, Compress to ▸ Additional options, Security ▸ Edit…,
Time Machine versions) register through `FileOperationsExtras.register()` in the "(spare 1)" slot of `Features.swift`,
after Archives and Properties, so they can extend those features' commands and tabs.

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
| FE-125 | Persistent job journal | implemented | unit (completed / not done / uncertain, torn last line, live-process journals left alone, waiting jobs recognized); headless crash simulation → review sheet; quit with a queued job → next launch offers "Start" (`behavior-checks.sh queue`) |
| FE-230 | Failure-injection suite | implemented | `FailureInjectionTests.swift`, one suite on disposable fixtures: a 6 MB full disk, denied access (file, folder, destination then Try Again, delete denied), locked items (source on one and across volumes, destination folder, Replace over a locked target), cancelling at six points, lost disks (errno table, then a forced detach between items and mid-file, and of the source), a file arriving as a merge finishes, a volume mounted inside a tree being deleted, and crash recovery. One shared check: no original is gone without an identical copy, nothing that was there changed, no partial item, one result per source, and the expected failure was asked. Real SIGALRM crash: acceptance T16; a real disconnect of a browsed volume: T26 |
| FE-126 | Operation results | implemented | "Operation history" window ("…" menu, Window ▸ Operation History, progress window footer): kind, sources → destination, time, outcome counts, verification state; expanding a job shows per-item results with readable reasons; Open destination, Retry failed items, Clear history (confirmed). Bounded: 50 jobs × 200 items. Jobs from the crash review are added too. Unit (record from report and from journal, counts, retry plan, retention, persistence); headless runs: failure → history → retry → clear, snapshots light + dark |
| FE-127 | Queue controls | implemented (beyond Explorer) | Off by default (Windows runs every job at once). "Queue options" in the progress window footer and Window ▸ Transfer Queue: "Queue transfers to the same drive", "Run at most N operations at a time". Per waiting job: Start now, Move up/down, Defer; Pause/Resume/Cancel per job as before. Unit (`TransferScheduler`: default concurrency, same drive, limit order, defer, start now, reconfigure); headless run with limit 1, reorder and defer, snapshots light + dark |
| FE-128 | Safe retry | implemented | "Retry remaining" starts a normal job: destinations re-checked, conflicts asked; missing sources not offered |
| FE-129 | Undo protection | implemented | Undo Copy removes (to Trash) only copies whose fingerprint is unchanged (unit: edited, replaced-same-size, Finder .DS_Store, deleted); redo restores |
| FE-130 | Optional copy verification | implemented | "Verify after copying" per copy job (check box in its progress panel, off by default; "Verify new copies by default" in Queue options). Size + SHA-256 of original and copy, streamed in 1 MB chunks, copy read with `F_NOCACHE`; shown as "Verifying copies… N%", then "Verified" (status bar, history) or an alert listing the files that don't match. Unit (identical tree incl. links, flipped byte, size, missing, exclusions, cancel, moves not verified); headless run with `ARBOR_VERIFY_THROTTLE`, snapshot |
| — | "Copy without its properties?" | implemented | Windows' "Property Loss" dialog (Yes · Skip · Cancel, "Do this for all current items") when the destination volume can't store an item's extended attributes (no `VOL_CAP_INT_EXTENDED_ATTR`: FAT32, exFAT, SMB without named streams) or access list (`_PC_EXTENDED_SECURITY_NP`), for files, packages and folders' own properties ("copy this folder without its properties?"; Skip leaves the folder out). Unit (APFS, a real exFAT image, inventory ignores system attributes, skip / for-all / cancel, tagged folder: `FolderPropertyLossTests`); headless copy to a real exFAT image, snapshots |
| FE-241 | Per-item success vs aborted | implemented | per-item outcomes incl. `partial` and `copiedButSourceRemains`; journal per item |
| FE-250 | Revalidation after delayed decision | implemented | unit: destination edited while dialog open → asked again; vanished conflict → plain copy |
| FE-255 | Actual committed name | implemented | unit: keep-both name recorded in report and journal |
| FE-257 | Pause capability honesty | implemented | see "What pause means" |

## What pause means (FE-115, FE-257)

The worker blocks at its next checkpoint: between files and between ~1 MB chunks inside a file (copyfile's
progress callback). The file stays open and continues from the same byte offset on resume. A same-volume move
(a rename) and an APFS clone are instant and are never "half done". Pausing lasts only while Arbor runs; quitting
cancels the job (removing the file being copied) and keeps the journal for review at the next launch.

## Queue, history and verification

- **Queue** (`TransferScheduler`, `TransferQueueController`): a job's drives are the volume IDs (`statfs` f_fsid) of its
  sources and destination, looked up off the main thread. A waiting job shows "Waiting to start" / "Deferred" with the
  reason ("Waiting for another operation on the same drive", "Waiting: one operation at a time") and its place in the
  queue; the progress window's header says "1 running, 2 waiting". Cancelling a waiting job starts it, so it ends at
  once as "cancelled" through the normal report and history. Changing the settings releases waiting jobs immediately;
  running jobs are never stopped.
- **History** lives in `~/Library/Application Support/Arbor/History/operations.json` (written atomically, 0600, on a
  private queue). "Retry failed items" starts normal jobs: a folder that arrived partly is not copied again whole; only
  its failed items go into the matching destination folder. Sources that no longer exist aren't offered.
- **Verification** runs on its own thread between the copy and the job's report, uses the job's pause/cancel control,
  and only checks what was copied (skipped and failed items inside merged folders are excluded).

## Decisions

| ID | Decision | Why |
|---|---|---|
| DEC-fileops-1 | Copy with `copyfile(3)` per file (`COPYFILE_ALL | CLONE | DATA_SPARSE | NOFOLLOW | EXCL`), own folder traversal | Byte progress, mid-file cancel/pause, per-file errors, folder metadata applied after contents. `EXCL` means nothing is ever written over. Creation date restored after non-clone copies (copyfile doesn't) |
| DEC-fileops-2 | A copyfile data error (`COPYFILE_ERR`) returns `COPYFILE_QUIT` | copyfile retries a failed write forever if the callback continues (seen with ENOSPC on HFS+) |
| DEC-fileops-3 | ~~Folder merge is confirmed by default~~. Changed: `Prefs.hideFolderMergeConflicts` defaults to on (Windows' default), so folders merge silently and the "Confirm Folder Replace" prompt is opt-in in Folder Options | Explorer's default is to merge silently; owner task asked for the prompt. Wording says files with the same name are asked about, because Arbor never replaces them silently |
| DEC-fileops-4 | Conflicts at one folder level are found first and asked together | Explorer's "The destination has N files with the same names"; enables the compare dialog. Each answer is re-checked before use (FE-250) |
| DEC-fileops-5 | Cross-volume move removes each original file right after its own copy; folders only when empty; packages as a unit after the whole package copied | Cancelling never leaves an item in neither place; originals are never removed recursively except a fully copied package |
| DEC-fileops-6 | Cancel keeps finished files, removes only the file being copied; a cancelled folder is reported `partial` | Spec §9.3: cancellation doesn't imply rollback |
| DEC-fileops-7 | Progress window appears after 0.8 s; closing it hides it (jobs continue; Window ▸ Show File Operations) | Explorer shows no dialog for quick jobs; hiding avoids accidental cancel |
| DEC-fileops-8 | Journal = append-only JSON lines in `~/Library/Application Support/Arbor/Jobs`, top-level item granularity, not fsync'd | O(1) per change; survives app crashes (not power loss, which errs toward "uncertain"/"not done", and retry re-checks) |
| DEC-fileops-9 | Undo Copy moves unchanged copies to the Trash (not permanent delete) | Recoverable, matches DEC-010 |
| DEC-fileops-10 | Delete confirmation for Trash follows Windows (off by default, `Prefs.displayDeleteConfirmation`); permanent delete always asks, default button No | windows11-reference §9.5 |
| DEC-fileops-11 | Disk full and read-only destination offer Try Again / Cancel only (no Skip) | Skipping can't help when the whole destination can't be written |
| DEC-fileops-12 | Compare dialog shows type icons, not thumbnails | Thumbnails would need disk reads for every row; icons are free |
| DEC-fileops-13 | Queue controls are off by default and labeled as Arbor extras | Explorer runs every transfer at once (FE-127 asks to keep this apart from parity claims) |
| DEC-fileops-14 | Deferred jobs start only when nothing else runs or waits; "Start now" ignores every rule | Predictable; the user can always override |
| DEC-fileops-15 | History keeps 50 jobs × 200 items, written from the job's report (and from crash journals after review) | Bounded file (spec §15); the journal itself is deleted when a job ends |
| DEC-fileops-16 | Verification compares SHA-256 of both sides (not a stored hash) and reads the copy uncached | Detects corruption on the destination, not just in memory; memory stays at two 1 MB buffers |
| DEC-fileops-17 | Moves aren't verified | A cross-volume move removes each original right after its copy, so nothing is left to compare |
| DEC-fileops-18 | "Property Loss" is asked for files, packages and folders (a folder's own tags, comments, attributes or access list; its contents are asked about one by one, and Skip leaves the whole folder out); system attributes (quarantine, provenance, MACL, last-used date) and all-zero Finder info never trigger it. "Yes" copies anyway: macOS keeps extended attributes in "._" files on FAT/exFAT and drops access lists | Windows asks per file; asking about invisible system attributes would prompt for every download |
| DEC-fileops-19 | Compress to ▸ Additional options writes ZIP, 7z, TAR, .tar.gz/.bz2/.xz and single-file .gz/.bz2/.xz with bsdtar; no Zstandard | The system libarchive has no zstd writer; it would depend on a separately installed `zstd` |
| DEC-fileops-20 | "Include hidden files" excludes `*/.*` below the selection; selected dot items are always included | The user chose them explicitly |
| DEC-fileops-21 | A job still waiting in the queue when Arbor quits isn't started or cancelled: its journal (which has no "running" line yet) is kept, and the next launch's review offers "Start", which queues it again as a normal job. Quitting doesn't wait for waiting jobs | The user asked for that transfer; nothing of it happened, so offering it again is safe and every destination is checked again |
| DEC-fileops-22 | Undo of a move from another volume is a normal move job (progress, pause, cancel, journal, conflict prompts, history); it registers no undo of its own | Same safety rules as any move; the undo stack keeps one Undo/Redo pair (qa-core.md QA-CORE-5) |
| DEC-fileops-23 | Folders nest at most 128 levels (`PathLimits.maxFolderDepth`) for copy, move, merge and permanent delete, including emptying the Trash. Deeper subtrees fail as "Path Too Long" with their originals kept; a delete that reaches the cap has already removed what came before, as `rm` would. Job threads get 8 MB of stack for this depth | Walkers hold one descriptor per level from a soft limit of 256 shared by every job; recursion was unbounded and overflowed the thread (QA-CORE-11). Trees the app accepted before can now be refused |
| DEC-fileops-24 | A job remembers the mount point of its destination at the start and re-checks it before every item (`statfs`), refusing with "Location Not Available" and no Skip; Try Again checks again | The folder a volume was mounted on survives an unmount and accepts writes, and renames into it succeed, so files would disappear under a later remount. The mount point is compared because a disk reconnected at the same place can get a different device number. A window of one system call remains |
| DEC-fileops-25 | New failure kinds are `pathTooLong`, `destinationLocked`, `volumeUnavailable` and `fileTooLarge`. `pathTooLong` and `fileTooLarge` offer Skip; a locked or vanished folder offers it only when that folder is inside the job's destination (`faultySubfolder`, and the message names it), never for the destination itself or a lost disk or share. Any error while the destination is gone reads as `volumeUnavailable`. EIO alone stays "Interrupted Action" | A forced eject mid-file reports EIO and the like, so the destination check, not the error number, says what happened; EIO on its own is ambiguous |
| DEC-fileops-26 | An emptied source folder after a merge, and a permanent delete, go through descriptors (`FileOps.removeEmptyFolder`, `removePermanently`). A folder is removed only by AT_REMOVEDIR, which refuses if anything arrived | The old path-based recursive delete could erase a file that arrived after the emptiness check, without ever copying it |
| DEC-fileops-27 | `FileOps.removeTree` stops with EXDEV at any folder on another volume than its parent, checked on the open folder, so a permanent delete never enters a disk image, sshfs or NFS mount inside the tree or selected directly. What came before the mount is already gone, as with the depth cap, and the message says nothing on the mount was deleted | `removefile(3)`, which FileManager relies on, doesn't cross mount points either; the descriptor walk that replaced it erased a mounted volume |
| DEC-fileops-28 | A failed Trash carries whether a permanent delete could still work (`TrashFailure`). Locked, read-only and missing items get a plain alert; only a location without a Trash, a permission problem or a path too long for the Trash offers Delete Permanently | The offer can't succeed in the other cases (EPERM, EROFS, ENOENT), and the dialog would contradict its own reason |

## Scripted checks (headless)

Steps added (append-only, from `FileOperationsFeature`): `opstart:copy|move:/a|/b:/dest`, `opsnap:progress|dialog|sheet:/x.png`,
`opdetails:on|off`, `opshow`, `oppause`, `opresume`, `opcancel`, `opbutton:<title>`, `opcompare:source|existing|both|skipsame`,
`opprefs:deleteconfirm=on|mergeprompt=off`, `recovery`. `log:` gains `operations:`, `operations window:`, `file-op dialogs:` and
`undo action:` lines. Environment: `ARBOR_JOURNAL_DIR` (journal folder; headless runs default to a private temp folder) and,
headless only, `ARBOR_TRANSFER_THROTTLE=<bytes/s>` to slow jobs down for snapshots.

From `FileOperationsExtras`: `opqueue:samedrive=on,limit=N,verifydefault=on`,
`opjob:N:startnow|up|down|defer|undefer|verify=on|verify=off|cancel|pause|resume` (N = 1-based job in start order),
`ophistory`, `histexpand`, `histselect:<row>`, `histbutton:<title>` (also the Clear confirmation), `histsnap:/x.png`,
`compressset:format=tarGzip,method=store,level=maximum,hidden=off,name=…,dest=…` (with `click:archive.compress.options`,
`opbutton:Create`, `opsnap:dialog:`), `aclset:kind=group,name=staff,verdict=deny,level=modify,inherit=on,select=N,group=…`
(with `propbutton:Edit…|Add…|Add|Apply|Back|Remove|Undo last change|Close`), `tmselect:N`, `tmbutton:open|restore`.
`log:` gains `queue:`, `history:`, the history window's rows, `verification alert:`, `compress options:` and the
permissions editor's state. Headless-only environment: `ARBOR_HISTORY_FILE`, `ARBOR_VERIFY_THROTTLE=<bytes/s>`,
`ARBOR_TM_BACKUPS=/a.backup:/b.backup` (backup folders searched instead of `tmutil listbackups`), `ARBOR_TM_ACCESS=denied|unconfigured`.

## Known gaps

- A real network failure isn't exercised: no SMB or NFS server exists in the tests, so loss is simulated by force-detaching a disk image plus an errno table. Power loss isn't covered: the journal is deliberately not fsynced (DEC-fileops-8).
- A real 4 GB file on FAT32 is only classified (EFBIG), to keep `scripts/test.sh` fast.
- Verification failures are covered by unit tests; the headless runs reach the "Verified" outcome only (a copy can't be
  corrupted on demand mid-run). Moves aren't verified (DEC-fileops-17).
- "Retry failed items" stays available after a retry (the old record still lists the failures); retrying again goes
  through the conflict prompts, so nothing is overwritten.
- "File In Use" is rare on macOS (EBUSY/ETXTBSY); locked (uchg) items are reported as "File Access Denied … locked".
- The property-loss prompt doesn't cover file flags or owners (copyfile applies what the volume allows).
- A queued job restored with "Start" goes back to the end of the queue; its old position isn't kept.
- Pause doesn't survive quitting; a retried item restarts from the beginning.
- The header counts top-level items ("Copying 2 items"), not every file inside folders; "Items remaining" counts every entry.
