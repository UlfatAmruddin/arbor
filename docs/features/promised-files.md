# Promised files (FE-102, FE-240, FE-256)

Files that another app promises to write when dropped, such as Mail attachments and archive members.

Code: `Sources/ArborCore/PromiseReception.swift` (logic, tests in `Tests/ArborCoreTests/PromiseReceptionTests.swift`) and
`Sources/Arbor/Features/PromisedFiles/` (`PromiseDrop` and script steps, tests in `Tests/ArborTests/PromiseDropTests.swift`).

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-102 | File promises and dropped attachments | **Implemented for stand-in providers.** A drop on an item view, the tree or the address bar shows "Receiving “name” · bytes" in the status bar with its progress bar and Cancel, then becomes a normal copy job with the progress window. A provider that reports an error, or says nothing for 120 seconds, gets a clear message naming the item | Unit tests; `behavior-checks.sh promises` |
| FE-240 | Streamed and promised transfer negotiation | **Implemented; interoperability open.** Promised content goes from the provider to a staging folder on disk and then through `FileTransfer`, so no file is held in memory. A drop is offered as Copy (Generic if that's all the source allows); a Move-only source is refused | Unit tests on real `NSFilePromiseProvider` pasteboards; Finder and Mail not exercised |
| FE-256 | Promise completion versus partial output | **Implemented.** Only the provider's completion report counts, and only with a plain item in the promise's own staging folder. Error, cancel, silence or an unsafe location leaves nothing in the destination; staging is removed afterwards | Unit tests; `behavior-checks.sh promises` |

FE-258 (names may be unknown before the drop) is respected: hovering only reads the pasteboard types, and a promise with no declared names is finished once 10 seconds pass with no new report or data.

## How it works

- `PromiseDrop` offers the operation and, at the drop, hands the `NSFilePromiseReceiver`s to `PromiseReception`.
- `PromiseReception` makes a staging folder on the destination's volume with one folder per promise, asks each provider to write there, and tracks each promise's reports on one private queue. Every second it measures what has arrived (bounded) for the status bar and the stall limit.
- A delivery is accepted only if the report has no error, its name passes `NameRules.validate`, its parent really is that promise's folder, and `fstatat` finds a plain file or folder there. The path used afterwards is built from Arbor's folder, not from the report.
- What arrived goes through `startTransfer(.copy, …)`: conflict dialogs, journal, queue, Undo. The staging folder is removed when that job ends. Staged items sit in a folder called "Dropped items", which is what the conflict dialog shows as their source.
- Names and error text from the provider are shown only through `UntrustedText.display`.

## Decisions

| ID | Decision | Why | Status |
|---|---|---|---|
| DEC-promises-1 | Reception is a status bar activity, not a job in the progress window; the copy that follows is a job | The progress window is built around `FileTransfer`; extraction, compression and mounting are activities too | Provisional |
| DEC-promises-2 | Staging is on the destination's volume, and that one folder is made on the main thread during the drop | Delivery must start while the drop is being handled, and a copy from the same volume clones. The folder was just hovered, so it is reachable | Provisional |
| DEC-promises-3 | Cancel keeps nothing that had arrived, even complete items | Nothing has been placed yet, and the provider still has them | Provisional |
| DEC-promises-4 | 120 seconds without a report or a new byte means the provider is unavailable | Long enough for a slow mail server; a wrong guess costs a retry, and Cancel is there sooner | Provisional |
| DEC-promises-5 | Same-named promises get separate folders and reach the conflict dialog | The system would otherwise rename them unseen | Provisional |

## Known gaps

- Dragging from Finder, Mail or other real apps can't be exercised here: AppKit only delivers within a real drag, so tests use stand-in providers. A real receiver on a private pasteboard never answers, which is what the unavailable-provider test uses.
- Progress within one item is bytes only: promises declare no size, so the bar moves per item.
- Cancel can't stop the other app's writing; its folder is removed and whatever it delivers later is ignored.
- A crash during reception leaves staging in the volume's temporary items folder until macOS clears it. Quitting cancels and removes it.

## Scripted checks

`scripts/behavior-checks.sh promises`. Steps: `promisedrop:<mode>:<name>:/folder` (modes `ok`, `unnamed`, `fail`, `lie`, `escape`, `link`, `stall`, `slow`), `promisecancel` (the status bar's Cancel), `promisewait` (holds until nothing is running). `log:` adds a `promised:` line. `ARBOR_PROMISE_STALL=<seconds>` shortens the stall limit.
