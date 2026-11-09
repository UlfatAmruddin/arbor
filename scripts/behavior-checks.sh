#!/usr/bin/env bash
# Headless regression checks for undo/redo, selection identity, window-modal alerts, sheet queueing,
# recovery of queued jobs, headless safety, breadcrumb drops and middle-clicks, and explained refusals
# (docs/features/qa-core.md, qa-places.md, file-operations.md, item-actions.md, cloud.md).
# Usage: scripts/build-app.sh debug && scripts/behavior-checks.sh [name…]   (no names = all groups)
#   ARBOR_KEEP_FAILED=<dir>   move the folder (logs, fixture) of each group with a failure into <dir>
#   Stale-bundle guard, one-suite-at-a-time lock, ARBOR_REBUILD: scripts/lib/app-bundle.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/app-bundle.sh
arbor_prepare_app behavior-checks.sh debug
APP="$ARBOR_APP_BIN"
FAILED=0
GROUP_FAILED=0
GROUPS_WANTED=" ${*:-all} "

want() { [[ "$GROUPS_WANTED" == *" all "* || "$GROUPS_WANTED" == *" $1 "* ]]; }

# discard <group> <folder…>: remove a group's folders, or keep them in $ARBOR_KEEP_FAILED after a failure.
discard() {
  local group="$1" d; shift
  if [ "$GROUP_FAILED" = 1 ] && [ -n "${ARBOR_KEEP_FAILED:-}" ]; then
    mkdir -p "$ARBOR_KEEP_FAILED"
    for d in "$@"; do chmod -R u+rwx "$d" 2>/dev/null; mv "$d" "$ARBOR_KEEP_FAILED/$group-$(basename "$d")"; done
    echo "kept  $group → $ARBOR_KEEP_FAILED"
  else
    rm -rf "$@"
  fi
  GROUP_FAILED=0
}

run() {   # run <root> <start folder> <script> [VAR=value…]
  local root="$1" start="$2" script="$3"; shift 3
  env ARBOR_HEADLESS=1 ARBOR_TEST_TRASH="$root/trash" ARBOR_JOURNAL_DIR="$root/journal" ARBOR_HISTORY_FILE="$root/history.json" \
    ARBOR_SCRIPT="$script" "$@" perl -e 'alarm shift; exec @ARGV' 120 "$APP" "$start" >/dev/null 2>&1
}

check() {   # check <name> <file> <expected line>
  if [ -f "$2" ] && grep -qxF -- "$3" "$2"; then echo "pass  $1"; else
    echo "FAIL  $1: expected “$3”"; [ -f "$2" ] && grep -E "^(rows|selected|location|sheet|undo action|redo action|operations|system open)" "$2" | sed 's/^/        /'; FAILED=1; GROUP_FAILED=1; fi
}

contains() {   # contains <name> <file> <fixed text>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then echo "pass  $1"; else
    echo "FAIL  $1: expected to contain “$3”"
    [ -f "$2" ] && grep -E "^(sheet|selected|rows|system open|queue|operations|undo action|redo action|consistency: recent)" "$2" | sed 's/^/        /'
    FAILED=1; GROUP_FAILED=1; fi
}

lacks() {   # lacks <name> <file> <fixed text>
  if [ -f "$2" ] && ! grep -qF -- "$3" "$2"; then echo "pass  $1"; else
    echo "FAIL  $1: did not expect “$3”"; FAILED=1; GROUP_FAILED=1; fi
}

fact() {   # fact <name> <shell test…>
  local name="$1"; shift
  if "$@"; then echo "pass  $name"; else echo "FAIL  $name"; FAILED=1; GROUP_FAILED=1; fi
}

# QA-CORE-6: Undo and Redo keep each action's own name, however often they alternate.
if want undo; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F/sub"
  for n in a b c d e; do echo "$n" > "$R/F/$n.txt"; done
  # A 1×1 PNG, for Rotate.
  echo "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAEElEQVR4nGP4z8DAwMDAAAAJ/gH/4cXYyAAAAABJRU5ErkJggg==" | base64 -D > "$R/F/p.png"
  S="wait:1"
  S+=";click:file.newFolder;event;wait:1;escape;event;wait:0.5;action:undo:;event;wait:1;log:$R/nf1.txt;action:redo:;event;wait:1;log:$R/nf2.txt;action:undo:;event;wait:1;action:redo:;event;wait:1;log:$R/nf3.txt"
  S+=";select:a.txt;click:file.trash;event;wait:1;action:undo:;event;wait:1;log:$R/tr1.txt;action:redo:;event;wait:1;log:$R/tr2.txt"
  S+=";select:b.txt;click:file.rename;event;type:bb.txt;enter;event;wait:1;action:undo:;event;wait:1;log:$R/rn1.txt;action:redo:;event;wait:1;log:$R/rn2.txt"
  S+=";click:file.new.txt;event;wait:1;escape;event;wait:0.5;action:undo:;event;wait:1;action:redo:;event;wait:1;log:$R/nt.txt"
  S+=";select:p.png;click:image.rotateRight;event;wait:1.5;action:undo:;event;wait:1.5;log:$R/ro1.txt;action:redo:;event;wait:1.5;log:$R/ro2.txt"
  S+=";select:c.txt|d.txt;click:file.rename;event;type:Doc;enter;event;wait:1.5;action:undo:;event;wait:1;log:$R/br1.txt;action:redo:;event;wait:1;log:$R/br2.txt"
  S+=";select:e.txt;click:edit.copy;event;location:$R/F/sub;wait:1;click:edit.paste;event;wait:2;action:undo:;event;wait:2;log:$R/cp1.txt;action:redo:;event;wait:1.5;log:$R/cp2.txt"
  S+=";quit"
  run "$R" "$R/F" "$S"
  check "undo of New folder offers redo New Folder" "$R/nf1.txt" "redo action: New Folder"
  check "redo of New folder keeps its name" "$R/nf2.txt" "undo action: New Folder"
  check "New folder name after a second round" "$R/nf3.txt" "undo action: New Folder"
  check "undo of Move to Trash offers redo" "$R/tr1.txt" "redo action: Move to Trash"
  check "redo of Move to Trash" "$R/tr2.txt" "undo action: Move to Trash"
  check "undo of Rename offers redo Rename" "$R/rn1.txt" "redo action: Rename"
  check "redo of Rename" "$R/rn2.txt" "undo action: Rename"
  check "redo of New Text Document keeps its name" "$R/nt.txt" "undo action: New Text Document"
  check "undo of Rotate Right offers redo Rotate Right" "$R/ro1.txt" "redo action: Rotate Right"
  check "redo of Rotate Right" "$R/ro2.txt" "undo action: Rotate Right"
  check "undo of a batch rename offers redo Rename" "$R/br1.txt" "redo action: Rename"
  check "redo of a batch rename" "$R/br2.txt" "undo action: Rename"
  check "undo of Copy offers redo Copy" "$R/cp1.txt" "redo action: Copy"
  check "redo of Copy" "$R/cp2.txt" "undo action: Copy"
  discard undo "$R"
fi

# QA-CORE-5: Undo of a move from another volume runs as a background job (progress, cancel), not on the main thread.
if want undomove; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/A" "$R/mnt"
  if hdiutil create -size 24m -fs HFS+ -volname ArborUndo -quiet "$R/v.dmg" && \
     hdiutil attach -nobrowse -noautoopen -quiet -mountpoint "$R/mnt" "$R/v.dmg"; then
    dd if=/dev/zero of="$R/A/big.bin" bs=1048576 count=4 2>/dev/null
    echo keep > "$R/A/small.txt"
    run "$R" "$R/A" "wait:1;opstart:move:$R/A/big.bin|$R/A/small.txt:$R/mnt;wait:8;log:$R/m1.txt;action:undo:;event;wait:0.6;log:$R/m2.txt;wait:9;log:$R/m3.txt;quit" \
      ARBOR_TRANSFER_THROTTLE=1500000
    check "move to the other volume finished" "$R/m1.txt" "operations: none"
    contains "undo of the move runs as a job" "$R/m2.txt" "operations: move phase="
    check "undo finished" "$R/m3.txt" "operations: none"
    fact "items are back in the original folder" test -f "$R/A/big.bin" -a -f "$R/A/small.txt"
    fact "nothing left on the other volume" test ! -e "$R/mnt/big.bin" -a ! -e "$R/mnt/small.txt"
    check "redo is offered" "$R/m3.txt" "redo action: Move"
    hdiutil detach -force -quiet "$R/mnt" >/dev/null 2>&1
  else
    echo "skip  undo of a cross-volume move (no disk image)"
  fi
  discard undomove "$R"
fi

# Selection identity: duplicated tabs and the selection after a delete keep exactly the chosen items.
if want selection; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/P/one" "$R/P/two" "$R/P/three"
  for d in one two three; do echo "$d" > "$R/P/$d/a.txt"; done
  echo b > "$R/P/three/b.txt"
  run "$R" "$R/P" "wait:1;search:txt;event;wait:3;select:b.txt;wait:0.5;log:$R/s0.txt;click:file.trash;event;wait:3;log:$R/s1.txt;quit"
  check "search results listed" "$R/s0.txt" "selected: b.txt"
  check "after a delete only one neighbour is selected" "$R/s1.txt" "selected: a.txt"
  R2=$(arbor_mktemp_dir); mkdir -p "$R2/trash" "$R2/P/one" "$R2/P/two"
  for d in one two; do echo "$d" > "$R2/P/$d/readme.txt"; done
  run "$R2" "$R2/P" "wait:1;search:readme;event;enter;wait:3;log:$R2/d0.txt;duptab;wait:3;log:$R2/d1.txt;quit"
  check "one same-named result selected" "$R2/d0.txt" "selected: readme.txt"
  check "a duplicated tab keeps one same-named item" "$R2/d1.txt" "selected: readme.txt"
  discard selection "$R" "$R2"
fi

# Rename prompts are window-modal sheets that scripts can answer.
if want sheets; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F"; echo 1 > "$R/F/a.txt"; echo 2 > "$R/F/b.txt"; echo 3 > "$R/F/c.txt"
  run "$R" "$R/F" "wait:1;select:a.txt;click:file.rename;event;type:a.md;enter;wait:1;log:$R/x1.txt;sheetlog:$R/x1.txt;button:Use .md;wait:1.5;log:$R/x2.txt;select:b.txt;click:file.rename;event;type:b.rtf;enter;wait:1;button:Cancel;wait:1;escape;wait:1;log:$R/x3.txt;select:c.txt;click:file.rename;event;type:b.txt;enter;wait:1;log:$R/x4.txt;sheetlog:$R/x4.txt;button:OK;wait:1;escape;wait:1;log:$R/x5.txt;quit"
  check "extension change asks in a sheet" "$R/x1.txt" "sheet: true"
  contains "extension prompt wording" "$R/x1.txt" "Change the file name extension?"
  check "Use .md renamed the file" "$R/x2.txt" "rows: a.md | b.txt | c.txt"
  check "Cancel kept the name" "$R/x3.txt" "rows: a.md | b.txt | c.txt"
  check "a rename conflict is reported in a sheet" "$R/x4.txt" "sheet: true"
  contains "conflict wording" "$R/x4.txt" "Couldn't rename “c.txt”."
  check "conflict renamed nothing" "$R/x5.txt" "rows: a.md | b.txt | c.txt"
  check "no sheet left open" "$R/x5.txt" "sheet: false"
  discard sheets "$R"
fi

# qa-places #12: a second network error waits for the first sheet instead of stacking or going app-modal.
if want network; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F" "$R/state"
  run "$R" "$R/F" "wait:1;address:\\\\nope-one\\a;wait:2;address:\\\\nope-two\\b;wait:2;address:\\\\nope-one\\a;wait:2;sheetlog:$R/n1.txt;button:Cancel;wait:1;sheetlog:$R/n2.txt;button:Cancel;wait:1;sheetlog:$R/n3.txt;log:$R/n4.txt;quit" \
    ARBOR_FAKE_NETWORK=1 ARBOR_STATE_DIR="$R/state"
  contains "first error shows" "$R/n1.txt" "nope-one"
  contains "second error waits its turn" "$R/n2.txt" "nope-two"
  contains "an identical error isn't shown twice" "$R/n3.txt" "sheet: (none)"
  check "nothing left open" "$R/n4.txt" "sheet: false"
  discard network "$R"
fi

# Headless runs never open anything outside Arbor's windows: requests are logged instead.
if want headless; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F"; echo 1 > "$R/F/a.txt"
  run "$R" "$R/F" "wait:1;select:a.txt;click:file.open;wait:0.5;click:file.showInFinder;wait:0.5;click:file.openInTerminal;wait:0.5;log:$R/h.txt;quit"
  P=$(cd "$R/F" && pwd -P)   # items are listed under the physical path (/private/var/…)
  contains "opening a file is only logged" "$R/h.txt" "system open: open $P/a.txt"
  contains "Show in Finder is only logged" "$R/h.txt" "reveal $P/a.txt"
  contains "Open in Terminal is only logged" "$R/h.txt" "Terminal"
  discard headless "$R"
fi

# consistency.md: opening a file shortcut records its target in Recent.
if want recent; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F" "$R/state"; echo 1 > "$R/F/report.txt"
  run "$R" "$R/F" "wait:1;select:report.txt;click:file.createShortcut;event;wait:1.5;escape;wait:0.5;log:$R/r0.txt;select:report.txt - Shortcut;click:file.open;wait:1;log:$R/r1.txt;quit" \
    ARBOR_STATE_DIR="$R/state"
  contains "shortcut created" "$R/r0.txt" "report.txt - Shortcut"
  contains "target opened (logged)" "$R/r1.txt" "open $(cd "$R/F" && pwd -P)/report.txt"
  contains "target recorded in Recent" "$R/r1.txt" "consistency: recent=[report.txt]"
  discard recent "$R"
fi

# file-operations.md: a job still waiting in the queue at quit is offered again at the next launch.
if want queue; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/A" "$R/B"
  dd if=/dev/zero of="$R/A/one.bin" bs=1048576 count=6 2>/dev/null; echo two > "$R/A/two.txt"
  run "$R" "$R/A" "wait:1;opqueue:limit=1;opstart:copy:$R/A/one.bin:$R/B;wait:0.5;opstart:copy:$R/A/two.txt:$R/B;wait:1;log:$R/q0.txt;terminate" \
    ARBOR_TRANSFER_THROTTLE=500000
  contains "second job waits" "$R/q0.txt" "queue:"
  fact "quit left the waiting job's journal" test "$(ls "$R/journal" 2>/dev/null | wc -l | tr -d ' ')" -ge 1
  fact "waiting job wasn't copied" test ! -e "$R/B/two.txt"
  run "$R" "$R/A" "wait:3;sheetlog:$R/q1.txt;button:Dismiss;wait:1.5;sheetlog:$R/q2.txt;button:Start;wait:3;log:$R/q3.txt;quit"
  cat "$R/q1.txt" "$R/q2.txt" > "$R/q12.txt" 2>/dev/null
  contains "waiting job is offered again" "$R/q12.txt" "was waiting to start"
  fact "Start ran the waiting job" test -f "$R/B/two.txt"
  discard queue "$R"
