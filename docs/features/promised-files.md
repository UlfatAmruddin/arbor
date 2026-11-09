# Promised files (FE-102, FE-240, FE-256)

Files that another app promises to write when dropped, such as Mail attachments and archive members.

Code: `Sources/ArborCore/PromiseReception.swift` (logic, tests in `Tests/ArborCoreTests/PromiseReceptionTests.swift`) and
`Sources/Arbor/Features/PromisedFiles/` (`PromiseDrop` and script steps, tests in `Tests/ArborTests/PromiseDropTests.swift`).

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-102 | File promises and dropped attachments | **Implemented; checked against a separate process, real apps not yet seen.** A drop on an item view, the tree or the address bar shows "Receiving “name” · bytes" in the status bar with its progress bar and Cancel, then becomes a normal copy job with the progress window. A provider that reports an error, or says nothing for 120 seconds, gets a clear message naming the item | Unit tests; `behavior-checks.sh promises promisesinterop` |
| FE-240 | Streamed and promised transfer negotiation | **Implemented; system path checked across processes, Mail, Finder and Safari not yet seen.** Promised content goes from the provider to a staging folder on disk and then through `FileTransfer`, so no file is held in memory. A drop is offered as Copy (Generic if that's all the source allows); a Move-only source is refused | Unit tests on real `NSFilePromiseProvider` pasteboards; `behavior-checks.sh promisesinterop` (see "Across processes"); the manual list below has not been run |
| FE-256 | Promise completion versus partial output | **Implemented.** Only the provider's completion report counts, and only with a plain item in the promise's own staging folder. Error, cancel, silence or an unsafe location leaves nothing in the destination; staging is removed afterwards | Unit tests; `behavior-checks.sh promises` |

FE-258 (names may be unknown before the drop) is respected: hovering only reads the pasteboard types, and a promise with no declared names is finished once 10 seconds pass with no new report or data.

## How it works

- `PromiseDrop` offers the operation and, at the drop, hands the `NSFilePromiseReceiver`s to `PromiseReception`.
- `PromiseReception` makes a staging folder on the destination's volume with one folder per promise, asks each provider to write there, and tracks each promise's reports on one private queue. Every second it measures what has arrived (bounded) for the status bar and the stall limit.
- A delivery is accepted only if the report has no error, its name passes `NameRules.validate`, its parent really is that promise's folder, and `fstatat` finds a plain file or folder there. The path used afterwards is built from Arbor's folder, not from the report.
- What arrived goes through `startTransfer(.copy, …)`: conflict dialogs, journal, queue, Undo. The staging folder is removed when that job ends. Staged items sit in a folder called "Dropped items", which is what the conflict dialog shows as their source.
- Names and error text from the provider are shown only through `UntrustedText.display`.

## Across processes

`scripts/promise-peer.swift` is a separate program using the real `NSFilePromiseProvider`, its delegate and `NSFilePromiseReceiver`. The `promisesinterop` check compiles it and runs it beside the real app.

**What is real:** two processes, the system's drag pasteboard, the Details view's own drop validation and drop code, `NSFilePromiseReceiver`, AppKit's file coordination between the processes, the provider writing into Arbor's staging folder, the completion report, and the copy into the destination. In the other direction, Arbor's real `ArchiveMemberPromise` is read and delivered to the separate process.

**What is not real:** there is no drag session. AppKit starts delivery only when its drag manager announces the end of a drop, and that needs a pressed mouse button. Posting mouse events would need Accessibility permission and move the pointer. So the check makes that one call by hand, through private AppKit names (`_notifyFilePromiseTargetsWithDraggingInfo:` in the app, `draggingEnded:` in the peer). The step is compiled only into debug builds. `FakeDraggingInfo` stands in for the drag information and carries the real pasteboard. If a later macOS renames these, the check fails with `end=false` rather than passing.

Seen on macOS 26:

| Case | Result |
|---|---|
| Private named pasteboard, end of drop announced | Types and file types cross; delivery fails with "The operation was cancelled", nothing written |
| Drag pasteboard, end of drop not announced | The provider is asked for a name but never writes; the receiver stays silent |
| Drag pasteboard, end of drop announced | The provider writes; content, size and process ID match |
| Hovering | The provider is asked for nothing; the promise is offered as Copy |
| Provider reports an error | Its text reaches the alert; partial output is removed |
| Provider process dies while writing | AppKit reports an error at once, so the stall limit isn't needed; no output |
| Provider names a file `../evil.txt` | AppKit refuses and never asks it to write; Arbor reports the failure; no output |
| Promised name already exists | The conflict dialog appears; Skip keeps the existing file |

Names stay empty until delivery is requested (FE-258). AppKit may report the delivered path through a symbolic link (`/tmp` for `/private/tmp`), which is why `PromiseReception` compares the parent folder by device and inode.

The check overwrites the system's drag pasteboard, so a drag made by hand during those seconds would be disturbed. It has passed on a developer Mac; whether the runner's session allows it will show on the first CI run.

## Check by hand

**None of these has been run.** Real Mail, Finder and Safari drags need a person. About two minutes, in a debug or release build, with a disposable folder open in Arbor:

| # | Drag | Expected |
|---|---|---|
| 1 | Mail: an attachment onto the empty area of the folder | "Receiving “name”" in the status bar, then the file is there, selected, and opens correctly |
| 2 | The same attachment again | The Replace or Skip dialog; Skip leaves the first file alone |
| 3 | Finder: a file onto the folder | A plain file drop, not a promise: it follows the usual copy or move rules |
| 4 | Arbor to Finder: a file onto the Desktop | Finder receives it by the usual rules |
| 5 | Arbor to Finder: open a .zip in Arbor and drag one member onto the Desktop | The member is extracted there, content intact |
| 6 | Safari: an image from a web page onto the folder | An image file arrives with a sensible name and opens. Note what happens if Arbor refuses it, since Safari's offer may not be a promise |

## Decisions

| ID | Decision | Why | Status |
|---|---|---|---|
| DEC-promises-1 | Reception is a status bar activity, not a job in the progress window; the copy that follows is a job | The progress window is built around `FileTransfer`; extraction, compression and mounting are activities too | Provisional |
| DEC-promises-2 | Staging is on the destination's volume, and that one folder is made on the main thread during the drop | Delivery must start while the drop is being handled, and a copy from the same volume clones. The folder was just hovered, so it is reachable | Provisional |
| DEC-promises-3 | Cancel keeps nothing that had arrived, even complete items | Nothing has been placed yet, and the provider still has them | Provisional |
| DEC-promises-4 | 120 seconds without a report or a new byte means the provider is unavailable | Long enough for a slow mail server; a wrong guess costs a retry, and Cancel is there sooner | Provisional |
| DEC-promises-5 | Same-named promises get separate folders and reach the conflict dialog | The system would otherwise rename them unseen | Provisional |

## Known gaps

- Real drags from Mail, Finder and Safari have not been seen (see "Check by hand"). The separate process is not sandboxed and uses the modern API, so sandboxed apps and older providers using `NSFilesPromisePboardType` remain unproven.
- The end of the drop is simulated (see "Across processes"). A receiver on a private pasteboard never delivers, which is what the unavailable-provider test uses.
- Progress within one item is bytes only: promises declare no size, so the bar moves per item.
- Cancel can't stop the other app's writing; its folder is removed and whatever it delivers later is ignored.
- A crash during reception leaves staging in the volume's temporary items folder until macOS clears it. Quitting cancels and removes it.

## Scripted checks

`scripts/behavior-checks.sh promises`. Steps: `promisedrop:<mode>:<name>:/folder` (modes `ok`, `unnamed`, `fail`, `lie`, `escape`, `link`, `stall`, `slow`), `promisecancel` (the status bar's Cancel), `promisewait` (holds until nothing is running). `log:` adds a `promised:` line. `ARBOR_PROMISE_STALL=<seconds>` shortens the stall limit.

`scripts/behavior-checks.sh promisesinterop`. Debug-build steps on the system's drag pasteboard: `promisesystemhover`, `promisesystemdrop` (the current folder), `promisesystemoffer:<visible item>`, `promiseholduntil:/path` (keeps serving until the other process leaves that file). `log:` adds a `promise interop:` line.
