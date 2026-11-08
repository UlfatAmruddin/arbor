# Testing Arbor

## 1. Unit tests (logic)
```bash
scripts/test.sh
```
Put logic in `Sources/ArborCore` and test it with Swift Testing in `Tests/ArborCoreTests`.
Tests must use disposable fixture folders (`Fixture` in `FileSystemTests.swift`), never real user files or the real Trash.
`scripts/build-app.sh debug` must build with zero warnings.

## 2. Scripted UI checks (the real app)
`Sources/Arbor/DebugScript.swift` drives the live UI through the same command registry and responder chain as the menus.
Always run headless so nothing appears on screen:

```bash
scripts/build-app.sh debug
ROOT=$(mktemp -d); FX="$ROOT/fixture"; mkdir -p "$FX"; echo hi > "$FX/a.txt"
ARBOR_HEADLESS=1 ARBOR_APPEARANCE=dark \
ARBOR_SCRIPT="wait:1;select:a.txt;click:edit.copy;event;click:edit.paste;event;wait:1.5;log:$ROOT/state.txt;snapshot:$ROOT/shot.png;quit" \
  build/Arbor.app/Contents/MacOS/Arbor "$FX"
cat "$ROOT/state.txt"
```

Environment:
- `ARBOR_HEADLESS=1`: invisible, click-through window, no Dock icon. Preferences (pins, view mode, sort, panes) go to a throwaway domain that `quit` deletes, and window/split/column geometry is neither read nor saved, so runs never change the user's settings. Nothing outside Arbor's windows opens either: files, apps, Finder, Terminal, Mail, the share picker, Quick Look, settings pages, the desktop picture and disk images are only logged (`log:` → `system open: …`; everything goes through `Support/SystemOpen.swift`, enforced by `SystemOpenAuditTests`).
- `ARBOR_APPEARANCE=light|dark`: forces the appearance (check both).
- The path argument opens that folder; without it the window opens Home.

Steps (separated by `;`; the first `:` separates a step from its argument):

| Step | Does |
|---|---|
| `wait:1.5` | pause (seconds) |
| `event` | post an event boundary (undo grouping closes per event); put it after each user action |
| `select:a.txt\|b.md` | select rows by name in the active tab (empty = none) |
| `click:<command id>` | perform a registry command with the active tab's context, e.g. `click:edit.copy`, `click:file.newFolder`, `click:view.previewPane`, `click:tab.closeRight` |
| `action:cut:` | send a selector through the responder chain (`undo:` etc.) |
| `newtab` / `closetab` / `duptab` / `detachtab` | tab commands on the active tab |
| `tab:N` / `movetab:FROM:TO` | select tab N; move a tab (1-based) |
| `location:home\|thismac\|gallery\|network\|trash\|<path>\|<location key>` | navigate the active tab |
| `back` / `forward` / `up` / `refresh` | navigation |
| `view:details\|largeIcons\|…` | set the view mode (unregistered modes show Details; `log` says so) |
| `type:New name` / `enter` / `escape` | edit the focused text field (rename, address) |
| `button:Keep Both` | click a button in the window's sheet or modal alert |
| `search:rep` | type into the search box |
| `address:~/Documents` | submit text through the address bar |
| `log:/path` | append windows, tab titles, active tab, location key, view mode, rows, selection, status bar, history, breadcrumb, command bar and status-bar toggle states, panes, navigation tree, frames |
| `crumbs:/path` | append breadcrumb segments, collapsed segments and every chevron's menu entries |
| `menu:<which>:/path` | append a menu's titles, shortcuts, checks and disabled states. `<which>`: `item`, `background`, `tree:<row>`, `tab:<n>`, `new`, `sort`, `view`, `seemore`, `main:<title>` |
| `hittest:x,y:/path` | append the view class under a window point (top-left origin), e.g. to prove the tab row gets clicks |
| `undostate:/path` | append the undo stack state |
| `snapshot:/path.png` | draw the window (title bar included) into a PNG; `snapshotlayer:` renders the layer tree instead |
| `quit` | delete the headless preferences domain and exit |
| `terminate` | quit the way "Quit Anyway" does while jobs run (journals kept for the next launch) |