fi

# item-actions.md (FE-023, FE-107): breadcrumb segments take drops and middle-clicks, by the tree's rules.
if want breadcrumb; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/P/Mid/Leaf" "$R/P/Other"
  P=$(cd "$R" && pwd -P); M="$P/P/Mid"; L="$M/Leaf"; O="$P/P/Other"
  KM="${M#/private}"; KL="${L#/private}"   # location keys and crumbs drop /private
  for n in x y z t v; do echo "$n" > "$O/$n.txt"; done
  echo leaf > "$L/a.txt"; echo old > "$M/c.txt"; echo new > "$O/c.txt"; echo u > "$M/u.txt"

  # What counts as a target: visible folder segments only, one at a time.
  S="wait:1;dragfiles:plain:$O/x.txt;crumbhover:Mid;crumbstate:$R/t1.txt;crumbhover:Leaf;crumbstate:$R/t2.txt;crumbhover:chevron:Mid;crumbstate:$R/t3.txt"
  S+=";crumbhover:Mid;crumbhover:-;crumbstate:$R/t4.txt;crumbhover:Mid;crumbleave;crumbstate:$R/t5.txt"
  S+=";crumbhover:Leaf;crumbstate:$R/t13.txt;crumbhover:copyonly:=;crumbstate:$R/t14.txt;crumbleave"
  S+=";dragfiles:plain:$M;crumbhover:Leaf;crumbstate:$R/t6.txt;crumbdrop;crumbstate:$R/t7.txt"
  S+=";dragfiles:plain:$O/x.txt;click:nav.address;wait:0.3;crumbhover:Mid;crumbstate:$R/t8.txt;crumbleave;escape;wait:0.3"
  S+=";location:home;wait:1;crumbhover:Home;crumbstate:$R/t9.txt;crumbleave"
  S+=";location:thismac;wait:1;crumbhover:This Mac;crumbstate:$R/t10.txt;crumbleave"
  S+=";location:$P/P;wait:1;openitem:z.zip;wait:1.5;crumbhover:z.zip;crumbstate:$R/t11.txt;crumbleave"
  S+=";location:$P/P;wait:1;search:nothing-matches;event;enter;wait:2;crumbhover:Search Results in P;crumbstate:$R/t12.txt;crumbleave;quit"
  ditto -c -k "$O" "$P/P/z.zip"
  run "$R" "$L" "$S"
  contains "a folder segment is highlighted" "$R/t1.txt" "drop target: Mid"
  check "a same-volume drag moves" "$R/t1.txt" "last drag: operation 16"
  contains "the highlight follows the pointer" "$R/t2.txt" "drop target: Leaf"
  lacks "only one target at a time" "$R/t2.txt" "drop target: Mid"
  lacks "a chevron is no target" "$R/t3.txt" "drop target"
  check "a chevron refuses" "$R/t3.txt" "last drag: operation 0"
  lacks "empty space is no target" "$R/t4.txt" "drop target"
  lacks "leaving clears the highlight" "$R/t5.txt" "drop target"
  check "the same folder offers a move" "$R/t13.txt" "last drag: operation 16"
  check "and a copy once the source only allows copying" "$R/t14.txt" "last drag: operation 1"
  check "a folder can't drop on its own descendant" "$R/t6.txt" "last drag: operation 0"
  lacks "no highlight on its own descendant" "$R/t6.txt" "drop target"
  check "and the drop is refused" "$R/t7.txt" "last drag: accepted false"
  lacks "no target while typing an address" "$R/t8.txt" "drop target"
  check "Home takes no drop" "$R/t9.txt" "last drag: operation 0"
  check "This Mac takes no drop" "$R/t10.txt" "last drag: operation 0"
  contains "an archive is on screen" "$R/t11.txt" "z.zip"
  check "an archive segment takes no drop" "$R/t11.txt" "last drag: operation 0"
  contains "search results are on screen" "$R/t12.txt" "Search Results in P"
  check "a search segment takes no drop" "$R/t12.txt" "last drag: operation 0"

  # Drops take the normal transfer path: undo, the right-drag menu, conflicts.
  S="wait:1;dragfiles:plain:$L/a.txt;crumbhover:Mid;crumbdrop;event;wait:1;log:$R/d1.txt;action:undo:;event;wait:1.2;log:$R/d2.txt"
  S+=";dragfiles:plain:$O/x.txt;crumbhover:Leaf;crumbdrop;event;wait:1;log:$R/d3.txt"
  S+=";dragfiles:right:$O/y.txt;crumbhover:Mid;crumbdrop;event;wait:0.5;log:$R/d4.txt;dropmenu:Copy here;event;wait:1"
  S+=";dragfiles:plain:$O/v.txt;crumbhover:copyonly:Mid;crumbdrop;event;wait:1"
  S+=";dragfiles:plain:$O/c.txt;crumbhover:Mid;crumbdrop;event;wait:1;log:$R/d5.txt;opbutton:Compare info for both files;wait:0.5;opcompare:both;opbutton:Continue;wait:1.5;quit"
  run "$R" "$L" "$S"
  check "the drop was accepted" "$R/d1.txt" "last drag: accepted true"
  contains "undo of the move is offered" "$R/d1.txt" "undo action: Move"
  fact "undo brought the file back" test -f "$L/a.txt" -a ! -e "$M/a.txt"
  check "a drop on the current folder selects what landed" "$R/d3.txt" "selected: x.txt"
  fact "and moved it" test -f "$L/x.txt" -a ! -e "$O/x.txt"
  contains "a right-button drop asks" "$R/d4.txt" "drop menu: Copy here"
  fact "Copy here copied" test -f "$M/y.txt" -a -f "$O/y.txt"
  fact "a copy-only drop agrees with its badge" test -f "$M/v.txt" -a -f "$O/v.txt"
  contains "a name conflict asks first" "$R/d5.txt" "file-op dialogs: Replace or Skip Files"
  fact "keeping both overwrote nothing" test "$(cat "$M/c (2).txt")" = new -a "$(cat "$M/c.txt")" = old

  # Spring-loading: same tab, cancellable, never the folder already shown; a rebuilt bar refuses the drop.
  S="wait:1;dragfiles:plain:$O/z.txt;crumbhover:Leaf;wait:1;log:$R/s0.txt;crumbleave;crumbhover:Mid;wait:0.2;crumbleave;wait:1;log:$R/s1.txt"
  S+=";crumbhover:Mid;wait:1;crumbleave;log:$R/s2.txt;back;wait:1;log:$R/s3.txt"
  S+=";crumbhover:Mid;location:$O;wait:0.3;crumbdrop;log:$R/s4.txt;quit"
  run "$R" "$L" "$S"
  check "the current folder never springs" "$R/s0.txt" "last spring: none"
  check "leaving early cancels" "$R/s1.txt" "last spring: none"
  check "a resting drag springs" "$R/s2.txt" "last spring: crumb:$KM"
  contains "and opens the folder in the same tab" "$R/s2.txt" "location: folder:$KM "
  contains "Back returns" "$R/s3.txt" "location: folder:$KL "
  check "a drop after a rebuild is refused" "$R/s4.txt" "last drag: accepted false"
  fact "and moves nothing" test -f "$O/z.txt"

  # A collapsed path reflows after a spring: the resting pointer must not spring again. The width is pinned: it decides what collapses.
  D1=$(printf 'first-%024d' 0); D2=$(printf 'second-%024d' 0); D3=$(printf 'third-%024d' 0); D4=$(printf 'fourth-%024d' 0); D5=$(printf 'fifth-%024d' 0)
  mkdir -p "$P/P/$D1/$D2/$D3/$D4/$D5"; KD3="${P#/private}/P/$D1/$D2/$D3"; KD4="$KD3/$D4"
  S="wait:1;windowsize:1180,760;dragfiles:plain:$O/z.txt;log:$R/c0.txt;crumbhover:$D1;crumbstate:$R/c1.txt;crumbleave;crumbhover:$D4;wait:1;log:$R/c2.txt;crumbhover:=;log:$R/c3.txt;wait:1.2;log:$R/c4.txt;crumbleave;crumbhover:$D3;wait:1;log:$R/c5.txt;quit"
  run "$R" "$P/P/$D1/$D2/$D3/$D4/$D5" "$S"
  fact "the path is collapsed" grep -Eq "collapsed: [1-9].*$D1[,)]" "$R/c0.txt"
  check "a collapsed segment is no target" "$R/c1.txt" "last drag: operation 0"
  contains "the visible segment sprang" "$R/c2.txt" "location: folder:$KD4 "
  contains "the reflowed segment still takes the drop" "$R/c3.txt" "drop target:"
  lacks "and another segment is under the pointer now" "$R/c3.txt" "drop target: $D4"
  check "no second spring" "$R/c4.txt" "last spring: crumb:$KD4"
  contains "the location didn't climb" "$R/c4.txt" "location: folder:$KD4 "
  check "leaving the bar allows another spring" "$R/c5.txt" "last spring: crumb:$KD3"
  contains "and it opens that segment" "$R/c5.txt" "location: folder:$KD3 "

  # Middle-click: one new tab at that crumb; the original tab is left alone.
  S="wait:1;crumbmiddle:2:Mid;log:$R/m1.txt;tab:1;wait:0.5;log:$R/m2.txt;crumbmiddle:3:Mid;crumbmiddle:2:chevron:Mid;crumbmiddle:2:-;log:$R/m3.txt"
  S+=";location:home;wait:1;crumbmiddle:2:Home;log:$R/m4.txt;quit"
  run "$R" "$L" "$S"
  contains "middle-click opens a new tab" "$R/m1.txt" "tabs: Leaf | Mid  active: 2"
  contains "at that folder" "$R/m1.txt" "location: folder:$KM "
  contains "the original tab stays" "$R/m2.txt" "location: folder:$KL "
  contains "with its history untouched" "$R/m2.txt" "back: false forward: false"
  contains "other buttons, chevrons and empty space do nothing" "$R/m3.txt" "tabs: Leaf | Mid  active: 1"
  contains "non-folder segments open too" "$R/m4.txt" "tabs: Home | Mid | Home  active: 3"

  # Right-to-left: hit testing reads the mirrored frames, so the order is asserted as well.
  S="wait:1;dragfiles:plain:$O/z.txt;crumbhover:Mid;crumbstate:$R/r1.txt;crumbleave;crumbmiddle:2:Mid;log:$R/r2.txt;quit"
  run "$R" "$L" "$S" ARBOR_RTL=1
  contains "right-to-left segments run from the deepest" "$R/r1.txt" "left to right: Leaf, Mid"
  contains "a mirrored segment is highlighted" "$R/r1.txt" "drop target: Mid"
  contains "a mirrored segment opens a new tab" "$R/r2.txt" "tabs: Leaf | Mid  active: 2"

  # The tree, now on the same shared rules.
  S="wait:1;location:$P/P;wait:1;select:Other;click:file.pin;event;wait:1;location:$M;wait:1;dragfiles:plain:$O/t.txt;treedrop:Other;log:$R/n1.txt"
  S+=";dragfiles:plain:$M/u.txt;treedrop:Other;log:$R/n2.txt;dragfiles:plain:$M/c.txt;treedrop:Home;log:$R/n3.txt;quit"
  run "$R" "$M" "$S"
  check "the tree refuses items already there" "$R/n1.txt" "last drag: operation 0 accepted false"
  check "the tree moves by the same rules" "$R/n2.txt" "last drag: operation 16 accepted true"
  fact "the tree drop arrived" test -f "$O/u.txt" -a ! -e "$M/u.txt"
  check "Home in the tree takes no drop" "$R/n3.txt" "last drag: operation 0 accepted false"

  # Another volume copies, and the source stays.
  mkdir -p "$R/mnt"
  if hdiutil create -size 24m -fs HFS+ -volname ArborCrumb -quiet "$R/v.dmg" && \
     hdiutil attach -nobrowse -noautoopen -quiet -mountpoint "$R/mnt" "$R/v.dmg"; then
    mkdir -p "$R/mnt/Inner"
    run "$R" "$R/mnt/Inner" "wait:1;dragfiles:plain:$O/t.txt;crumbhover:Inner;log:$R/v1.txt;crumbdrop;event;wait:1.5;log:$R/v2.txt;quit"
    check "another volume copies" "$R/v1.txt" "last drag: operation 1"
    fact "the source stays" test -f "$O/t.txt" -a -f "$R/mnt/Inner/t.txt"
    hdiutil detach -force -quiet "$R/mnt" >/dev/null 2>&1
  else
    echo "skip  breadcrumb drop across volumes: hdiutil failed"
  fi
  discard breadcrumb "$R"
fi

