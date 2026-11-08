#!/usr/bin/env bash
# Headless regression checks for undo/redo, selection identity, window-modal alerts, sheet queueing,
# recovery of queued jobs and headless safety (docs/features/qa-core.md, qa-places.md, file-operations.md).
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
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/F/sub"
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
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/A" "$R/mnt"
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
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/P/one" "$R/P/two" "$R/P/three"
  for d in one two three; do echo "$d" > "$R/P/$d/a.txt"; done
  echo b > "$R/P/three/b.txt"
  run "$R" "$R/P" "wait:1;search:txt;event;wait:3;select:b.txt;wait:0.5;log:$R/s0.txt;click:file.trash;event;wait:3;log:$R/s1.txt;quit"
  check "search results listed" "$R/s0.txt" "selected: b.txt"
  check "after a delete only one neighbour is selected" "$R/s1.txt" "selected: a.txt"
  R2=$(mktemp -d); mkdir -p "$R2/trash" "$R2/P/one" "$R2/P/two"
  for d in one two; do echo "$d" > "$R2/P/$d/readme.txt"; done
  run "$R2" "$R2/P" "wait:1;search:readme;event;enter;wait:3;log:$R2/d0.txt;duptab;wait:3;log:$R2/d1.txt;quit"
  check "one same-named result selected" "$R2/d0.txt" "selected: readme.txt"
  check "a duplicated tab keeps one same-named item" "$R2/d1.txt" "selected: readme.txt"
  discard selection "$R" "$R2"
fi

# Rename prompts are window-modal sheets that scripts can answer.
if want sheets; then
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/F"; echo 1 > "$R/F/a.txt"; echo 2 > "$R/F/b.txt"; echo 3 > "$R/F/c.txt"
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
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/F" "$R/state"
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
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/F"; echo 1 > "$R/F/a.txt"
  run "$R" "$R/F" "wait:1;select:a.txt;click:file.open;wait:0.5;click:file.showInFinder;wait:0.5;click:file.openInTerminal;wait:0.5;log:$R/h.txt;quit"
  P=$(cd "$R/F" && pwd -P)   # items are listed under the physical path (/private/var/…)
  contains "opening a file is only logged" "$R/h.txt" "system open: open $P/a.txt"
  contains "Show in Finder is only logged" "$R/h.txt" "reveal $P/a.txt"
  contains "Open in Terminal is only logged" "$R/h.txt" "Terminal"
  discard headless "$R"
fi

# consistency.md: opening a file shortcut records its target in Recent.
if want recent; then
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/F" "$R/state"; echo 1 > "$R/F/report.txt"
  run "$R" "$R/F" "wait:1;select:report.txt;click:file.createShortcut;event;wait:1.5;escape;wait:0.5;log:$R/r0.txt;select:report.txt - Shortcut;click:file.open;wait:1;log:$R/r1.txt;quit" \
    ARBOR_STATE_DIR="$R/state"
  contains "shortcut created" "$R/r0.txt" "report.txt - Shortcut"
  contains "target opened (logged)" "$R/r1.txt" "open $(cd "$R/F" && pwd -P)/report.txt"
  contains "target recorded in Recent" "$R/r1.txt" "consistency: recent=[report.txt]"
  discard recent "$R"
fi

# file-operations.md: a job still waiting in the queue at quit is offered again at the next launch.
if want queue; then
  R=$(mktemp -d); mkdir -p "$R/trash" "$R/A" "$R/B"
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

exit $FAILED