Features add steps and log lines from their own files: `DebugScript.registerStep("name") { arg, window in … }` and `DebugScript.registerLogger { window in "…" }`.
A step that must hold the script until something finishes (a folder load, a copy) registers with `DebugScript.registerWaitStep("name") { arg, window, elapsed in … }`; it is polled until it returns true.

## 3. Performance benchmarks
`scripts/bench.sh` runs the memory and responsiveness workloads headless on generated fixtures; `scripts/bench.sh --check`
fails when a result exceeds its budget. Steps (`memlog:`, `nav:`, `scroll:`, `stalls:`…), budgets and results: docs/PERFORMANCE.md.
On slower hardware, scale the budgets instead of editing `scripts/bench-budgets.txt`: `BENCH_TOLERANCE=3` multiplies the
time budgets (ms, stalls, CPU) and `BENCH_MEMORY_TOLERANCE=1.5` the memory budgets (both default 1; counts such as
`search.churn1.stale` never scale). The factors are recorded in `environment.txt` and shown next to each budget.

Rules of thumb:
- Start with `wait:1` so the first location has loaded.
- Use a unique `mktemp -d` fixture and output paths per run; several test runs may happen at once (the suites in §6 take turns).
- Read the PNGs to check visuals, in light and dark.
- End scripts with `quit`. Never leave a test app running, headless or not.
- Rendering note (macOS 26): a custom `NSTableHeaderView` or header-cell subclass stops table rows from drawing (on screen and in snapshots). Style headers through the stock cell's attributed title instead.

## 3. Accessibility, keyboard and localization checks
Steps: `axdump:/path` (accessibility tree as VoiceOver sees it), `key:shift+F10` (keys through the real keyboard path), `focus:/path`, `mouse:3|4`, `swipe:back|forward`, `compose:<text>` (input-method marked text), `announcements:/path`, `contextkey:/path`, `textsize:130`,
`l10naudit:/path` (text in every window that isn't from the string table, and clipped labels; use with `ARBOR_PSEUDO_LOC=1`),
`axaudit:/path` (controls VoiceOver would read without a name, empty rows), `composecommit:<text>`, `windowactive:0|1`.
Environment: `ARBOR_PSEUDO_LOC=1` (accented, longer strings), `ARBOR_RTL=1` (right-to-left layout), `ARBOR_CONTRAST=1`, `ARBOR_REDUCE_MOTION=1`, `ARBOR_TEXT_SIZE=150`. Keep the string table current with `scripts/extract-strings.sh` (`--check` verifies). Details: docs/features/accessibility.md.

## 5. Acceptance scenarios
`scripts/acceptance.sh [T01 …]` runs the task scenarios T01–T30 of docs/SPEC.md §17.5 headless, each on its own fixture,
and prints pass / FAIL / partial per scenario (`ACCEPT_KEEP=1` keeps the logs and snapshots). Results, and what each
scenario can't show headless: docs/ACCEPTANCE.md. Steps it adds: `menukey:cmd+x` (a menu shortcut, delivered the way its
menu item delivers it) and a `clipboard:` line in `log:` (pasteboard names, copy or move, items drawn as cut).

## 6. The scripted suites and continuous integration
`scripts/behavior-checks.sh`, `scripts/core-checks.sh`, `scripts/acceptance.sh` and `scripts/bench.sh` share
`scripts/lib/app-bundle.sh`, which adds three guards before the first check:

- **Stale bundle.** The suites test `build/Arbor.app`, not the sources. When any file under `Sources/` or `Resources/`, or
  `Package.swift` / `Package.resolved`, is newer than `build/Arbor.app/Contents/MacOS/Arbor`, a suite stops with exit 2
  and names the newer files. `ARBOR_REBUILD=1` rebuilds instead (debug; release for `bench.sh --skip-build`);
  `ARBOR_ALLOW_STALE=1` runs the old bundle anyway, with a warning. `bench.sh` without `--skip-build` builds release itself.
- **One suite at a time.** Two suites at once compete for the CPU, so their timed waits and the benchmarks go wrong, and
  `bench.sh` or `ARBOR_REBUILD` would replace `build/Arbor.app` under the other suite. Each suite holds the lock directory
  `$TMPDIR/arbor-app-suites.lock` (it names the suite, process and start time) for its whole run; a second suite says
  what it is waiting for and starts when the first one ends. `ARBOR_LOCK_WAIT=<seconds>` limits the wait (default 3600;
  `0` exits at once with code 2), `ARBOR_LOCK_DIR` moves the lock. A lock whose process no longer runs is taken over. The
  app itself keeps each headless run apart (preferences domain, pasteboards, Trash, journal and history are per process).
- **Smoke launch.** The app is started headless once; if it can't start here at all (no window server session, broken
  bundle), the suite stops with exit 2 and the app's output instead of reporting every check as failed.

`ARBOR_KEEP_FAILED=<dir>` makes all three check suites move the folder of each failing group or scenario (its `log:`
files, snapshots and fixture) into `<dir>`, and remove the rest as usual.

Checks that can't run in an environment say so in a `skip` line with the reason, and acceptance marks the scenario
`partial`: no disk image (`hdiutil` failed: behavior `undomove`, T13, the disk part of T26), a case-sensitive temporary
volume (QA-CORE-2), running as root, where permissions aren't enforced (T18, T21, T23).

### What CI runs
`.github/workflows/ci.yml` runs three jobs in parallel on every push and pull request, on GitHub's `macos-26` runner
(the runner is logged in to a GUI session, which the headless app still needs for its window server connection):

| Job | Steps | Artifacts |
|---|---|---|
| `build-and-test` | debug build (fails on any warning), `scripts/test.sh`, `scripts/make-dmg.sh --universal` | the unsigned disk image |
| `app-checks` | `scripts/build-app.sh debug`, then `scripts/list-extension-points.sh` (fails on a registration error), behavior-checks, core-checks and acceptance; each runs even after an earlier one failed | on failure: `build/logs/` (each suite's output) and `build/failed/` (folders of the failing checks) |
| `performance` | `scripts/bench.sh --check --quick` with `BENCH_TOLERANCE=3`, `BENCH_MEMORY_TOLERANCE=1.5` | always: the results, environment and per-run logs |

The tolerances exist because hosted runners are virtual machines with a few shared cores and no GPU of their own; retune
them from the uploaded results when the runner image changes, and keep `scripts/bench-budgets.txt` for the reference Mac.

### Reproducing a CI job locally
Run the same commands from a clean checkout of the commit (no other suite running):

```bash
# app-checks
scripts/build-app.sh debug && mkdir -p build/logs
export ARBOR_KEEP_FAILED="$PWD/build/failed" ARBOR_LOCK_WAIT=0
scripts/list-extension-points.sh > build/logs/extension-points.txt
scripts/behavior-checks.sh 2>&1 | tee build/logs/behavior-checks.txt
scripts/core-checks.sh     2>&1 | tee build/logs/core-checks.txt
scripts/acceptance.sh      2>&1 | tee build/logs/acceptance.txt

# performance (builds build/Arbor.app as release: rebuild debug before the checks again)
BENCH_TOLERANCE=3 BENCH_MEMORY_TOLERANCE=1.5 scripts/bench.sh --check --quick --out build/bench/ci

# build-and-test
scripts/build-app.sh debug 2>&1 | grep "warning:"; scripts/test.sh && scripts/make-dmg.sh --universal
```
On a developer Mac the budgets apply as they are: run `scripts/bench.sh --check` without the tolerances.
