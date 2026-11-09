# Address entry (FE-006, FE-213)

Code: `Sources/Arbor/Features/AddressEntry/`, core logic in `Sources/ArborCore/PathCompletion.swift`, `PathListingQueue.swift`,
`ShellAddress.swift`, `AddressHandoff.swift`, `DirectoryLister.boundedEntries`, `MountPoints.volumeClass`, `PathResolver.localPath`, `RecentLocations.swift`, `AddressHistoryFile.swift`, `AddressHistoryStore.swift`, `PathCompletionHistory.swift`
(tests: `Tests/ArborCoreTests/PathCompletionTests.swift`, `AddressHistoryTests.swift`, `ShellAddressTests.swift`, `AddressHandoffTests.swift`, `Tests/ArborTests/AddressEntryAuditTests.swift`;
headless: `scripts/behavior-checks.sh address addresshistory addresshandoff`).

## Status

Explorer's own completion and `shell:` handling aren't observed (no Windows machine, DECISIONS open question 5). What is
built follows the published API behavior in `docs/research/windows11-reference.md` §1.9 and is proposed Mac behavior, not a parity claim.

| FE | Requirement | Status | How verified |
|---|---|---|---|
| FE-006 | Path completion and history | **Partial.** Completion is built: a dropdown of up to 12 rows under the field, only for plain local path forms, never changing the text unless a row is picked. History is built: typed and visited places are remembered across launches and feed the ▾ list and the dropdown. No parity claim until the Windows audit | Unit tests; headless `address` and `addresshistory` groups; list snapshots and `axdump` in light and dark; `l10naudit` and `axaudit` with pseudo-localization |
| FE-213 | Address commands and shell names | **Built (macOS boundary).** `shell:` names and Windows command words go to a Mac place, get a specific message, or, for the fixed table below, open a Mac tool after a visible question. Typed text is never passed to anything | Unit tests of every table row, the argument refusal and the routes; audit test forbidding `Process`, `NSWorkspace` and `SystemOpen` in the parsing files and text in the launcher; headless `address` and `addresshandoff` groups |

FE-079 keeps its boundary: device nodes have no Mac counterpart, and Control Panel and printers are hand-offs to System Settings, not Arbor pages.

## How completion stays safe

- **Typing is never blocked.** `PathCompletionQuery.parse` only builds strings, and the volume check reads the cached mount table. Listing runs on `SlowWorkQueue` lanes.
- **The list can't overwrite anything.** Down and Up move a highlight only. Return with no highlight submits exactly what was typed. A pick re-derives the query and, if it no longer matches the rows, submits the text unchanged.
- **Stale work can't surface.** Every render re-derives the query from the field. Late results only fill the cache. Cancelled results are dropped, including when a request joins a scan that was already cancelled.
- **A list never outlives its place.** It closes when the window's location changes (Back, tab switch) and on any mouse press outside the rows and the visible text, because toolbar buttons never take focus. The text stays; the next edit brings the list back.
- **A row leads to the item it names.** A candidate must not be a place keyword, must survive trimming, and must parse back to its folder plus its name.
- **The footer says what is true.** A complete listing with more matches says to keep typing. A partial one (entry cap, time limit or a read error) says only part of the folder could be read, because typing can't bring up names the scan never reached.
- **Links.** A symbolic link in the listing isn't followed: its row has no trailing slash and a document icon, and Return opens what it points at. Typing a path through a link lists the target. A folder opened through a link keeps the link's address for its items.
- **Limits**, one value per lane (`PathCompletionLane`):

| Lane | Debounce | Scan limit | Queue timeout | Entry cap | Scans in flight |
|---|---|---|---|---|---|
| Local | 0.12 s | 1.2 s | 1.5 s | 20,000 | 3 |
| Network | 0.35 s | 3 s | 4 s | 5,000 | 2 |

Automount entries get no listing. That covers autofs mounts and the entries macOS ships (`/home`, `/net`, `/Network/Servers`), which the mount table can't show for a path typed through their symbolic links. A symbolic link the user made into an automount can still trigger a mount; that happens off the main thread and is limited by the lane cap. A folder is classified by the path typed, so a link to a share uses the local lane's limits.

Cloud placeholders: the scan runs with dataless materialization turned off for its thread, so a placeholder folder gives no rows and downloads nothing.

Filtering is in memory on the main thread: about 5 ms for 20,000 long names when none match (release build, the worst case). Names that match but can't be offered are expensive to check, so the scan of a cached listing stops after 256 of them and reports more items; that case measures under 3 ms.

## History

`AddressHistoryStore` owns one list, shared by all windows, in `Application Support/Arbor/AddressHistory.json`:

```json
{"entries":["folder:/Users/me/Documents","home"],"version":1}
```

Entries are `Location.key` strings, newest first, at most 100 and 4 KB each; the file is read up to 1 MB. Searches are left out. The ▾ list shows the newest 12. The dropdown shows up to 4 folders under the text typed, in the form typed (`~/Doc` offers `~/Documents/Work/`), above the folder's own names and with a clock icon. A folder the listing already shows keeps its plain row. Hidden names follow the Hidden items setting.