# settings-transfer.md (FE-208): an import shows what changes first, and a crafted file can't reach anything off the allowlist.
if want settings; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F"
  header='"format":"arbor.settings","version":1'
  printf '{%s,"settings":{"ARBOR_SCRIPT":"quit","AppleLanguages":["fr"],"hideProtectedSystemFiles":false,"hideExtensions":true,"clickItems":"single","compactView":true,"textSize":"/Users/me"}}' "$header" > "$R/crafted.json"
  printf '{%s,"settings":{"compactView":1,"textSize":116}}' "$header" > "$R/invalid.json"
  printf '{"format":"arbor.settings","version":2,"settings":["x"]}' > "$R/newer.json"
  printf '{%s,"settings":{"openTo":"home","browseFolders":"own","showSyncProviderNotifications":false,"fullPathInTitleBar":true,"hiddenFiles":"show","hideEmptyDrives":false,"showStatusBar":false,"itemCheckBoxes":true,"typingMode":"search","navShowAllFolders":true,"navExpandToOpenFolder":true,"showLibraries":true,"navShowAvailabilityStatus":true,"showPopupDescriptions":false,"navigationPaneVisible":false,"swipeNavigation":false,"fileOpsQueueSameDrive":true,"fileOpsConcurrencyLimit":2}}' "$header" > "$R/long.json"
  echo 'not json' > "$R/garbage.json"
  dd if=/dev/zero of="$R/big.json" bs=1024 count=65 2>/dev/null
  S="wait:1;setpref:typingMode=search;click:view.textSize.115;settingsexport:$R/out.json"
  S+=";setpref:typingMode=select;click:view.textSize.100;settingsimport:$R/out.json;wait:0.3;log:$R/preview.txt;menu:main:Arbor:$R/menu.txt;button:Cancel;wait:0.8;log:$R/cancelled.txt"
  S+=";settingsimport:$R/out.json;wait:0.3;button:Import;wait:0.8;log:$R/imported.txt"
  S+=";settingsimport:$R/out.json;wait:0.3;log:$R/same.txt;button:OK;wait:0.8"
  S+=";settingsimport:$R/crafted.json;wait:0.3;log:$R/crafted-preview.txt;button:Import;wait:0.8;log:$R/crafted-after.txt"
  S+=";settingsimport:$R/long.json;wait:0.3;log:$R/long-top.txt;sheetkey:pagedown;log:$R/long-paged.txt;sheetkey:return;wait:0.3;log:$R/long-return.txt;sheetkey:escape;wait:0.8;log:$R/long-escaped.txt"
  S+=";settingsimport:$R/invalid.json;wait:0.3;log:$R/invalid.txt;button:OK;wait:0.8"
  S+=";settingsimport:$R/newer.json;wait:0.3;log:$R/newer.txt;button:OK;wait:0.8"
  S+=";settingsimport:$R/garbage.json;wait:0.3;log:$R/garbage.txt;button:OK;wait:0.8"
  S+=";settingsimport:$R/big.json;wait:0.3;log:$R/big.txt;button:OK;wait:0.8;log:$R/end.txt;quit"
  run "$R" "$R/F" "$S"
  contains "export records the setting" "$R/out.json" '"typingMode" : "search"'
  lacks "export leaves out warnings and paths" "$R/out.json" 'hideProtectedSystemFiles'
  contains "preview names the change" "$R/preview.txt" "Import 2 settings?"
  contains "preview shows the new value" "$R/preview.txt" "Larger (115%)"
  contains "a preview blocks a second import" "$R/menu.txt" "Import Settings… (disabled)"
  contains "Cancel changes nothing" "$R/cancelled.txt" " typingMode=select "
  contains "Import restores the value" "$R/imported.txt" " typingMode=search "
  contains "Import restores the text size" "$R/imported.txt" " textSize=115 "
  contains "an unchanged file says so" "$R/same.txt" "Your settings already match this file."
  contains "crafted file: only allowed entries are offered" "$R/crafted-preview.txt" "Import 1 setting?"
  contains "crafted file: ignored keys are counted" "$R/crafted-preview.txt" "5 other entries in the file were ignored."
  lacks "crafted file: its text isn't shown" "$R/crafted-preview.txt" "/Users/me"
  contains "crafted file: the allowed entry applied" "$R/crafted-after.txt" " compactView=on "
  contains "crafted file: the warning stays on" "$R/crafted-after.txt" "hideProtectedSystemFiles=on"
  contains "crafted file: extensions stay visible" "$R/crafted-after.txt" "hideExtensions=off"
  contains "crafted file: clicks stay as they were" "$R/crafted-after.txt" "clickItems=double"
  contains "crafted file: a path is no text size" "$R/crafted-after.txt" " textSize=115 "
  contains "a long preview opens with the list in focus" "$R/long-top.txt" "settings preview: focus=list offset=0"
  lacks "Page Down scrolls the preview" "$R/long-paged.txt" "offset=0"
  check "Return can't confirm" "$R/long-return.txt" "sheet: true"
  check "Escape closes the preview" "$R/long-escaped.txt" "sheet: false"
  contains "Escape changes nothing" "$R/long-escaped.txt" "browseFolders=same"
  contains "nothing usable isn't called a match" "$R/invalid.txt" "Nothing to import from this file."
  contains "a newer file is named" "$R/newer.txt" "made by a newer version of Arbor"
  contains "garbage is refused" "$R/garbage.txt" "This isn't an Arbor settings file."
  contains "an oversized file is refused" "$R/big.txt" "too large"
  check "nothing left open" "$R/end.txt" "sheet: false"
  discard settings "$R"
fi

# workspaces.md (FE-027): named tab sets survive a relaunch and cope with missing folders, damaged and newer files.
if want workspaces; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/state" "$R/A" "$R/B" "$R/C" "$R/D"
  K="${R#/private}"   # location keys are standardized paths
  W="$R/state/Workspaces.json"
  READY="workspacesready;waitload"
  S="$READY;location:$R/A;waitload;newtab;waitload;location:$R/B;waitload;newtab;waitload;location:$R/C;waitload;tab:2"
  S+=";workspace:save:Trio;menu:main:Window:$R/window-menu.txt;menu:seemore:$R/see-more.txt;quit"
  run "$R" "$R/D" "$S" ARBOR_STATE_DIR="$R/state"
  contains "the saved file lists the tabs" "$W" "\"location\":\"folder:$K/B\""
  contains "the active tab is saved" "$W" "\"activeTab\":1"
  lacks "Back is not saved" "$W" "folder:$K/D"
  contains "the Window menu has the submenu" "$R/window-menu.txt" "Workspaces"
  contains "the menu says it is beyond Explorer" "$R/see-more.txt" "Arbor addition, not part of File Explorer"
  contains "the menu lists the workspace" "$R/see-more.txt" "Trio"

  run "$R" "$R/D" "$READY;log:$R/l0.txt;workspace:open:Trio;workspacesready;waitload;log:$R/l1.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "a relaunch finds it" "$R/l0.txt" "list=Trio[1/folder:$K/A|folder:$K/B|folder:$K/C]"
  check "opens in a new window" "$R/l1.txt" "windows: 2"
  check "new window has the tabs" "$R/l1.txt" "tabs: A | B | C  active: 2"

  run "$R" "$R/D" "$READY;workspace:replace:Trio;workspacesready;waitload;log:$R/r1.txt;quit" ARBOR_STATE_DIR="$R/state"
  check "replace keeps one window" "$R/r1.txt" "windows: 1"
  check "replace swaps the tabs" "$R/r1.txt" "tabs: A | B | C  active: 2"

  # The real sheets: Cancel changes nothing, Save stores the tabs under the name offered (the active tab's title).
  run "$R" "$R/D" "$READY;click:workspaces.save;event;wait:0.5;log:$R/p1.txt;sheetlog:$R/p1s.txt;button:Cancel;event;wait:0.8;log:$R/p2.txt;click:workspaces.save;event;wait:0.5;button:Save;event;wait:0.8;log:$R/p3.txt;quit" ARBOR_STATE_DIR="$R/state"
  check "Save asks for a name" "$R/p1.txt" "sheet: true"
  contains "the name field is offered" "$R/p1s.txt" "Save current tabs as workspace"
  check "Cancel closes the sheet" "$R/p2.txt" "sheet: false"
  lacks "Cancel saves nothing" "$R/p2.txt" "list=D["
  contains "Save stores the workspace" "$R/p3.txt" "list=D[0/folder:$K/D] , Trio["

  # Saving over a name asks first: Cancel leaves the file alone, Replace stores this window's tabs and keeps the entry.
  ASK="$READY;newtab;waitload;location:$R/A;waitload;tab:1;click:workspaces.save;event;wait:0.5;button:Save;event;wait:0.8"
  BEFORE=$(cat "$W")
  run "$R" "$R/D" "$ASK;sheetlog:$R/o1.txt;button:Cancel;event;wait:0.8;log:$R/o2.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "saving over a name asks" "$R/o1.txt" "Replace the workspace “D”?"
  check "Cancel closes the question" "$R/o2.txt" "sheet: false"
  fact "Cancel keeps the saved tabs" test "$BEFORE" = "$(cat "$W")"
  run "$R" "$R/D" "$ASK;button:Replace;event;wait:0.8;log:$R/o3.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "Replace stores this window's tabs" "$R/o3.txt" "list=D[0/folder:$K/D|folder:$K/A] , Trio["

  # The real rename sheet: a taken name is refused and named, a free one goes through.
  S="$READY;workspace:renamesheet:Trio;wait:0.5;workspace:typename:d;button:Rename;event;wait:0.8;sheetlog:$R/e0s.txt;log:$R/e0.txt;button:OK;event;wait:0.8"
  S+=";workspace:renamesheet:Trio;wait:0.5;workspace:typename:Quartet;button:Rename;event;wait:0.8;workspace:delete:D;log:$R/e1.txt;quit"
  run "$R" "$R/D" "$S" ARBOR_STATE_DIR="$R/state"
  contains "a taken name is refused" "$R/e0s.txt" "A workspace named “d” already exists."
  contains "a refused rename changes nothing" "$R/e0.txt" ", Trio["
  contains "renamed and deleted" "$R/e1.txt" "list=Quartet["
  lacks "deleted entry is gone from the file" "$W" "\"name\":\"D\""
  contains "rename reached the file" "$W" "\"name\":\"Quartet\""

  # Folder tabs follow the per-folder view (FE-052); a place without one keeps the saved view.
  run "$R" "$R/D" "$READY;location:trash;waitload;view:list;workspace:save:Bin;workspace:open:Bin;workspacesready;waitload;log:$R/v1.txt;workspace:deletesheet:Bin;wait:0.5;sheetlog:$R/v2.txt;button:Delete;event;wait:0.8;log:$R/v3.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "a non-folder tab keeps its saved view" "$R/v1.txt" "location: trash  view: list"
  contains "Delete says files aren't affected" "$R/v2.txt" "No files or folders are affected."
  lacks "Delete removes the entry" "$R/v3.txt" "Bin["

  # A folder that has gone is skipped and named, stays in the workspace, and its active tab moves right.
  BEFORE=$(cat "$W"); rmdir "$R/B"
  run "$R" "$R/D" "$READY;workspace:replace:Quartet;workspacesready;waitload;wait:0.5;log:$R/m1.txt;sheetlog:$R/m1s.txt;button:OK;event;wait:0.8;quit" ARBOR_STATE_DIR="$R/state"
  check "the others open" "$R/m1.txt" "tabs: A | C  active: 2"
  contains "the skipped tab is named" "$R/m1s.txt" "couldn't be opened"
  contains "the skipped tab's folder is shown" "$R/m1s.txt" "couldn't be opened / B"
  fact "the workspace isn't edited" test "$BEFORE" = "$(cat "$W")"

  # Nothing available: an alert, and the window stays as it was.
  rmdir "$R/A" "$R/C"
  run "$R" "$R/D" "$READY;workspace:replace:Quartet;workspacesready;wait:0.5;log:$R/g1.txt;sheetlog:$R/g1s.txt;button:OK;event;wait:0.8;quit" ARBOR_STATE_DIR="$R/state"
  check "the window keeps its tab" "$R/g1.txt" "tabs: D  active: 1"
  contains "the alert says so" "$R/g1s.txt" "None of the places in"

  # A location this version can't parse is reported as that, not as something missing from the disk.
  echo '{"version":1,"workspaces":[{"name":"Odd","tabs":[{"location":"timeline:x"}]}]}' > "$W"
  run "$R" "$R/D" "$READY;workspace:replace:Odd;workspacesready;wait:0.5;sheetlog:$R/u1.txt;button:OK;event;wait:0.8;quit" ARBOR_STATE_DIR="$R/state"
  contains "an unreadable location says so" "$R/u1.txt" "1 tab has a location this version of Arbor can't open."
  lacks "and doesn't blame the disk" "$R/u1.txt" "moved, deleted"

  # Damaged: moved aside and reported. Newer: shown read-only, and its bytes never change.
  echo 'not json' > "$W"
  run "$R" "$R/D" "$READY;log:$R/d1.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "damage is reported" "$R/d1.txt" "The saved workspaces were damaged"
  fact "the damaged file was moved aside" grep -q 'not json' "$R/state/Workspaces.damaged.json"
  fact "the damaged file is gone" test ! -e "$W"

  : > "$W"
  run "$R" "$R/D" "$READY;log:$R/z1.txt;workspace:save:After;log:$R/z2.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "an empty file is reported as damage" "$R/z1.txt" "The saved workspaces were damaged"
  contains "and saving works again" "$R/z2.txt" "list=After["

  echo '{"version":99,"workspaces":[{"name":"Future","tabs":[{"location":"home"}]}]}' > "$W"
  BEFORE=$(cat "$W")
  run "$R" "$R/D" "$READY;workspace:rename:Future=Past;log:$R/n1.txt;workspace:delete:Future;log:$R/n2.txt;workspace:save:New;log:$R/n3.txt;menu:seemore:$R/n-menu.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "a newer file is read-only" "$R/n1.txt" "readonly=true error=readOnly"
  contains "delete is refused" "$R/n2.txt" "list=Future["
  contains "save is refused" "$R/n3.txt" "error=readOnly"
  fact "a newer file is never rewritten" test "$BEFORE" = "$(cat "$W")"
  contains "the reason is shown" "$R/n-menu.txt" "Saved by a newer version of Arbor"
  contains "Save is disabled while read-only" "$R/n-menu.txt" "Save current tabs as workspace… (disabled)"
  contains "Rename is disabled while read-only" "$R/n-menu.txt" "Rename… (disabled)"
  contains "Delete is disabled while read-only" "$R/n-menu.txt" "Delete… (disabled)"

  # A newer format need not look like this one at all.
  echo '{"sets":[{"name":"Future"}],"version":2}' > "$W"
  BEFORE=$(cat "$W")
  run "$R" "$R/D" "$READY;log:$R/s1.txt;workspace:save:New;log:$R/s2.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "a newer shape is read-only" "$R/s1.txt" "readonly=true"
  contains "a newer shape says why" "$R/s1.txt" "Saved by a newer version of Arbor"
  contains "a newer shape refuses saves" "$R/s2.txt" "error=readOnly"
  fact "a newer shape is neither moved nor rewritten" test "$BEFORE" = "$(cat "$W")"
  discard workspaces "$R"
fi

