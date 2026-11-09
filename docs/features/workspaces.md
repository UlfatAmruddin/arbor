# Saved workspaces (named tab sets)

Spec: FE-027 ("Proposed improvement"). Reference: none. File Explorer has no named tab sets, and windows11-reference.md only records that tabs aren't restored after closing, so nothing here claims parity (DEC-019).
Code: `Sources/ArborCore/Workspaces/`, `Sources/Arbor/Features/Workspaces/`, `Sources/Arbor/Window/TabState+Session.swift`.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-027 | Workspaces submenu in the "…" menu and the Window menu; the first row says it's an Arbor addition | Implemented | Scripted `menu:` checks |
| FE-027 | Save current tabs as a named workspace; saving under the same name asks, then replaces | Implemented | Unit tests, scripted sheets |
| FE-027 | Open: replace this window's tabs, or a new window; tabs that have gone are skipped and listed | Implemented | Unit and registration tests, scripted checks |
| FE-027 | Rename and delete (nothing on disk is touched except the list) | Implemented | Unit tests, scripted checks |
| FE-027 | Versioned, tolerant `Workspaces.json` | Implemented | Unit tests (`WorkspaceTests.swift`) |

The feature is optional in the plainest sense: nothing runs on disk beyond one small read at launch, no file exists until the first save, and it has no command bar button, shortcut or tab menu entry, so the FE-019 tab menu stays as audited.

## Behavior

- A workspace is one window's tabs: name, ordered list of `SessionTab`, active index. No window frame, panes, selection or scroll position.
- **Replace tabs in this window** doesn't ask, like closing tabs in Explorer; Back/Forward of the replaced tabs are lost. Only the active tab loads; the rest load when shown (FE-251).
- Opening runs one background check with a 2 second deadline (`WorkspaceOpenCheck`):

  | Finding | Result |
  |---|---|
  | Everything there | Tabs open |
  | Some folders or archives gone | The rest open; a sheet lists up to 6 names plus "…and N more"; a skipped active tab lands on its right neighbour, else the last |
  | Nothing available | An alert; no tab or window changes |
  | Check didn't finish in time | A sheet says a place isn't responding; no tab or window changes. Trying again joins the same background job, so a slow but live share succeeds |
  | The window gained a sheet during the check | No swap: a beep and a status message |
  | Vanishes after the check | The usual load failure path: status message, then Home |

- A missing place never edits the workspace, because an unplugged drive or disconnected share may come back. Saving again under the same name removes it.
- A window with more than 40 tabs, or tabs whose address is over 8192 bytes, saves what fits and says how many were left out in the status bar.

## File format

`Application Support/Arbor/Workspaces.json`, beside `Session.json`, sorted keys:

```json
{"version":1,"workspaces":[{"activeTab":0,"id":"<uuid>","name":"Work","tabs":[{"ascending":true,"back":[],"foldersFirst":true,"forward":[],"location":"folder:/Users/me/Projects","sortKey":"name","viewMode":"details"}]}]}
```

| What's in the file | What happens |
|---|---|
| Not a regular file (symlink, FIFO, folder), the open or read fails, or over 4 MiB | Read-only session, file untouched |
| Empty, not JSON, or (at `version` 1 or below) the top level isn't an object with a `workspaces` list | Moved to `Workspaces.damaged.json`; starts empty |
| `version` above 1 | Shown as far as it parses, which may be nothing if the shape changed; read-only, never moved or rewritten |
| `version` missing or not an integer | Treated as 1 |
| One bad workspace or tab, or anything over a limit, or a repeated name | Skipped and counted; original bytes copied to `Workspaces.damaged.json` first |
| Unknown keys | Ignored |
| Missing or mistyped optional tab field | Default value |
| Missing, invalid or repeated `id` | A new UUID |
| A name needing cleanup | Cleaned; skipped only if nothing usable remains |
| `back` / `forward` | Discarded |
| A location key this version can't parse | Kept in the file for a newer Arbor; reported when opened |