Every address that opened arrives as a visit, so a typed one is recorded like any other. Text that failed to open is never kept. A network address loses any password when it is parsed (`NetworkAddress`), before it can reach the history.

- **Loading touches only the file.** It runs off the main thread, and entries become `Location`s from strings alone. `Location(key:)` states `isDirectory` on every URL, because without it Foundation asks the disk.
- **Bad input is harmless.** Damage starts an empty list, and a bad entry is skipped (not a string, too long, control characters, a search, or a path with `.`, `..` or empty components). No damaged copy is kept, because it would outlive Clear history. A file from a newer version is read but not rewritten.
- **Writes are coalesced.** A save follows 1 second after the last visit, and any pending one is written at exit. A visit before the load finishes is kept ahead of what was loaded, and nothing is written until then.
- **Missing folders are hidden, not forgotten.** A check runs off the main thread after a save and when ▾ opens, one at a time, on a queue of its own. Only paths the mount table calls local get an `lstat`; network and automount paths are never asked about. A hidden place returns when its drive does, and the check's result reaches the list only after it finishes, so a folder removed a moment ago can show once more.
- **Clear history** (Folder Options and Home) removes the file, cancels any pending save and drops a load or check already running.
- **Headless runs** have no file unless `ARBOR_STATE_DIR` is set, and then it is in that folder.

## `shell:` names

Names Arbor accepts (`ShellAddress.table`, one row per entry), not a claim about Windows. Typed text never forms a URL or an argument. Asked only after the resolver failed, so a real item with the same name wins.

| Name | Goes to |
|---|---|
| `desktop`, `downloads`, `personal`, `documents`, `my pictures`, `pictures`, `my music`, `music`, `my video`, `videos`, `movies` | The folder in the home folder |
| `profile` | Home folder |
| `userprofiles`, `public`, `appsfolder` | `/Users`, `/Users/Shared`, `/Applications` |
| `appdata` | `~/Library/Application Support` |
| `recent` | Home, whose Recent list is the counterpart (a message if that list is turned off) |
| `recyclebinfolder`, `mycomputerfolder`, `networkplacesfolder`, `libraries` | Trash, This Mac, Network, Libraries |
| `controlpanelfolder`, `printersfolder`, `connectionsfolder`, `startup`, `common startup`, `fonts` | A hand-off, below |
| `start menu`, `programs`, `common programs`, `sendto`, `windows`, `system`, `programfiles` | A message saying where to look, or that there is no counterpart |

`shell:::{…}` folder IDs and unknown names get their own message. Text that is shaped like a path keeps the resolver's own message.

## Hand-offs and command words

The whole inventory (`AddressHandoffTarget.table` and `ShellAddress`, exact matches, any letter case). Command words are consulted only when nothing by that name exists.

| Typed | Opens, after the question |
|---|---|
| `control`, `control.exe`, `shell:controlpanelfolder` | System Settings |
| `shell:printersfolder` | System Settings at Printers & Scanners |
| `shell:connectionsfolder` | System Settings at Network |
| `shell:startup`, `shell:common startup` | System Settings at Login Items |
| `shell:fonts` | Font Book |
| `cmd`, `cmd.exe`, `powershell`, `powershell.exe`, `pwsh`, `pwsh.exe`, `wt`, `wt.exe` | Terminal, at the window's current folder |
| `taskmgr`, `taskmgr.exe` | Activity Monitor |

| Typed | Answer |
|---|---|
| `notepad`, `calc`, `mspaint`, `regedit`, `explorer`, or any bare name ending `.exe`, `.bat`, `.cmd`, `.ps1`, `.msi` | Refused with the message that Arbor doesn't run commands |
| A hand-off word followed by anything (`cmd /c x`, `control foo`) | Refused: Arbor doesn't pass typed text to other apps. Starts nothing, asks nothing |
| A `shell:` name followed by anything (`shell:fonts x`) | Unknown name, so it is refused like any other |

- **Nothing typed gets through.** `AddressHandoffTarget` is a closed enum with no text in it; every bundle identifier and settings address is a constant in `AddressHandoff.swift`. The parsing files can't launch (audit test). `AddressHandoffLauncher`, in `Handoff/`, takes only the target and the window.
- **One question, every time.** A sheet names the app, and for Terminal the folder. Cancel is first and answers Escape. No button takes Return, the key that just sent the address. Nothing launches until Open is clicked. Cancel leaves the text in the field to edit.
- **Terminal needs a real folder.** It uses the path behind Open in Terminal, with the folder passed as a document. In an archive, the Trash, Network or a server, Home, This Mac, Gallery, Libraries or search results, it says why it can't run and doesn't ask. The folder comes from the window and is checked again after the answer, so a window that has moved on opens nothing.
- **Headless runs** ask and answer as usual (`button:`, `sheetkey:`). The `address handoff:` line in `log:` holds each question and answer, and `SystemOpen` only records the launch.