# finder-tags.md (FE-081): the Tags section lists tags and opens each as an ordinary search, without moving anything.
if want finder-tags; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F"
  for n in tagged workshop plain; do echo "$n" > "$R/F/$n.txt"; done
  tag_file() { xattr -w com.apple.metadata:_kMDItemUserTags "<?xml version=\"1.0\"?><plist version=\"1.0\"><array><string>$2</string></array></plist>" "$1"; }
  tag_file "$R/F/tagged.txt" Work; tag_file "$R/F/workshop.txt" Workshop
  WORK='search?q=tag%3A%22Work%22&recursive=1'
  S="wait:1;log:$R/default.txt"
  S+=";folderoptions:view;foset:navShowTags=0;fobutton:OK;wait:0.8;log:$R/off.txt"
  S+=";folderoptions:view;foset:navShowTags=1;fobutton:OK;wait:0.8;log:$R/on.txt"
  S+=";showlibraries:1;wait:0.8;tagcatalog:Work=4|Home tag=0;log:$R/collapsed.txt"
  S+=";treeexpand:Tags;treeexpand:Libraries;log:$R/seeded.txt"
  S+=";select:plain.txt;click:edit.copy;event;location:$WORK;wait:1.5;log:$R/open.txt;axdump:$R/ax.txt"
  S+=";tagcatalog:Alpha=2|Work=4;log:$R/reseeded.txt"
  S+=";location:search?q=tag%3A%22Work%22&scope=$R/F&recursive=1;wait:2;log:$R/scoped.txt;quit"
  run "$R" "$R/F" "$S"
  contains "Tags is the last, collapsed row" "$R/default.txt" "| Trash | Tags"
  contains "Tags starts collapsed" "$R/default.txt" "finder-tags: collapsed"
  lacks "Show tags off removes the row" "$R/off.txt" "| Tags"
  contains "Show tags on brings it back" "$R/on.txt" "| Tags"
  contains "a new catalog doesn't expand a collapsed section" "$R/collapsed.txt" "finder-tags: collapsed rows=Home tag:0,Work:4"
  contains "rows are in order with colours" "$R/seeded.txt" "finder-tags: expanded rows=Home tag:0,Work:4 discoveries=0"
  contains "a collapsed section asks for nothing" "$R/collapsed.txt" "refreshes=0"
  contains "expanding Tags asks for a refresh, expanding another row doesn't" "$R/seeded.txt" "refreshes=1"
  contains "rows sit under Tags" "$R/seeded.txt" "Tags |   Home tag |   Work"
  check "tab is named after the tag" "$R/open.txt" "tabs: Work  active: 1"
  check "breadcrumb is the tag" "$R/open.txt" "address: segments: Work; collapsed: 0"
  check "search box shows the query" "$R/open.txt" 'search box: “tag:"Work"”'
  contains "search columns" "$R/open.txt" "columns: name(260) dateModified(160) type(150) size(90) search.folder(280) search.match(110)"
  contains "Paste has no destination" "$R/open.txt" "edit.paste(off)"
  contains "current location is marked" "$R/open.txt" "marked=Work"
  contains "VoiceOver hears it is a tag" "$R/ax.txt" "Work, tag"
  contains "an update keeps the section expanded and marked" "$R/reseeded.txt" "finder-tags: expanded rows=Alpha:2,Work:4 discoveries=0 marked=Work"
  contains "an update keeps other expanded rows" "$R/reseeded.txt" "Libraries |   Documents"
  check "an update doesn't navigate the tab" "$R/reseeded.txt" "location: $WORK  view: details"
  check "the query matches the whole tag" "$R/scoped.txt" "rows: tagged.txt"
  fact "files stay where they were" test -f "$R/F/tagged.txt"

  ROW=$(sed -n 's/^tree: //p' "$R/seeded.txt" | tr '|' '\n' | sed 's/^ *//; s/ *$//' | grep -n -x 'Work' | head -1 | cut -d: -f1)
  S="wait:1;showlibraries:1;wait:0.8;tagcatalog:Work=4|Home tag=0;treeexpand:Tags;treeexpand:Libraries;menu:tree:$((ROW - 1)):$R/menu.txt;quit"
  run "$R" "$R/F" "$S"
  contains "tag row offers a new tab" "$R/menu.txt" "Open in new tab"
  contains "tag row offers a new window" "$R/menu.txt" "Open in new window"
  lacks "tag row offers nothing that needs a folder" "$R/menu.txt" "Pin to Quick access"

  S="wait:1;folderoptions:view;foset:navExpandToOpenFolder=1;fobutton:OK;wait:0.8;tagcatalog:Work=4;location:$WORK;wait:1;log:$R/expand.txt;quit"
  run "$R" "$R/F" "$S"
  contains "Expand to open folder opens the section" "$R/expand.txt" "finder-tags: expanded rows=Work:4 discoveries=0 marked=Work"

  S="wait:1;taglabels:None=|Red=FF0000;log:$R/labels.txt;taglabels:None=|Red=00FF00;log:$R/recoloured.txt;taglabels:None=|Red=00FF00;log:$R/same.txt;quit"
  run "$R" "$R/F" "$S"
  contains "new labels update the rows" "$R/labels.txt" "rows=Red:1 discoveries=0 marked=- refreshes=0 changes=1"
  contains "a colour-only label change updates the rows" "$R/recoloured.txt" "changes=2"
  contains "unchanged labels don't" "$R/same.txt" "changes=2"

  S="wait:1;location:$WORK;wait:1;location:search?q=tag%3A%22Red%22&recursive=1;wait:1;click:search.close;wait:1;log:$R/closed.txt;forward;wait:1;log:$R/forward.txt;quit"
  run "$R" "$R/F" "$S"
  check "Close search leaves two tag rows for the folder" "$R/closed.txt" "location: folder:$R/F  view: details"
  check "Forward retraces the tag rows" "$R/forward.txt" "location: $WORK  view: details"
  discard finder-tags "$R"
fi

# address-entry.md: path suggestions never change what was typed, and shell: names never start anything.
if want address; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F/Alpha" "$R/F/Alpine" "$R/F/cmd" "$R/F/Many" "$R/F/Huge" "$R/home/Downloads"
  echo 1 > "$R/F/apple.txt"; echo 1 > "$R/F/Alpha/inner.txt"; for i in $(seq 1 13); do echo 1 > "$R/F/Many/f$i"; done
  P=$(cd "$R/F" && pwd -P)
  S="shown rows=[Alpha/|Alpine/]"
  HIDDEN="completions: hidden rows=[] highlight=- footer=no"

  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;addresscompletions:$R/a.txt;key:down;addresscompletions:$R/a.txt;key:up;key:up;addresscompletions:$R/a.txt;key:down;key:down;key:return;wait:1;addresscompletions:$R/a.txt;log:$R/a1.txt;quit"
  check "the list appears under typed text" "$R/a.txt" "completions: $S highlight=- footer=no listings=1 text=$P/Al"
  check "Down highlights without touching the field" "$R/a.txt" "completions: $S highlight=0 footer=no listings=1 text=$P/Al"
  check "Up wraps through no highlight" "$R/a.txt" "completions: $S highlight=1 footer=no listings=1 text=$P/Al"
  contains "Return on a highlight opens that row" "$R/a1.txt" "/F/Alpha  view: details"
  check "a pick starts no new listing and closes the list" "$R/a.txt" "$HIDDEN listings=1 text=-"

  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;key:return;wait:0.5;addresscompletions:$R/b.txt;log:$R/b1.txt;quit"
  check "Return without a highlight closes the list and keeps the text" "$R/b.txt" "$HIDDEN listings=1 text=$P/Al"
  contains "Return without a highlight submits what was typed" "$R/b1.txt" "Can't find “$P/Al”"
  contains "the failed address leaves the location alone" "$R/b1.txt" "/F  view: details"
  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;key:down;type:$P/cmd;key:return;wait:1;log:$R/b2.txt;quit"
  contains "a highlighted row from older text is not applied" "$R/b2.txt" "/F/cmd  view: details"

  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;key:escape;addresscompletions:$R/c.txt;addresstype:$P/Alp;addresscompletionready;addresscompletions:$R/c.txt;key:escape;key:escape;wait:0.3;addresscompletions:$R/c.txt;quit"
  check "Escape closes the list and keeps the text" "$R/c.txt" "$HIDDEN listings=1 text=$P/Al"
  contains "the next edit reopens it" "$R/c.txt" "shown rows=[Alpha/|Alpine/] highlight=- footer=no listings=1 text=$P/Alp"
  check "a second Escape restores the location" "$R/c.txt" "$HIDDEN listings=1 text=-"

  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;compose:か;addresscompletions:$R/d.txt;quit"
  contains "composing shows no list" "$R/d.txt" "completions: hidden"
  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;key:left;addresscompletions:$R/e.txt;quit"
  check "moving the caret into the text closes the list" "$R/e.txt" "$HIDDEN listings=1 text=$P/Al"
  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;click:nav.address;addresscompletions:$R/f.txt;quit"
  contains "starting the edit over closes the list" "$R/f.txt" "$HIDDEN listings=1 text="
  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;key:tab;wait:0.3;addresscompletions:$R/g.txt;quit"
  contains "Tab leaves the field and closes the list" "$R/g.txt" "$HIDDEN"
  run "$R" "$P" "wait:1;addresstype:$P/Many/;addresscompletionready;addresscompletions:$R/h.txt;quit"
  contains "more rows than fit are admitted to" "$R/h.txt" "footer=moreMatches"
  perl -e 'for (1..20001) { open(my $f, ">", "$ARGV[0]/Huge/n$_") or die; close $f }' "$R/F"
  run "$R" "$P" "wait:1;addresstype:$P/Huge/n;addresscompletionready;addresscompletions:$R/h2.txt;quit"
  contains "a folder past the entry cap says it is only partly read" "$R/h2.txt" "footer=partialListing"

  ln -s "$R/F/Alpha" "$R/F/Blink"
  run "$R" "$P" "wait:1;addresstype:$P/Bli;addresscompletionready;addresscompletions:$R/m.txt;key:down;key:return;wait:1;log:$R/m1.txt;quit"
  contains "a link to a folder is offered" "$R/m.txt" "shown rows=[Blink]"
  contains "picking a link row opens it" "$R/m1.txt" "/F/Blink  view: details"
  contains "picking a link row raises no error" "$R/m1.txt" "sheet: false"
  run "$R" "$P" "wait:1;addresstype:$P/Blink/in;addresscompletionready;addresscompletions:$R/m2.txt;quit"
  contains "typing inside a link lists its target" "$R/m2.txt" "shown rows=[inner.txt]"

  run "$R" "$P" "wait:1;location:$P/Alpine;wait:1;addresstype:$P/Al;addresscompletionready;back:;wait:1;addresscompletions:$R/n.txt;quit"
  contains "moving to another place closes the list" "$R/n.txt" "completions: hidden"
  run "$R" "$P" "wait:1;addresstype:$P/Al;addresscompletionready;addressclickaway;addresscompletions:$R/o.txt;quit"
  check "a press outside the list closes it and keeps the text" "$R/o.txt" "$HIDDEN listings=1 text=$P/Al"

  run "$R" "$P" "wait:1;addresstype:$P/Alpha/;wait:0.3;addresstype:$P/A;addresscompletionready;addresscompletions:$R/i.txt;quit" ARBOR_COMPLETION_DELAY=0.8
  contains "newer text wins over a listing still running" "$R/i.txt" "shown rows=[Alpha/|Alpine/|apple.txt]"
  lacks "the abandoned listing shows nothing" "$R/i.txt" "inner.txt"
  run "$R" "$P" "wait:1;addresstype:$P/Alpha;key:return;log:$R/j.txt;wait:2.5;addresscompletions:$R/j2.txt;quit" ARBOR_COMPLETION_DELAY=2
  contains "Return doesn't wait for a listing" "$R/j.txt" "/F/Alpha  view: details"
  contains "a listing finishing after Return opens nothing" "$R/j2.txt" "completions: hidden"
  run "$R" "$P" "wait:1;addresstype:$P/Al;wait:2;addresscompletions:$R/k.txt;wait:2;addresscompletions:$R/k.txt;addresstype:$P/Alp;wait:0.1;addresscompletions:$R/k2.txt;quit" ARBOR_COMPLETION_DELAY=3
  check "a slow listing shows nothing" "$R/k.txt" "$HIDDEN listings=1 text=$P/Al"
  lacks "a late result opens no list" "$R/k.txt" "completions: shown"
  contains "the next keystroke uses the late result" "$R/k2.txt" "$S highlight=- footer=no listings=1 text=$P/Alp"

  run "$R" "$P" "wait:1;address:shell:downloads;wait:1;log:$R/l.txt;address:shell:controlpanelfolder;wait:0.5;log:$R/l.txt;addresscompletions:$R/l2.txt;address:shell:cmd-nope;wait:0.3;log:$R/l.txt;location:$P;wait:1;address:cmd;wait:1;log:$R/l3.txt;address:notepad;wait:0.5;log:$R/l3.txt;quit" CFFIXED_USER_HOME="$R/home"
  contains "shell:downloads opens the Mac folder" "$R/l.txt" "$R/home/Downloads  view: details"
  contains "no counterpart: says where to look" "$R/l.txt" "Macs have no Control Panel"
  contains "no counterpart: the text stays editable" "$R/l2.txt" "text=shell:controlpanelfolder"
  contains "an unknown name is named" "$R/l.txt" "doesn't know the shell name “cmd-nope”"
  contains "a real folder wins over a command word" "$R/l3.txt" "/F/cmd  view: details"
  contains "a command word is refused, not run" "$R/l3.txt" "doesn't run commands from the address bar"
  run "$R" "$P" "wait:1;address:$P/missing-setup.cmd;wait:0.5;log:$R/l4.txt;quit"
  contains "a missing path ending .cmd keeps the whole path in its message" "$R/l4.txt" "Can't find “$P/missing-setup.cmd”"
  lacks "a missing path is not called a command" "$R/l4.txt" "doesn't run commands from the address bar"
  check "typed text is never run" "$R/l3.txt" "system open: none"
  discard address "$R"
fi

