# Clipboard shared with other apps (FE-101)

Files go between Arbor and Finder or other Mac apps through the system pasteboard. Windows' shell clipboard can carry a
preferred and a performed effect; the Mac pasteboard has no such record (spec §8.2), so Arbor's own cut intent is kept
beside it, and other apps never see it.

Code: `Sources/ArborCore/ClipboardFiles.swift` (what is accepted, tests in `Tests/ArborCoreTests/ClipboardFilesTests.swift`),
`Sources/Arbor/Support/FileClipboard.swift` (tests on private pasteboards in `Tests/ArborTests/FileClipboardTests.swift`),
`ClipboardCommands` in `Commands/FileCommands.swift`, and script steps in `Sources/Arbor/Features/ClipboardInterop/`.

## Status

| FE | Feature | Status | How verified |
|---|---|---|---|
| FE-101 | Clipboard interoperability with Mac apps | **Implemented; real Finder not exercised.** See the table below | Unit tests on private pasteboards; `behavior-checks.sh clipboard` with a stand-in app writing the same file URLs |

## What happens

| From | To | Result |
|---|---|---|
| Finder or another app, Copy | Arbor, Paste | Copy, through the normal job: conflict dialogs, journal, Undo |
| Finder or another app, Copy | Arbor, Move Item(s) Here (⌥⌘V, Edit menu, background menu) | Move, through the same job, with Undo. The other app's clipboard is left as it is, but Arbor stops offering it, because its files have gone |
| Arbor, Copy | Finder or another app | Copy. One `public.file-url` per item (AppKit also derives the older `NSFilenamesPboardType`), and the first item carries every full path as plain text, one per line, for apps that take only text |
| Arbor, Cut | Finder or another app | Exactly the same data as Copy, so a **copy**: the source stays and stays marked as cut in Arbor. The status bar says so when cutting |
| Arbor, Cut | Arbor, Paste | Move, while the pasteboard still holds what Arbor wrote (`TransferIntent`) |
| Arbor, Cut, then another app copies something | Arbor, Paste | Pastes the new content as a copy; the cut marks go away |

A finished move empties the clipboard only if Arbor wrote the content and it is still the content that was pasted
(QA-CORE-3). A skip, a cancel or a problem leaves the clipboard alone, because something is still where it was, and no
message claims a move for items that didn't move.

## What is accepted

Pasteboard contents come from anywhere, so `ClipboardFiles.read` treats them as hostile and refuses the whole paste, with
a message saying why, rather than pasting part:

- More than 100,000 items: the count is checked before any item is read.
- Any item that isn't a URL, or a URL that isn't plain local: another scheme, a host (`file://server/...`), a relative
  form, a `%00`, a query or fragment, a file reference that no longer resolves, or a string over 64 KB
  (`ExternalOpen.validatedFileURL`, the check outside opens use). `..` is resolved before the path is used.
- A volume root, as Copy is disabled on one in Arbor: moving a mount point would copy the disk and then empty it.

Duplicates are dropped. Nothing from the pasteboard is opened: it only ever becomes a source list for a copy or move, or
targets of Paste Shortcut. `canPaste` reads only the types, since menus ask it, and a hung owner could stall a data read.
Text on the pasteboard, including a path, is never treated as files.

Move Item(s) Here yields to a text field being edited, so ⌥⌘V while typing can't move files.

## Decisions

| ID | Decision | Why | Status |
|---|---|---|---|
| DEC-clipboard-1 | No private "cut" marker is written for other apps | The pasteboard has no agreed move signal; a marker only some apps read would be a promise Arbor can't keep | Provisional |
| DEC-clipboard-2 | Refuse the whole clipboard if any part is unacceptable | Pasting part of what was copied looks like success, and a mixed clipboard isn't what the user copied in Finder | Provisional |
| DEC-clipboard-3 | Another app's clipboard is retired, not cleared, after a move | Arbor only clears what it wrote; a second Paste would otherwise fail with "no longer exists" | Provisional |
| DEC-clipboard-4 | The plain text is full paths without quotes | The text is for pasting a path into a document or a shell prompt; Copy as Path keeps Explorer's quotes | Provisional |

## Known gaps

- Real Finder and other apps can't be driven in these runs, so no check has pasted into or out of a real Finder window.
  The stand-in writes the same standard types Finder documents, which is not proof. By hand: copy a file in Finder and
  Paste and ⌥⌘V in Arbor; Copy in Arbor and paste into Finder, TextEdit and Terminal; Cut in Arbor, paste into Finder
  and check the source is still there.
- A paste reads the list on the main thread: a large list takes under a second, but an owner that hangs while
  providing data can stall the window for as long as AppKit waits.
- After Undo of a move of another app's clipboard, Arbor doesn't offer that clipboard again until it changes.
- There is no Move entry in the item context menu ("Paste into folder"), only on the background and in the Edit menu.