Any later format must stay a top-level JSON object with an integer `version`: that is all an older Arbor needs to leave the file alone.

Limits: 100 workspaces, 40 tabs each, 8192 bytes per location key, 80 characters per name, 4 MiB per file. An edit that would pass the file limit is refused before memory changes, so Arbor can't write a file it would reject at the next launch.

## Decisions

Statuses follow the project log: provisional unless the owner confirmed them.

- **DEC-workspaces-1** Back and Forward are never saved. "Clear Arbor history" must stay complete, and a named set is a list of places, not a browsing trail. The list itself is user-created like Quick access pins, so Clear history leaves it alone.
- **DEC-workspaces-2** Location keys are parsed inside the deadline, off the main thread. `Location(key:)` makes file URLs, and `URL(fileURLWithPath:)` examines the disk for a path without a trailing slash, so parsing first on the main thread would freeze on a dead mount before the check began. The plan hands the parsed `Location` values to the main thread, which never parses a key. This also covers search scopes, which have no availability check of their own.
- **DEC-workspaces-3** A check that misses its deadline changes nothing. Opening the tabs anyway would run `displayName` on the main thread for every title, which is the freeze the deadline exists to stop.
- **DEC-workspaces-4** Nothing a rewrite would destroy goes unprotected: a damaged file is renamed aside in one `rename(2)`, a partly read file is copied aside at load, and if either fails the session is read-only. There is one copy slot; a later problem replaces it.
- **DEC-workspaces-5** Every change goes through `WorkspaceStore.commit`, the single place that refuses edits while read-only and refuses a result that wouldn't fit. The menu's disabled rows are a courtesy on top of it.
- **DEC-workspaces-6** The store lives in ArborCore with injected queues and file URL, so the rules above are unit-tested without a window.
- **DEC-workspaces-7** The check's result is the finished plan, not a shared list of paths. The job key includes the tabs, so a retry joins only a job for the same tabs, and a workspace saved over during a slow check starts a new one.
- **DEC-workspaces-8** Saved view mode and sort only take effect for tabs that aren't folders. For a folder, per-folder views (FE-052) apply on first display and always resolve to something, exactly as for `Session.json`.
- **DEC-workspaces-9** Rows use sentence case in both menus, like the Window menu's other Arbor submenus. An "update this workspace" command isn't offered: saving under the same name does that and asks first.
- **DEC-workspaces-10** A file over 4 MiB is left in place, read-only, rather than moved aside. Reading its `version` would mean parsing past the limit, no version of Arbor writes one that large today, and only a file known to be version 1 or older may be moved.

## Script steps

`workspace:save|replace|open|delete|deletesheet|renamesheet:<name>`, `workspace:rename:<old>=<new>`, `workspace:typename:<text>` (sets the name field of the open sheet), the wait step `workspacesready` (loaded, no check running), and a `workspaces:` line in `log:`. The `workspaces` group of `scripts/behavior-checks.sh` runs them with `ARBOR_STATE_DIR`.

## Known gaps

- macOS limit: a stat on a hung network mount can't be cancelled. Arbor stops waiting after 2 seconds, but that one background job stays blocked until the system returns.
- macOS limit: an existence check can't tell deleted, moved, unmounted and permission-denied apart, so the message says "moved, deleted or disconnected" rather than guessing.
- Reconnecting unmounted shares or remounting drives on open isn't attempted; those tabs are reported as unavailable.
- Two running copies of Arbor: the last write wins.
- A file over 4 MiB keeps workspaces read-only until it's removed by hand; the menu says the file can't be read.
- Not covered headless: pointer navigation of the nested submenu, a real hung mount (the deadline is tested with an injected slow check), and images of the alert sheets, whose text is checked through `sheetlog:` instead.
- No import, export, sharing or auto-update of a workspace; no opening at launch.