## Decisions

| ID | Decision | Alternatives | Reason |
|---|---|---|---|
| DEC-address-1 | Suggestions are a dropdown only; inline AutoAppend is not built | AutoAppend or ghost text, as the Windows API also offers | FE-006 forbids overwriting typed input, and appended text is exactly that risk |
| DEC-address-2 | Tab keeps moving focus and closes the list | Tab picks a row | Matches the API's default without `SHACF_USETAB`, and keeps FE-062 intact |
| DEC-address-3 | Return with no highlight submits the typed text, never the first row | Accept the top row | The user's text is what they asked for |
| DEC-address-4 | The first Escape closes the list and keeps the text; the next restores the location | One Escape does both | Dismissing suggestions shouldn't lose a long typed path. Proposed, not observed |
| DEC-address-5 | Listing never connects, mounts or downloads: no UNC, `smb://` or `file://` completion, no automount paths, no cloud materialization | Complete servers and shares | Typing must not cause network or download side effects |
| DEC-address-6 | One fixed table maps exact Windows words and `shell:` names to a closed set of Mac tools; each opens only after one question, words with arguments are refused, and the rest keep a specific message | Passing arguments on; launching without asking; only messages, which left the Mac tool one step further away; mapping names to the nearest folder | SPEC §5.2 asks for an explicit command interaction, and DEC-019 for the closest Mac equivalent. Typed text starts nothing and reaches nothing. Proposed, not observed |
| DEC-address-7 | `shell:` names and command words are checked only after the resolver fails | Check first | A real file or folder with that name always wins |
| DEC-address-8 | The session attaches through `WindowHooks.didCreate` rather than a new `Provided` point | A `Provided` factory like the search box | Nothing in core asks for a session, so a new point would add nothing |
| DEC-address-9 | No preference to turn suggestions off yet | Add a Folder Options toggle | Keeps the first version small; easy to add if wanted |
| DEC-address-10 | The history stores locations that opened, one list for typed and visited | Separate lists; saving the raw typed text | A typed address that opened is a visit anyway, and raw text could hold a typo or a password. Windows' own rules aren't observed, so no parity claim. Supersedes DEC-parity-7 |
| DEC-address-11 | Its own JSON file, not a preference | `Prefs` like recent searches | Reads off the main thread, and Clear history can remove it outright |
| DEC-address-12 | A folder that can't be found is hidden, not removed | Pruning on sight | An unplugged drive's places return with it; the 100-entry bound ages out the rest |
| DEC-address-13 | History rows appear with the folder's listing, not before | Showing them while the scan runs | One render path; a list that changes shape under the arrow keys is worse than a short wait |
| DEC-address-14 | No button in the hand-off question takes Return; Escape answers Cancel | Return answers Open; Return answers Cancel, which would leave Escape with no button | Return just sent the address, so a held key mustn't answer unread text. Same rule as a Windows shortcut's question |

## Known gaps

- **Two things the owner will notice.** Typing into `~/Documents/`, Desktop, Downloads, a network or removable volume can show the system's one-time privacy prompt, because listing is what triggers it; macOS can't report ahead of time whether access is granted. macOS 14 and later can also prompt for other apps' containers under `~/Library`.
- **Needs its own requirement.** `submitAddress` runs `PathResolver.resolve` and `onDiskSpelling` on the main thread on Return, so Return on a hung share can stall the window. That breaks the "no disk work on the main thread" rule. It predates this work and isn't made worse by it.
- **Not verified here:** a real hung SMB server and a real iCloud placeholder (simulated with `ARBOR_COMPLETION_DELAY` and a unit check of the I/O policy), and any comparison with real Explorer.
- A listing is not rescanned while the same folder is being typed. After a partial or stale listing, names the scan didn't reach can't appear until editing starts over, and a prefix that only such names match closes the list as if nothing matched.
- A thread blocked in the kernel on a hung mount can't be interrupted; work is limited by the lane caps, not killed.
- History keeps recording when Home's "Show recently used files" is off, as the session list did; that switch governs Home's lists. Whether it should also govern this is the owner's call.
- A remembered address is matched as spelled, so `/private/tmp/x` typed by hand doesn't find a history entry stored as `/tmp/x`.
- A path through a symbolic link to a share reads as local, so the existence check can wait on that share; it holds one background thread and stops later checks, and never the window.
- Network addresses (`smb://`, UNC) are in the ▾ list but not the dropdown, which only handles local path forms (DEC-address-5).
- Not built: Tab to complete, `shell:name\sub` paths, `shell:` names from the command line or Dock.
- The list isn't repositioned while the window resizes; it moves on the next keystroke (same as the search dropdown).
- Row clicks can't be driven headless (the panel ignores the mouse there); a click takes the same path as Return on a highlight. Presses outside the list are checked with a posted event, not a real pointer.