# address-entry.md: addresses survive a relaunch, a bad file is harmless, Clear history erases them, and no run sees the real file.
if want addresshistory; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/state" "$R/F/Alpha/Deep" "$R/F/Beta" "$R/home/Library/Application Support/Arbor"
  P=$(cd "$R/F" && pwd -P); K=${P#/private}
  FILE="$R/state/AddressHistory.json"

  run "$R" "$P" "wait:1;address:$P/Alpha/Deep;wait:1;location:$P/Beta;wait:1;quit" ARBOR_STATE_DIR="$R/state"
  fact "the history is saved at quit" test -f "$FILE"
  contains "a typed address is remembered" "$FILE" "folder:$K/Alpha/Deep"
  contains "a visited place is remembered" "$FILE" "folder:$K/Beta"
  contains "the file has a version" "$FILE" '"version":1'

  run "$R" "$P" "wait:1.5;log:$R/a.txt;addresstype:$K/Al;addresscompletionready;addresscompletions:$R/a2.txt;key:down;key:return;wait:1;log:$R/a3.txt;quit" ARBOR_STATE_DIR="$R/state"
  check "the ▾ list comes back after a relaunch, newest first" "$R/a.txt" "recent: $K | $K/Beta | $K/Alpha/Deep"
  contains "completion offers the remembered folder first" "$R/a2.txt" "shown rows=[Alpha/Deep/|Alpha/]"
  contains "a remembered row opens its folder" "$R/a3.txt" "/F/Alpha/Deep  view: details"

  printf '{"version":1,"entries":["folder:%s/Gone","folder:%s/Beta","folder:/Volumes/Arbor No Such Volume/x",3,"folder:/a/../b"]}' "$K" "$K" > "$FILE"
  run "$R" "$P" "wait:2.5;location:$P/Beta;wait:0.5;log:$R/b.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "a remembered place that exists is listed" "$R/b.txt" "$K/Beta"
  lacks "a folder that went away is not offered" "$R/b.txt" "$K/Gone"
  lacks "a folder on an unplugged drive is not offered" "$R/b.txt" "Arbor No Such Volume"
  contains "hidden entries stay remembered" "$FILE" "Arbor No Such Volume"

  echo "not json" > "$FILE"
  run "$R" "$P" "wait:1;log:$R/c.txt;quit" ARBOR_STATE_DIR="$R/state"
  check "a damaged file starts an empty list" "$R/c.txt" "recent: $K"
  contains "the next save replaces a damaged file" "$FILE" "folder:$K"

  printf '{"version":99,"entries":["trash"],"later":true}' > "$FILE"
  run "$R" "$P" "wait:1;log:$R/d.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "a newer file is read" "$R/d.txt" "Trash"
  contains "a newer file is not rewritten" "$FILE" '"later":true'

  run "$R" "$P" "wait:1;location:$P/Beta;wait:1;homeclear;wait:0.5;log:$R/e.txt;quit" ARBOR_STATE_DIR="$R/state"
  fact "Clear history erases the file" test ! -e "$FILE"
  check "Clear history empties the ▾ list" "$R/e.txt" "recent: "

  REAL="$R/home/Library/Application Support/Arbor/AddressHistory.json"
  printf '{"version":1,"entries":["folder:%s/Beta"]}' "$K" > "$REAL"
  before=$(cksum < "$REAL")
  run "$R" "$P" "wait:1;location:$P/Alpha;wait:2;log:$R/f.txt;homeclear;wait:0.5;quit" CFFIXED_USER_HOME="$R/home"
  lacks "a headless run does not read the real history" "$R/f.txt" "$K/Beta"
  fact "a headless run does not write or erase the real history" test "$before" = "$(cksum < "$REAL")"
  discard addresshistory "$R"
fi

# FE-218: the Open in Arbor service, and what the selection offers to other apps' services. Real Services need a GUI session.
if want services; then
  R=$(arbor_mktemp_dir); F="$R/F"; mkdir -p "$R/trash" "$F/sub" "$F/App.app/Contents"
  echo a > "$F/a.txt"; echo b > "$F/b.txt"
  printf '{"format":"arbor.search","version":1,"query":"saved","scopePath":"%s","recursive":true,"fileContents":false,"systemFiles":false,"zippedFiles":false,"saved":"2026-01-01T00:00:00Z"}' "$F" > "$R/s.arborsearch"
  S="wait:1"
  S+=";serviceopen:$F/sub;log:$R/folder.txt"
  S+=";serviceopen:$F/a.txt;log:$R/file.txt"
  S+=";serviceopen:$F/a.txt|$F/b.txt;log:$R/files.txt"
  S+=";serviceopen:$F/App.app;log:$R/package.txt"
  S+=";serviceopen:$F/missing|$F/sub;wait:0.5;log:$R/partial.txt;button:OK;wait:0.3"
  S+=";serviceopen:$F/missing;wait:0.5;log:$R/failed.txt;button:OK;wait:0.3"
  S+=";serviceopen:$F/missing|$F/gone;wait:0.5;log:$R/failed-two.txt;button:OK;wait:0.3"
  S+=";serviceopen:;log:$R/empty.txt"
  S+=";servicestale:$F/sub;log:$R/stale.txt"
  S+=";opendoc:$R/s.arborsearch;log:$R/search.txt"
  S+=";tab:1;location:$F;wait:0.7;select:;serviceprobe:$R/none.txt"
  S+=";select:a.txt;serviceprobe:$R/one.txt"
  S+=";click:file.rename;wait:0.3;serviceprobe:$R/renaming.txt;escape;wait:0.3"
  S+=";select:a.txt;click:file.rename;wait:0.3;type:zed.txt;serviceclick:1;wait:0.5;log:$R/rename-other.txt;serviceclick:0;wait:0.5;serviceprobe:$R/rename-clicked.txt;escape;wait:0.3"
  S+=";view:largeIcons;wait:0.7;select:a.txt;click:file.rename;wait:0.3;type:zed.txt;iconclick:b.txt:right;wait:0.5;log:$R/rename-grid.txt;serviceprobe:$R/rename-grid-probe.txt;escape;wait:0.3;view:details;wait:0.7"
  S+=";select:a.txt;search:a;wait:0.7;serviceprobe:$R/typing.txt;select:a.txt;serviceclick:0;serviceprobe:$R/clicked.txt"
  S+=";quit"
  run "$R" "$F" "$S"
  contains "a folder opens in a tab" "$R/folder.txt" "location: folder:$F/sub"
  check "a file reveals its parent selected" "$R/file.txt" "selected: a.txt"
  contains "the parent opens for a file" "$R/file.txt" "location: folder:$F "
  check "files in one folder share one tab" "$R/files.txt" "selected: a.txt | b.txt"
  check "a package is revealed" "$R/package.txt" "selected: App.app"
  contains "partial failure opens the rest" "$R/partial.txt" "location: folder:$F/sub"
  contains "partial failure reports a count" "$R/partial.txt" "Arbor couldn't open 1 item."
  lacks "the alert names no file" "$R/partial.txt" "missing"
  contains "all failed reports a count" "$R/failed.txt" "Arbor couldn't open 1 item."
  contains "one skipped item reads as one" "$R/failed.txt" "It may have been moved or deleted"
  contains "several skipped items read as several" "$R/failed-two.txt" "They may have been moved or deleted"
  check "nothing usable sets the service error" "$R/empty.txt" "service error: Open in Arbor needs a file or folder."
  contains "a late result only notes it" "$R/stale.txt" "took too long and was dropped"
  check "a late result shows no sheet" "$R/stale.txt" "sheet: false"
  lacks "a late result opens no tab" "$R/stale.txt" "sub | sub  active"
  contains "a saved search keeps its own location" "$R/search.txt" "location: search?q=saved"
  check "no selection: no file service" "$R/none.txt" "requestor file: false"
  check "a selection answers for files" "$R/one.txt" "requestor file: true"
  check "text is not offered" "$R/one.txt" "requestor text: false"
  check "services can't write back" "$R/one.txt" "requestor returning: false"
  check "the selection is what gets written" "$R/one.txt" "written: a.txt"
  check "a service asking for the older type gets it too" "$R/one.txt" "written legacy: a.txt"
  check "item menu allows Services" "$R/one.txt" "plugins item: true"
  check "background menu doesn't" "$R/one.txt" "plugins background: false"
  check "tree menu doesn't" "$R/one.txt" "plugins tree: false"
  check "tab menu doesn't" "$R/one.txt" "plugins tab: false"
  check "column header menu doesn't" "$R/one.txt" "plugins header: false"
  check "Arbor ▸ Services is handed to AppKit" "$R/one.txt" "services menu: true"
  check "renaming: no file service" "$R/renaming.txt" "requestor file: false"
  check "typing in search: no file service" "$R/typing.txt" "requestor file: false"
  check "right-click takes focus from the search box" "$R/clicked.txt" "requestor file: true"
  check "right-click leaves a rename open" "$R/rename-clicked.txt" "requestor file: false"
  check "right-click elsewhere keeps the selection during a rename" "$R/rename-other.txt" "selected: a.txt"
  check "the same in the icon views" "$R/rename-grid.txt" "selected: a.txt"
  check "an icon-view rename stays open" "$R/rename-grid-probe.txt" "requestor file: false"
  fact "right-click doesn't commit a rename" test -f "$F/a.txt"
  discard services "$R"

  R=$(arbor_mktemp_dir); F="$R/F"; mkdir -p "$R/trash" "$F"
  echo a > "$F/a.txt"; echo b > "$F/b.txt"
  (cd "$F" && /usr/bin/zip -q member.zip b.txt)
  S="wait:1;select:a.txt;click:file.trash;event;wait:1;location:trash;wait:0.7;select:a.txt;log:$R/trash-state.txt;serviceprobe:$R/trash.txt"
  S+=";location:$F;wait:0.7;opendoc:$F/member.zip;wait:1;select:b.txt;log:$R/archive-state.txt;serviceprobe:$R/archive.txt;quit"
  run "$R" "$F" "$S"
  check "the Trash row is selected" "$R/trash-state.txt" "selected: a.txt"
  check "Trash: no file service" "$R/trash.txt" "requestor file: false"
  check "the archive member is selected" "$R/archive-state.txt" "selected: b.txt"
  check "archive: no file service" "$R/archive.txt" "requestor file: false"
  discard services "$R"
fi

# accessibility.md (FE-066, FE-067): the two file-list key presets. MAC is the step that selects the Mac preset.
if want keypreset; then
  MAC="setpref:keyboardPreset=mac"
  at() { printf 'location: folder:%s  view:' "${1#/private}"; }   # as location keys spell the folder
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F/sub" "$R/F/sub2"
  for n in a b c d; do echo "$n" > "$R/F/$n.txt"; done
  P=$(cd "$R/F" && pwd -P)   # items are listed under the physical path (/private/var/…)

  # Windows style, in Details and an icon layout: Return is coded separately in each view.
  for layout in details largeIcons; do
    S="wait:1;view:$layout;wait:0.5;select:a.txt;key:return;wait:0.5;log:$R/w1-$layout.txt"
    S+=";select:sub;key:return;wait:1;log:$R/w2-$layout.txt;key:delete;wait:1;log:$R/w3-$layout.txt;quit"
    run "$R" "$R/F" "$S"
    contains "windows $layout: Return opens a file" "$R/w1-$layout.txt" "open $P/a.txt"
    contains "windows $layout: Return opens a folder" "$R/w2-$layout.txt" "$(at "$R/F/sub")"
    contains "windows $layout: ⌫ goes back" "$R/w3-$layout.txt" "$(at "$R/F")"
  done
  S="wait:1;select:b.txt;key:forwarddelete;wait:1;log:$R/w4.txt"
  S+=";select:c.txt;key:shift+forwarddelete;wait:0.5;log:$R/w5.txt;opbutton:No;wait:0.8;log:$R/w6.txt;quit"
  run "$R" "$R/F" "$S"
  lacks "windows: ⌦ moves to the Trash" "$R/w4.txt" "b.txt"
  fact "windows: the file is in the test Trash" sh -c "ls '$R/trash' | grep -Eq -- '(^|-)b[.]txt$'"
  contains "windows: ⇧⌦ always asks" "$R/w5.txt" "file-op dialogs: Delete File"
  fact "windows: answering No keeps the file" test -f "$R/F/c.txt"
  check "windows: the question is gone" "$R/w6.txt" "file-op dialogs: none"

  # Trash on the default preset: ⌦ reaches the permanent delete's own confirmation.
  echo t > "$R/F/t.txt"
  run "$R" "$R/F" "wait:1;select:t.txt;click:file.trash;event;wait:1;location:trash;wait:2;select:t.txt;key:forwarddelete;wait:0.8;log:$R/w7.txt;button:No;wait:0.8;log:$R/w8.txt;quit"
  contains "windows: ⌦ in the Trash asks before deleting" "$R/w7.txt" "sheet: true"
  contains "windows: ⌦ in the Trash says permanently" "$R/w7.txt" "permanently"
  contains "windows: answering No keeps it in the Trash" "$R/w8.txt" "t.txt"

  # Mac style, in both layouts.
  for layout in details largeIcons; do
    Q="$R/$layout"; mkdir -p "$Q/sub"; for n in a b c d; do echo "$n" > "$Q/$n.txt"; done
    K=$(cd "$Q" && pwd -P)
    S="wait:1;view:$layout;wait:0.5;$MAC;select:a.txt;key:return;wait:0.5;type:a2.txt;enter;wait:1;log:$R/m1-$layout.txt"
    S+=";select:b.txt;key:enter;wait:0.5;type:b2.txt;enter;wait:1;log:$R/m2-$layout.txt"
    S+=";select:sub;key:cmd+down;wait:1;log:$R/m3-$layout.txt;menukey:cmd+up;wait:1;log:$R/m4-$layout.txt"
    S+=";select:c.txt;key:cmd+down;wait:0.5;log:$R/m5-$layout.txt"
    S+=";select:d.txt;click:file.trash;event;wait:1;log:$R/m6-$layout.txt"
    S+=";select:c.txt;key:delete;wait:1;log:$R/m7-$layout.txt;key:forwarddelete;wait:1;log:$R/m8-$layout.txt"
    S+=";key:shift+forwarddelete;wait:0.5;log:$R/m9-$layout.txt"
    S+=";select:sub;key:cmd+return;wait:1;log:$R/m10-$layout.txt;quit"
    run "$R" "$Q" "$S"
    contains "mac $layout: Return renames" "$R/m1-$layout.txt" "a2.txt"
    contains "mac $layout: keypad Enter renames" "$R/m2-$layout.txt" "b2.txt"
    contains "mac $layout: ⌘↓ opens a folder" "$R/m3-$layout.txt" "$(at "$Q/sub")"
    contains "mac $layout: ⌘↑ goes to the parent" "$R/m4-$layout.txt" "$(at "$Q")"
    contains "mac $layout: ⌘↓ opens a file" "$R/m5-$layout.txt" "open $K/c.txt"
    check "mac $layout: Return never opened anything" "$R/m2-$layout.txt" "system open: none"
    lacks "mac $layout: the Trash command still works" "$R/m6-$layout.txt" "d.txt"
    contains "mac $layout: ⌫ doesn't go back" "$R/m7-$layout.txt" "$(at "$Q")"
    fact "mac $layout: ⌦ doesn't delete" test -f "$Q/c.txt"
    check "mac $layout: ⇧⌦ does nothing" "$R/m9-$layout.txt" "file-op dialogs: none"
    contains "mac $layout: ⌘Return still opens a new tab" "$R/m10-$layout.txt" "active: 2"
  done

  # Text fields keep their keys in both presets: inline rename, then the address box.
  for preset in windows mac; do
    Q="$R/text-$preset"; mkdir -p "$Q/folder"; echo x > "$Q/x.txt"
    S="wait:1;setpref:keyboardPreset=$preset;location:$Q/folder;wait:1;up;wait:1"
    S+=";select:folder;click:file.rename;event;wait:0.5;type:folderz;key:delete;wait:0.3;key:cmd+down;key:forwarddelete;log:$R/t1-$preset.txt"
    S+=";key:return;wait:1;log:$R/t2-$preset.txt"
    S+=";click:nav.address;event;wait:0.5;type:$Q/folder;key:delete;key:cmd+down;key:forwarddelete;log:$R/t3-$preset.txt"
    S+=";escape;wait:0.3;click:nav.address;event;wait:0.5;type:$Q/folder;key:return;wait:1;log:$R/t4-$preset.txt;quit"
    run "$R" "$Q" "$S"
    contains "$preset text: keys in the name field don't navigate" "$R/t1-$preset.txt" "$(at "$Q")"
    contains "$preset text: ⌫ edits, Return commits the name" "$R/t2-$preset.txt" "rows: folder | x.txt"
    contains "$preset text: keys in the address box don't navigate" "$R/t3-$preset.txt" "$(at "$Q")"
    contains "$preset text: Return submits the address" "$R/t4-$preset.txt" "$(at "$Q/folder")"
  done

  # A held Return must not cycle in and out of rename, nor a held ⌘↓ dive through folders.
  Q="$R/held"; mkdir -p "$Q/sub/deeper"; echo x > "$Q/x.txt"
  S="wait:1;$MAC;select:x.txt;key:return;wait:0.3;keyrepeat:return;wait:0.3;focus:$R/h1.txt;log:$R/h1.txt;escape;wait:0.5"
  S+=";select:x.txt;keyrepeat:return;wait:0.3;focus:$R/h2.txt"
  S+=";select:sub;key:cmd+down;wait:1;select:deeper;keyrepeat:cmd+down;wait:0.8;log:$R/h3.txt;quit"
  run "$R" "$Q" "$S"
  contains "held Return keeps the name field open" "$R/h1.txt" "RenameField"
  lacks "a key repeat alone doesn't start a rename" "$R/h2.txt" "RenameField"
  contains "held ⌘↓ doesn't dive" "$R/h3.txt" "$(at "$Q/sub")"

  # Mac style falls through where the rename can't run; it never opens a selected read-only item.
  # A click on a header selects its items, which do rename; a collapsed group has none, so its header is selected.
  Q="$R/fall"; mkdir -p "$Q/fold" "$Q/G"; for n in m1 m2 one two three; do echo "$n" > "$Q/$n.txt"; done; echo z > "$Q/inside.txt"
  (cd "$Q" && /usr/bin/zip -q zipped.zip inside.txt)
  echo "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAEElEQVR4nGP4z8DAwMDAAAAJ/gH/4cXYyAAAAABJRU5ErkJggg==" | base64 -D > "$Q/G/photo.png"
  K=$(cd "$Q" && pwd -P)
  S="wait:1;$MAC;groupby:type;wait:1;collapse:Folder;groupclick:Folder;key:return;wait:0.8;log:$R/f0.txt;key:return;wait:0.8;log:$R/f1.txt;groupby:none;wait:1"
  S+=";select:m1.txt|m2.txt;key:return;wait:0.8;type:Doc;enter;wait:1.5;log:$R/f2.txt"
  S+=";select:zipped.zip;key:cmd+down;wait:1.5;select:inside.txt;key:return;wait:0.8;log:$R/f3.txt;quit"
  run "$R" "$Q" "$S"
  contains "mac: Return expands a selected group header" "$R/f0.txt" "[Folder] | fold | G |"
  contains "mac: Return collapses a selected group header" "$R/f1.txt" "Folder (2) [collapsed]"
  contains "mac: Return on several items starts a numbered rename" "$R/f2.txt" "Doc (1).txt"
  check "mac: Return in a ZIP listing opens nothing" "$R/f3.txt" "system open: none"
  contains "mac: Return in a ZIP listing keeps the selection" "$R/f3.txt" "selected: inside.txt"

  S="wait:1;$MAC;select:one.txt;click:file.trash;event;wait:1;location:trash;wait:2;select:one.txt;key:return;wait:0.8;log:$R/f4.txt;quit"
  run "$R" "$Q" "$S"
  check "mac: Return in the Trash opens nothing" "$R/f4.txt" "system open: none"
  contains "mac: Return in the Trash keeps the selection" "$R/f4.txt" "selected: one.txt"

  run "$R" "$Q" "wait:1;$MAC;homefav:$Q/G;location:home;wait:1.5;homeselect:favorites:G;key:return;wait:1.5;log:$R/f5.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "mac: Return activates a Home item" "$R/f5.txt" "$(at "$Q/G")"

  S="wait:1;$MAC;gallerysources:$Q/G;location:gallery;wait:2.5;galleryselect:photo.png;key:return;wait:0.8;log:$R/f6.txt;sheettext:renamed.png;button:Rename;wait:1;quit"
  run "$R" "$Q" "$S" ARBOR_GALLERY_NO_SPOTLIGHT=1
  contains "mac: Return in Gallery asks in a sheet" "$R/f6.txt" "sheet: true"
  fact "mac: the Gallery sheet renames the file" test -f "$Q/G/renamed.png"

  run "$R" "$Q" "wait:1;location:network;wait:1.5;key:delete;wait:1;log:$R/f7.txt;quit" ARBOR_FAKE_NETWORK=1 ARBOR_STATE_DIR="$R/state-net"
  contains "windows: ⌫ on the Network page goes back" "$R/f7.txt" "$(at "$Q")"

  # Input methods own the keyboard while composing (FE-068).
  run "$R" "$Q" "wait:1;$MAC;select:one.txt;compose:か;key:return;wait:0.5;focus:$R/i1.txt;log:$R/i1.txt;quit"
  lacks "mac: Return during composition doesn't rename" "$R/i1.txt" "RenameField"

  # A damaged value behaves as the default and shows the default radio.
  run "$R" "$Q" "wait:1;setpref:keyboardPreset=junk;select:two.txt;key:return;wait:0.5;log:$R/d1.txt;folog:$R/d2.txt;quit"
  contains "damaged value: Return opens" "$R/d1.txt" "open $K/two.txt"
  contains "damaged value: the dialog shows Windows style" "$R/d2.txt" "keyboardPreset=windows"

  # Folder Options: Apply takes effect at once, with the window still open.
  S="wait:1;folderoptions:view;wait:0.5;foset:keyboardPreset=mac;fobutton:Apply;wait:0.5;folog:$R/o1.txt;select:three.txt;key:return;wait:0.5;type:three2.txt;enter;wait:1;log:$R/o2.txt;quit"
  run "$R" "$Q" "$S"
  contains "Apply stores the preset" "$R/o1.txt" "keyboardPreset=mac"
  contains "Apply takes effect without reopening" "$R/o2.txt" "three2.txt"
  discard keypreset "$R"
fi

# FE-058: the band in Details, with real mouse events (NSTableView ignores clicks in the never-key headless window, so
# selecting by a plain click is a manual check). Rows are 28 points; the Name column is 340 wide and Date follows it.
if want detailsmarquee; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F" "$R/S" "$R/G" "$R/F2" "$R/src"
  for n in $(seq -w 1 50); do echo "$n" > "$R/F/f$n.txt"; echo "$n" > "$R/F2/f$n.txt"; done
  for n in a b c; do echo "$n" > "$R/S/$n.txt"; done
  for n in a b c; do echo "$n" > "$R/G/$n.txt"; echo "$n" > "$R/G/$n.md"; done
  echo new > "$R/src/zz.txt"

  # Short folder: below the rows, the Date column, names, modifiers, a row-space click.
  S="wait:1;view:details;wait:0.5"
  S+=";detailsmarquee:50,300,50,40;log:$R/below.txt"                     # from below the rows up into names
  S+=";detailsmarquee:450,10,300,70;log:$R/short.txt"                    # from Date, not reaching any name
  S+=";detailsmarquee:450,10,50,70;log:$R/reached.txt"                   # from Date, reaching the names
  S+=";detailsmarquee:420,10,500,70;log:$R/date.txt"                     # wholly inside Date
  S+=";detailsrowclick:200,42;log:$R/click.txt"                          # row space, no drag
  S+=";select:a.txt|b.txt;detailsmarquee:200,42,50,70:cmd;log:$R/cmd.txt"
  S+=";select:a.txt;detailsmarquee:200,42,50,70:shift;log:$R/shift.txt"
  S+=";detailsmarquee:200,10,50,70;key:shift+up;log:$R/anchor.txt"
  S+=";detailspress:b.txt:$R/press.txt;quit"
  run "$R" "$R/S" "$S"
  check "from below the rows" "$R/below.txt" "selected: b.txt | c.txt"
  contains "started below the rows" "$R/below.txt" "press=belowRows"
  check "a band short of the names selects nothing" "$R/short.txt" "selected: "
  check "a band reaching the names selects them" "$R/reached.txt" "selected: a.txt | b.txt | c.txt"
  contains "started on row space" "$R/reached.txt" "press=rowSpace"
  check "a band inside Date selects nothing" "$R/date.txt" "selected: "
  contains "a row-space click draws no band" "$R/click.txt" "press=rowSpace hits=0 band=0x0"
  check "⌘ toggles against the starting selection" "$R/cmd.txt" "selected: a.txt | c.txt"
  check "⇧ adds to the starting selection" "$R/shift.txt" "selected: a.txt | b.txt | c.txt"
  check "⇧-arrow continues from the band's ends" "$R/anchor.txt" "selected: a.txt | b.txt"
  check "icon, name and the rest of the row" "$R/press.txt" "press icon=item nameEnd=item justPast=rowSpace"
  check "other columns are row space" "$R/press.txt" "press dateModified=rowSpace type=rowSpace size=rowSpace"
  check "shape matches the laid-out cell" "$R/press.txt" "layout icon=true field=true"

  # Mirrored layout: the shape still matches the cell.
  run "$R" "$R/S" "wait:1;view:details;wait:0.5;detailspress:b.txt:$R/rtl.txt;quit" ARBOR_RTL=1
  check "mirrored shape matches the laid-out cell" "$R/rtl.txt" "layout icon=true field=true"
  check "mirrored: the whole field is the name" "$R/rtl.txt" "press icon=item nameEnd=item justPast=rowSpace"

  # Long folder: autoscroll on both axes.
  S="wait:1;view:details;wait:0.5;detailsmarquee:200,10,50,2000::1.2;log:$R/down.txt"
  S+=";windowsize:760,600;wait:0.5;select:;detailsmarquee:100,10,3000,20::1;log:$R/right.txt"
  S+=";detailsmarquee:100,10,-1000,20::1;log:$R/left.txt;quit"
  run "$R" "$R/F" "$S"
  contains "held past the bottom: offscreen rows join" "$R/down.txt" "| f50.txt"
  lacks "held past the bottom: it scrolled" "$R/down.txt" "scrolled=0,-"
  lacks "held past the right edge: it scrolled" "$R/right.txt" "scrolled=0,"
  contains "held past the left edge: it came back" "$R/left.txt" "scrolled=0,"

  # Groups: a header is 36 high, so items start at 36 and the next header at 120. Headers never join, even a focused one under ⌘.
  S="wait:1;view:details;wait:0.5;groupby:type;wait:1;select:a.md;key:up;log:$R/g0.txt"
  S+=";detailsmarquee:200,40,50,110:cmd;log:$R/g1.txt;detailsmarquee:200,40,50,200;log:$R/g2.txt;quit"
  run "$R" "$R/G" "$S"
  contains "a header was focused" "$R/g0.txt" "selectedRows=1"
  check "⌘ band drops the focused header" "$R/g1.txt" "selected: a.md | b.md | c.md"
  contains "only item rows stay selected" "$R/g1.txt" "selectedRows=3"
  check "the band skips the next group's header" "$R/g2.txt" "selected: a.md | b.md | c.md | a.txt | b.txt"
  contains "and the header itself" "$R/g2.txt" "selectedRows=5"

  # A listing change during a hold waits for mouse-up, and a refresh keeps the selection.
  S="wait:1;view:details;wait:0.5;detailsmarquee:200,10,50,70::3:queued;wait:0.5;opstart:copy:$R/src/zz.txt:$R/S;wait:0.5;log:$R/h1.txt"
  S+=";snapshot:$R/band-light.png;wait:3;log:$R/h2.txt"
  S+=";detailsmarquee:200,10,50,70::4:queued;wait:0.3;refresh;wait:0.3;log:$R/h3.txt;wait:4;log:$R/h4.txt;quit"
  run "$R" "$R/S" "$S" ARBOR_APPEARANCE=light
  contains "still tracking during the hold" "$R/h1.txt" "tracking=true"
  contains "the new row waits for mouse-up" "$R/h1.txt" "tableRows=3 "
  contains "the new row appears after mouse-up" "$R/h2.txt" "tableRows=4 "
  contains "the overlay shows the band over the rows" "$R/h1.txt" "overlay=50,10,150x60 overRows=true"
  contains "the overlay leaves with the drag" "$R/h2.txt" "overlay=none"
  fact "a snapshot of the band was written for review" test -s "$R/band-light.png"
  contains "a refresh waits too" "$R/h3.txt" "tracking=true"
  check "the selection survives the refresh" "$R/h4.txt" "selected: a.txt | b.txt | c.txt"

  # Back then another folder during a hold: the last folder must not inherit Back's scroll position.
  S="wait:1;view:details;wait:0.5;detailsmarquee:200,10,50,2000::1.2;wait:0.5;location:folder:$R/S;wait:1.5"
  S+=";detailsmarquee:200,10,50,70::10:queued;wait:0.5;back;wait:0.5;location:folder:$R/F2;wait:0.5;log:$R/n1.txt;wait:12;log:$R/n2.txt;quit"
  run "$R" "$R/F" "$S"
  contains "both folder changes wait for mouse-up" "$R/n1.txt" "tracking=true"
  contains "the last folder shows afterwards" "$R/n2.txt" "tableRows=50 "
  contains "and opens at its top" "$R/n2.txt" "scrolled=0,-"

  # Single-click mode: a click on row space opens, a band released near its start does not.
  S="wait:1;view:details;wait:0.5;folderoptions:general;foset:clickItems=single;fobutton:OK;wait:0.5;detailsmarquee:200,42,204.5,42::0:queued;wait:0.8;log:$R/sc1.txt"
  S+=";detailsrowclick:200,14;wait:0.8;log:$R/sc2.txt;quit"
  run "$R" "$R/S" "$S"
  contains "that press was a band" "$R/sc1.txt" "press=rowSpace"
  lacks "a band out and back opens nothing" "$R/sc1.txt" "/b.txt"
  contains "control: a row-space click opens" "$R/sc2.txt" "/a.txt"
  discard detailsmarquee "$R"
fi

# FE-132: a This Mac search says what it covered, volume by volume, from injected volumes only.
if want wholemac; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F" "$R/hd" "$R/usb/open" "$R/usb/locked" "$R/nas" "$R/off"
  echo 1 > "$R/hd/report-hd.txt"; echo 2 > "$R/usb/open/report-usb.txt"; echo 3 > "$R/usb/locked/report-locked.txt"; echo 4 > "$R/nas/report-nas.txt"; echo 5 > "$R/off/report-off.txt"
  chmod 000 "$R/usb/locked"
  VOLS="Macintosh HD|startup|enabled|$R/hd;USB Stick|external|disabled|$R/usb;Old Disk|external|disabled|;Work Share|network|unknown|$R/nas"
  S="wait:1;windowsize:1100,700;location:thismac;wait:1;search:report;event;wait:3;log:$R/a.txt;searchdetails:$R/d.txt;announcements:$R/spoken.txt"
  S+=";menu:main:Edit:$R/menu.txt;click:search.coverage;wait:0.6;log:$R/sheet.txt;searchcoverageax:$R/ax.txt;button:OK;wait:0.4;log:$R/closed.txt"
  S+=";searchmenu:$R/options.txt;searchopt:Why might results be missing?;wait:0.6;log:$R/sheet2.txt;button:OK;wait:0.4;quit"
  run "$R" "$R/F" "$S" ARBOR_TEST_SEARCH_VOLUMES="$VOLS"
  chmod 755 "$R/usb/locked"
  contains "an indexed startup disk gives results" "$R/a.txt" "report-hd.txt"
  contains "a scanned volume gives results" "$R/a.txt" "report-usb.txt"
  lacks "a network volume is never read" "$R/a.txt" "report-nas.txt"
  contains "the status names what was left out" "$R/a.txt" "Search incomplete: 2 volumes weren't searched (Old Disk, Work Share)"
  contains "details: included" "$R/d.txt" "    Macintosh HD: Searched through the Spotlight index."
  contains "details: denied folders make a volume partial" "$R/d.txt" "    USB Stick: Scanned folder by folder. macOS denied access to 1 folder."
  contains "details: indexing off" "$R/d.txt" "    Old Disk: Spotlight indexing is off on this volume."
  contains "details: network" "$R/d.txt" "    Work Share: Network volumes aren't searched from This Mac"
  contains "details: the denied folder is named" "$R/d.txt" "$R/usb/locked"
  contains "details: what no volume list can show" "$R/d.txt" "Folders excluded in System Settings ▸ Spotlight"
  contains "VoiceOver hears the outcome" "$R/spoken.txt" "Search options explains what was searched."
  contains "the explanation is in the menu bar" "$R/menu.txt" "Why Might Results Be Missing?"
  lacks "and it is enabled" "$R/menu.txt" "Why Might Results Be Missing? (disabled"
  contains "the command opens a sheet" "$R/sheet.txt" "sheet: true"
  contains "the sheet shows the volumes" "$R/sheet.txt" "Work Share: Network volumes"
  contains "VoiceOver reads the sheet's text" "$R/ax.txt" "Searched: This Mac."
  contains "VoiceOver reaches its button" "$R/ax.txt" "OK"
  contains "OK closes it" "$R/closed.txt" "sheet: false"
  contains "Search options has the entry" "$R/options.txt" "Why might results be missing?"
  contains "the entry opens the same sheet" "$R/sheet2.txt" "Old Disk: Spotlight indexing is off"

  # With indexing off, the startup disk is left out: its stand-in folder must not be read.
  S="wait:1;location:thismac;wait:1;search:report;event;wait:3;log:$R/off.txt;searchdetails:$R/off-d.txt;quit"
  run "$R" "$R/F" "$S" ARBOR_TEST_SEARCH_VOLUMES="Macintosh HD|startup|disabled|$R/off"
  lacks "indexing off: nothing is read" "$R/off.txt" "report-off.txt"
  contains "indexing off: the startup disk is left out" "$R/off-d.txt" "    Macintosh HD: Spotlight indexing is off on this volume."

  # A headless run with nothing injected searches nothing at all.
  S="wait:1;location:thismac;wait:1;search:report;event;wait:3;log:$R/none.txt;searchdetails:$R/none-d.txt;quit"
  run "$R" "$R/F" "$S"
  lacks "nothing injected: no real file is listed" "$R/none.txt" "report-"
  contains "nothing injected: still says it's incomplete" "$R/none.txt" "Search incomplete"
  lacks "nothing injected: no real volume is named" "$R/none-d.txt" "Included:"
  discard wholemac "$R"
fi

# FE-055: long names wrap in Details when the Folder Options choice is on. The window width sets the Name column.
if want namewrap; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F" "$R/L"
  TWO="Quarterly planning notes for the whole team with far too many words to fit on one line of the name column.pdf"
  CAPPED="$(printf 'x%.0s' $(seq 1 120))_$(printf 'y%.0s' $(seq 1 100)).tar.gz"
  touch "$R/F/$TWO" "$R/F/$CAPPED" "$R/F/b.txt" "$R/F/c.md" "$R/F/$(printf 'evil\nname.pdf')"
  mkdir "$R/F/Long folder name with a dot in it so that nothing marks a false extension somewhere over the end.of.it"
  # All 5,000 names wrap: what is measured must stay near what is on screen.
  perl -e 'for (1..5000) { open(my $f, ">", sprintf("%s/%05d %s.txt", $ARGV[0], $_, "long name " x 12)) or die }' "$R/L"

  # Row height + 12 = field height + 28: a cell whose field kept an old height would show here.
  fits() { awk 'index($0, "namewrap row:") { h=$0; sub(/.* height=/, "", h); sub(/ .*/, "", h); f=$0; sub(/.* field=[0-9]+x/, "", f); sub(/ .*/, "", f); if (h - f != base) bad=1 } END { exit bad }' base="$2" "$1"; }

  OPT="folderoptions:view;foset:wrapLongNames=1;fobutton:OK;wait:0.8"
  S="wait:1;view:details;windowsize:1100,700;wait:0.5;namewrap:$R/off.txt"
  S+=";$OPT;namewrap:$R/on.txt;snapshot:$R/on.png"
  S+=";detailsmarquee:600,10,30,130;log:$R/band.txt;detailsmarquee:600,10,300,130;log:$R/band2.txt"
  S+=";select:b.txt;key:down;log:$R/down.txt;key:shift+down;log:$R/shift.txt"
  S+=";click:view.compact;wait:0.5;namewrap:$R/compact.txt;click:view.compact;wait:0.5"
  S+=";select:$TWO;click:file.rename;wait:0.4;namewrap:$R/renaming.txt;escape;wait:0.4;namewrap:$R/escaped.txt"
  S+=";select:b.txt;click:file.rename;event;type:$TWO b.txt;enter;event;wait:1.2;namewrap:$R/renamed.txt;log:$R/renamed-log.txt"
  S+=";windowsize:760,700;wait:0.8;namewrap:$R/narrow.txt"
  S+=";folderoptions:view;foset:wrapLongNames=0;fobutton:OK;wait:0.8;namewrap:$R/off2.txt;quit"
  run "$R" "$R/F" "$S"
  contains "off by default" "$R/off.txt" "namewrap: on=false"
  contains "off: a long name stays on one line" "$R/off.txt" "$TWO height=28 "
  lacks "off: no cell is a wrapped one" "$R/off.txt" "wrapped=true"
  contains "on from Folder Options" "$R/on.txt" "namewrap: on=true"
  contains "a long name takes two lines" "$R/on.txt" "$TWO height=44 "
  contains "a short name keeps the ordinary height" "$R/on.txt" "c.md height=28 "
  contains "at most three lines" "$R/on.txt" "$CAPPED height=60 "
  fact "fields match their rows" fits "$R/on.txt" 12
  fact "every row keeps the full-name tooltip" grep -qvE 'tip=false' "$R/on.txt"
  contains "the name is shortened in the middle" "$R/on.txt" "…"
  fact "the shortened name keeps its extension" grep -qE '^namewrap row: x+_y+\.tar\.gz .*shown=.*….*\.tar\|\.gz$' "$R/on.txt"
  contains "the extension can't split" "$R/on.txt" "shown=c|.md"
  contains "a line break in a name stays out of the layout" "$R/on.txt" 'shown=evil name|.pdf'
  lacks "a folder gets no extension break" "$R/on.txt" "of|.it"
  contains "a band selects across tall rows" "$R/band.txt" "press=rowSpace hits=5 "
  contains "a band over the text takes only the long names" "$R/band2.txt" "press=rowSpace hits=2 "
  contains "the keyboard moves through tall rows" "$R/down.txt" "selected: c.md"
  contains "shift extends through tall rows" "$R/shift.txt" "selected: c.md | evil"
  contains "compact rows stay smaller" "$R/compact.txt" "c.md height=24 "
  fact "compact: fields match their rows" fits "$R/compact.txt" 8
  contains "a narrower column means more lines" "$R/narrow.txt" "$TWO height=60 "
  fact "narrow: fields match their rows" fits "$R/narrow.txt" 12
  contains "rename edits the full name" "$R/renaming.txt" "shown=$TWO"
  contains "Escape restores the shown text" "$R/escaped.txt" "shown=${TWO%.pdf}|.pdf"
  # A reload puts the Name column back at its saved width, so this name can take a different number of lines.
  fact "a renamed row takes its new height" grep -qE "^namewrap row: $TWO b\.txt height=(44|60) " "$R/renamed.txt"
  fact "renamed: fields match their rows" fits "$R/renamed.txt" 12
  contains "and is selected" "$R/renamed-log.txt" "$TWO b.txt"
  lacks "off again: nothing stays wrapped" "$R/off2.txt" "wrapped=true"
  contains "off again: back to one line" "$R/off2.txt" "$TWO height=28 "

  S="wait:1;view:details;windowsize:1100,700;wait:0.5;$OPT;namewrap:$R/tall.txt;quit"
  run "$R" "$R/F" "$S" ARBOR_TEXT_SIZE=150
  fact "bigger text gives taller rows" test "$(sed -n "s/^namewrap row: $TWO height=\([0-9]*\) .*/\1/p" "$R/tall.txt")" -gt 44

  S="wait:1;view:details;windowsize:1100,700;wait:0.5;$OPT;namewrap:$R/rtl.txt;detailspress:$TWO:$R/rtl-press.txt;quit"
  run "$R" "$R/F" "$S" ARBOR_RTL=1
  contains "right to left: a long name wraps" "$R/rtl.txt" "$TWO height=44 "
  contains "right to left: the shape still matches the cell" "$R/rtl-press.txt" "layout icon=true field=true"

  S="wait:1;view:details;windowsize:1100,700;wait:0.5;$OPT;namewrap:$R/top.txt;key:end;wait:0.8;namewrap:$R/end.txt;key:home;wait:0.8;namewrap:$R/home.txt;quit"
  run "$R" "$R/L" "$S"
  measured() { sed -n 's/^namewrap: .*measured=\([0-9]*\) .*/\1/p' "$1"; }
  fact "only rows near the screen are measured" test "$(measured "$R/top.txt")" -lt 1000
  contains "the last row is reached" "$R/end.txt" "05000 "
  contains "and the first again" "$R/home.txt" "00001 "
  fact "still only a fraction of the folder" test "$(measured "$R/end.txt")" -lt 2500
  discard namewrap "$R"
fi

# gallery-libraries.md: custom libraries (FE-076), their write destination (FE-238) and removal vs deletion (FE-239).
if want libraries; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F" "$R/A" "$R/B"; echo a > "$R/A/in-a.txt"; echo b > "$R/B/in-b.txt"

  # Create: bad names show why and create nothing; a good one opens the library and its dialog.
  S="wait:1;location:library?name=Libraries;wait:1;click:library.new;wait:1;log:$R/c0.txt"
  S+=";sheettext:libraries;wait:0.5;button:Create;wait:0.8;log:$R/c1.txt"
  S+=";sheettext:Documents;wait:0.5;button:Create;wait:0.8;log:$R/c2.txt"
  S+=";sheettext:Work;wait:0.5;button:Create;wait:2;log:$R/c3.txt;dialog:add:$R/A;dialog:add:$R/B;dialog:ok;wait:2;log:$R/c4.txt;quit"
  run "$R" "$R/F" "$S"
  contains "New suggests a free name" "$R/c0.txt" "New Library"
  contains "the reserved name explains itself" "$R/c1.txt" "is the name of the page that lists your libraries"
  check "the reserved name creates nothing" "$R/c1.txt" "sheet: true"
  contains "a taken name explains itself" "$R/c2.txt" "There's already a library named “Documents”."
  contains "a good name opens the library" "$R/c3.txt" "location: library?name=Work"
  contains "and its Manage dialog" "$R/c3.txt" "dialog Work Library Locations"
  contains "the listing merges the included folders" "$R/c4.txt" "rows: in-a.txt | in-b.txt"
  contains "Details adds the Folder column" "$R/c4.txt" "details columns: Name, Date modified, Type, Size, Folder"

  # Rename while open in a background tab: the tab follows, Back and Forward stay valid, its view is still remembered.
  S="wait:1;librarydef:Work=$R/A|$R/B;location:library?name=Work;wait:1.5"
  S+=";newtab;wait:1;location:library?name=Libraries;wait:1;libraryselect:Work;wait:0.5;click:file.rename;wait:1;sheettext:Job;wait:0.5;button:Rename;wait:1.5;log:$R/r1.txt"
  S+=";tab:1;wait:1.5;log:$R/r2.txt;view:list;wait:1;log:$R/r3.txt;back;wait:1.5;forward;wait:1.5;log:$R/r4.txt"
  S+=";location:home;wait:1;location:library?name=Job;wait:1.5;log:$R/r5.txt;quit"
  run "$R" "$R/F" "$S"
  contains "the Libraries page shows the new name" "$R/r1.txt" "selected: Job"
  contains "a background tab follows the rename" "$R/r2.txt" "tabs: Job | Libraries"
  check "no error after the rename" "$R/r2.txt" "sheet: false"
  contains "the view is recorded under the new name" "$R/r3.txt" "source=Saved for this folder"
  contains "Forward goes back to the renamed library" "$R/r4.txt" "location: library?name=Job"
  check "Back and Forward raise no alert" "$R/r4.txt" "sheet: false"
  contains "the view is remembered under the new name" "$R/r5.txt" "view: list"

  # Delete from a tile and the tree: confirmation, tabs land on Libraries, files stay; the menu says what it does.
  S="wait:1;librarydef:Gone=$R/A;librarydef:Tree=$R/B;location:library?name=Gone;wait:1.5"
  S+=";newtab;wait:1;location:library?name=Libraries;wait:1;libraryselect:Gone;wait:0.5;menu:main:File:$R/d0.txt;click:file.trash;wait:1;log:$R/d1.txt;button:Delete library;wait:1.5;log:$R/d2.txt"
  S+=";tab:1;wait:1.5;log:$R/d3.txt;librarymenu:Tree:$R/d4.txt;librarytree:library.delete:Tree;wait:1;button:Cancel;wait:0.8;log:$R/d5.txt"
  S+=";librarytree:library.delete:Tree;wait:1;button:Delete library;wait:1.5;log:$R/d6.txt;quit"
  run "$R" "$R/F" "$S"
  contains "the File menu names the library action" "$R/d0.txt" "Delete library"
  lacks "and doesn't offer the Trash for a tile" "$R/d0.txt" "Move to Trash"
  contains "the confirmation says the files stay" "$R/d1.txt" "Its folders and files stay where they are"
  lacks "the tile is gone" "$R/d2.txt" "library tiles: Documents | Music | Pictures | Videos | Gone"
  contains "a tab showing it lands on Libraries" "$R/d3.txt" "location: library?name=Libraries"
  contains "the tile menu offers Rename" "$R/d4.txt" "Rename library"
  contains "the tile menu offers Delete" "$R/d4.txt" "Delete library"
  lacks "the tile menu has no file command" "$R/d4.txt" "Copy as path"
  contains "Cancel keeps the library" "$R/d5.txt" "library tiles: Documents | Music | Pictures | Videos | Tree"
  lacks "Delete removes it from the tree menu too" "$R/d6.txt" "| Tree"
  fact "deleting libraries left the files" test -f "$R/A/in-a.txt" -a -f "$R/B/in-b.txt"
  fact "and put nothing in the Trash" test -z "$(ls -A "$R/trash")"

  # Optimize with the library already open; a saved view lasts until Optimize changes or Reset Folders.
  S="wait:1;librarydef:Media=$R/A|$R/B;location:library?name=Media;wait:1.5;managelibrary:Media;dialog:optimize:music;dialog:ok;wait:1.5;log:$R/o1.txt"
  S+=";managelibrary:Media;dialog:optimize:pictures;dialog:ok;wait:1.5;log:$R/o2.txt;view:details;wait:1;location:home;wait:1;location:library?name=Media;wait:1.5;log:$R/o3.txt"
  S+=";resetfolders;wait:1;log:$R/o4.txt;view:details;wait:1;managelibrary:Media;dialog:optimize:videos;dialog:ok;wait:1.5;log:$R/o5.txt;quit"
  run "$R" "$R/F" "$S"
  contains "Music shows its columns and Folder" "$R/o1.txt" "details columns: Name, #, Title, Contributing artists, Album, Folder"
  contains "Pictures opens in Large icons" "$R/o2.txt" "view: largeIcons"
  contains "a view change is remembered" "$R/o3.txt" "view: details"
  contains "Reset Folders forgets it" "$R/o4.txt" "view: largeIcons"
  contains "changing Optimize drops the saved view" "$R/o5.txt" "view: largeIcons"
  contains "the type is stored" "$R/o5.txt" "Media=videos"

  # FE-238: the drop target follows a save-location edit; New goes only there; with no folders New explains.
  S="wait:1;librarydef:Save=$R/A|$R/B;location:library?name=Save;wait:1.5;log:$R/s0.txt;managelibrary:Save;dialog:moveup:$R/B;log:$R/s1.txt;dialog:save:$R/B;dialog:ok;wait:1.5;log:$R/s2.txt"
  S+=";click:file.newFolder;event;wait:1.5;escape;wait:1;librarydef:Empty=;location:library?name=Empty;wait:1;click:file.newFolder;wait:1;log:$R/s3.txt;button:Cancel;wait:0.8"
  S+=";managelibrary:Save;wait:0.5;log:$R/s4.txt;dialog:cancel;wait:0.5;location:library?name=Libraries;wait:1;log:$R/s5.txt;librarytree:library.delete:Music;wait:1;button:Delete library;wait:1;click:library.restoreDefaults;wait:1;log:$R/s6.txt;quit"
  run "$R" "$R/F" "$S"
  contains "the drop target starts at the save location" "$R/s0.txt" "library drop target: $R/A"
  contains "Move up reorders the folders" "$R/s1.txt" "$R/B | *$R/A"
  contains "library target follows the edit" "$R/s2.txt" "library target: $R/B"
  contains "the view's drop target follows the edit" "$R/s2.txt" "library drop target: $R/B"
  fact "New folder wrote to the save location only" test -d "$R/B/New folder" -a ! -e "$R/A/New folder"
  contains "a library with no folders explains why" "$R/s3.txt" "doesn't include any folders"
  contains "Restore defaults is hidden for a custom library" "$R/s4.txt" "restore=false"
  contains "Restore default libraries brings one back" "$R/s6.txt" "Music"

  # New folder's name field edits the folder just made, even when an earlier folder already holds that name.
  mkdir -p "$R/C/New folder" "$R/D"
  S="wait:1;librarydef:Same=$R/C|$R/D;location:library?name=Same;wait:1.5;managelibrary:Same;dialog:save:$R/D;dialog:ok;wait:1.5;click:file.newFolder;wait:2;type:Renamed;enter;wait:2;quit"
  run "$R" "$R/F" "$S"
  fact "renaming after New folder acts on the folder just made" test -d "$R/D/Renamed" -a -d "$R/C/New folder" -a ! -e "$R/C/Renamed"

  # Removing the save location in Manage library hands it to the next folder, and that survives OK.
  S="wait:1;librarydef:Two=$R/A|$R/B|$R/C;location:library?name=Two;wait:1.5;managelibrary:Two;dialog:save:$R/B;dialog:remove:$R/B;log:$R/m1.txt;dialog:ok;wait:1.5;log:$R/m2.txt;quit"
  run "$R" "$R/F" "$S"
  contains "removing the save location moves it to the next folder" "$R/m1.txt" "$R/A | *$R/C"
  contains "the new save location is what gets saved" "$R/m2.txt" "library target: $R/C"

  # With a missing save location, the reload after New folder keeps both the fallback note and the partial-coverage note.
  S="wait:1;librarydef:Fall=$R/Missing|$R/D;location:library?name=Fall;wait:1.5;click:file.newFolder;wait:2;escape;wait:0.5;log:$R/n1.txt;quit"
  run "$R" "$R/F" "$S"
  contains "the fallback note outlasts the reload" "$R/n1.txt" "The save location isn't available, so “D” is used instead."
  contains "and the missing folder is still reported" "$R/n1.txt" "Some folders in this library aren't available"
  fact "New folder used the fallback" test -d "$R/D/New folder"

  # Optimize re-applies only that library: another tab keeps its column filter.
  mkdir -p "$R/G"; echo x > "$R/G/small.txt"; head -c 300000 /dev/zero > "$R/G/large.bin"
  S="wait:1;location:$R/G;wait:1;view:details;wait:0.5;filter:size:Tiny (0 – 16 KB);wait:0.8;librarydef:Opt=$R/B;newtab;wait:1;location:library?name=Opt;wait:1.5;managelibrary:Opt;dialog:optimize:music;dialog:ok;wait:1.5;log:$R/g1.txt;tab:1;wait:1.5;log:$R/g2.txt;quit"
  run "$R" "$R/F" "$S"
  contains "Optimize changes the library's own view" "$R/g1.txt" "details columns: Name, #, Title, Contributing artists, Album, Folder"
  contains "and another tab keeps its filter" "$R/g2.txt" "filters: size="
  check "so its rows stay filtered" "$R/g2.txt" "rows: small.txt"

  # The Libraries page: New offers only libraries, and the status line counts a search like every other view.
  S="wait:1;location:library?name=Libraries;wait:1;menu:new:$R/p1.txt;search:Doc;wait:1;log:$R/p2.txt;quit"
  run "$R" "$R/F" "$S"
  contains "New on the Libraries page offers a library" "$R/p1.txt" "Library"
  lacks "and nothing that makes a file" "$R/p1.txt" "Compressed"
  contains "a search reports matches of the total" "$R/p2.txt" "of 4 items match “Doc”"

  # The reason under the name field fits a very long name and reaches VoiceOver.
  LONG=$(printf 'a%.0s' {1..118})
  S="wait:1;librarydef:$LONG=$R/B;location:library?name=Libraries;wait:1;click:library.new;wait:1;sheettext:$LONG;wait:0.5;l10naudit:$R/v1.txt;announcements:$R/v2.txt;quit"
  run "$R" "$R/F" "$S"
  lacks "a long name's reason isn't clipped" "$R/v1.txt" "clipped: NSTextField \"There's already"
  contains "VoiceOver hears why the name can't be used" "$R/v2.txt" "There's already a library named"
  discard libraries "$R"
fi

# cloud.md (FE-231): a blocked command says why, by key binding or menu shortcut and on its button; its own tooltip returns elsewhere.
# qa-core.md (FE-225): opening a file past the path limit is explained, not silently dropped.
if want capabilities; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/src" "$R/F"; echo 1 > "$R/src/a.txt"; echo 1 > "$R/F/b.txt"
  (cd "$R/src" && /usr/bin/zip -q "$R/F/pack.zip" a.txt)
  K=$(cd "$R" && pwd -P)
  DEEP="$K/F"; NAME=$(printf 'd%.0s' {1..200}); LONG=$(printf 'f%.0s' {1..230})
  while [ ${#DEEP} -lt 800 ]; do DEEP="$DEEP/$NAME"; mkdir "$DEEP"; done
  (cd "$DEEP" && : > "$LONG")   # relative: the file's whole path is past PATH_MAX
  run "$R" "$R/F" "wait:1;location:archive?file=$K/F/pack.zip&inner=;wait:1.5;select:a.txt;key:F2;event;wait:0.3;log:$R/a.txt;location:$R/F;wait:1;select:b.txt;wait:0.3;log:$R/f.txt;click:edit.copy;event;location:trash;wait:1;key:cmd+v;event;wait:0.3;log:$R/t.txt;location:$DEEP;wait:1;openitem:$LONG;wait:0.5;log:$R/d.txt;sheetlog:$R/d.txt;quit"
  contains "pressing F2 inside an archive says why" "$R/a.txt" " | Archives are read-only here"
  contains "the greyed button shows the reason" "$R/a.txt" "file.rename=Archives are read-only here"
  contains "the button's own tooltip returns" "$R/f.txt" "file.rename=Rename (F2)"
  contains "pressing ⌘V in the Trash says why" "$R/t.txt" " | Items can't be created or pasted in the Trash"
  contains "opening a file past the path limit says why" "$R/d.txt" "too long for macOS to open"
  lacks "and doesn't ask macOS to open it" "$R/d.txt" "system open: open"
  discard capabilities "$R"
fi

# promised-files.md (FE-102, FE-240, FE-256): file promises through the real drop path, with stand-in providers.
if want promises; then
  R=$(arbor_mktemp_dir); mkdir -p "$R/trash" "$R/F"; K=$(cd "$R" && pwd -P)
  printf 'already here' > "$R/F/report.txt"; echo 1 > "$R/F/a.txt"

  S="wait:1;promisedrop:unnamed:new.txt:$K/F;promisewait;wait:0.5;log:$R/ok.txt;quit"
  run "$R" "$R/F" "$S"
  contains "a delivered promise is copied in and selected" "$R/ok.txt" "selected: new.txt"
  contains "its staging folder is removed afterwards" "$R/ok.txt" "promised: staging=gone report=none"
  check "the delivered bytes arrive" "$R/F/new.txt" "delivered"

  S="wait:1;promisedrop:ok:report.txt:$K/F;wait:1.5;log:$R/conflict.txt;opbutton:Skip this file;wait:1;promisewait;wait:0.3;log:$R/skipped.txt;quit"
  run "$R" "$R/F" "$S"
  contains "a promised name that exists asks first" "$R/conflict.txt" "Replace or Skip Files"
  check "and the file there stays when skipped" "$R/F/report.txt" "already here"
  contains "skipping ends the job" "$R/skipped.txt" "promised: staging=gone report=none"

  S="wait:1;promisedrop:ok:report.txt:$K/F;wait:1.5;opbutton:Replace the file in the destination;wait:1;promisewait;wait:0.3;quit"
  run "$R" "$R/F" "$S"
  check "only the explicit Replace brings the promised file in" "$R/F/report.txt" "delivered"
  check "and the file it replaced goes to the Trash" "$R/trash/report.txt" "already here"

  S="wait:1;promisedrop:fail:broken.bin:$K/F;promisewait;wait:0.3;log:$R/fail.txt;button:OK;wait:0.3;quit"
  run "$R" "$R/F" "$S"
  contains "an error is shown with the provider's reason" "$R/fail.txt" "couldn't be received. The attachment could not be fetched."
  contains "its partial file is removed" "$R/fail.txt" "promised: staging=gone"
  if [ -e "$R/F/broken.bin" ]; then echo "FAIL  a failed promise left output"; FAILED=1; GROUP_FAILED=1; else echo "pass  a failed promise leaves no output"; fi

  S="wait:1;promisedrop:lie:ghost.bin:$K/F;promisewait;wait:0.3;log:$R/lie.txt;button:OK;wait:0.3"
  S+=";promisedrop:escape:away.txt:$K/F;promisewait;wait:0.3;log:$R/escape.txt;button:OK;wait:0.3"
  S+=";promisedrop:link:hosts:$K/F;promisewait;wait:0.3;log:$R/link.txt;button:OK;wait:0.3;quit"
  run "$R" "$R/F" "$S"
  contains "a success report with nothing there fails" "$R/lie.txt" "the file isn't there"
  contains "a location outside staging is refused" "$R/escape.txt" "isn't safe"
  contains "a symbolic link is refused" "$R/link.txt" "isn't safe"
  for n in ghost.bin away.txt hosts; do
    if [ -e "$R/F/$n" ] || [ -L "$R/F/$n" ]; then echo "FAIL  $n reached the folder"; FAILED=1; GROUP_FAILED=1; else echo "pass  $n stayed out"; fi
  done

  S="wait:1;promisedrop:stall:waiting.bin:$K/F;wait:0.4;log:$R/stall1.txt;promisewait;wait:0.3;log:$R/stall2.txt;button:OK;wait:0.3;quit"
  run "$R" "$R/F" "$S" ARBOR_PROMISE_STALL=2
  contains "a silent provider shows progress meanwhile" "$R/stall1.txt" "Receiving “waiting.bin”"
  contains "a partial file doesn't count as received" "$R/stall1.txt" "promised: staging=present"
  contains "the unavailable provider is explained" "$R/stall2.txt" "stopped responding or has quit"
  if [ -e "$R/F/waiting.bin" ]; then echo "FAIL  a stalled promise left output"; FAILED=1; GROUP_FAILED=1; else echo "pass  a stalled promise leaves no output"; fi

  S="wait:1;windowsize:1000,700;wait:0.3;promisedrop:slow:big.bin:$K/F;wait:1.6;log:$R/slow.txt;snapshot:$R/slow.png;promisecancel;promisewait;wait:0.5;log:$R/cancel.txt;quit"
  run "$R" "$R/F" "$S"
  contains "bytes arriving are shown" "$R/slow.txt" "Receiving “big.bin” · "
  contains "cancel removes what arrived" "$R/cancel.txt" "promised: staging=gone report=none job=none"
  if [ -e "$R/F/big.bin" ]; then echo "FAIL  a cancelled promise left output"; FAILED=1; GROUP_FAILED=1; else echo "pass  a cancelled promise leaves no output"; fi
  discard promises "$R"
fi

exit $FAILED
