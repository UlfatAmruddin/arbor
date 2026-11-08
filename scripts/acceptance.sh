#!/usr/bin/env bash
# Headless run of the task scenarios T01–T30 (docs/SPEC.md §17.5) against build/Arbor.app.
# Every scenario builds its own fixture in a fresh `mktemp -d` folder with a private Trash, journal and history.
# Results and how to read them: docs/ACCEPTANCE.md.
#
# Usage: scripts/build-app.sh debug && scripts/acceptance.sh [T01 T07 …]   (no names = all scenarios)
#   ACCEPT_KEEP=1             keep each scenario's folder (logs, snapshots) and print its path
#   ARBOR_KEEP_FAILED=<dir>   move the folder of each failing scenario into <dir>/<id>
#   Stale-bundle guard, one-suite-at-a-time lock, ARBOR_REBUILD: scripts/lib/app-bundle.sh
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
. scripts/lib/app-bundle.sh
arbor_prepare_app acceptance.sh debug
APP="$ARBOR_APP_BIN"
WANTED=" ${*:-all} "
SUMMARY=()
FAILED_ANY=0

want() { [[ "$WANTED" == *" all "* || "$WANTED" == *" $1 "* ]]; }

# begin <id> <title>: start a scenario with a fresh fixture root in $R.
begin() {
  SCEN="$1"; SCEN_TITLE="$2"; SCEN_FAILS=0; SCEN_NOTE=""
  R=$(mktemp -d); R=$(cd "$R" && pwd -P); mkdir -p "$R/trash" "$R/journal" "$R/state"
  K="${R#/private}"   # the same folder as location keys spell it
  echo "== $SCEN $SCEN_TITLE"
}

# finish [note]: record the scenario's result. A note marks what the headless run can't show.
finish() {
  local result="pass"
  [ "$SCEN_FAILS" -gt 0 ] && { result="FAIL"; FAILED_ANY=1; }
  [ "$result" = "pass" ] && [ -n "${1:-}" ] && result="partial"
  SUMMARY+=("$(printf '%-4s %-8s %s%s' "$SCEN" "$result" "$SCEN_TITLE" "${1:+  ($1)}")")
  if [ "${ACCEPT_KEEP:-0}" = 1 ]; then echo "   kept: $R"; return; fi
  chmod -R u+rwx "$R" 2>/dev/null
  if [ "$result" = "FAIL" ] && [ -n "${ARBOR_KEEP_FAILED:-}" ]; then
    mkdir -p "$ARBOR_KEEP_FAILED"; rm -rf "${ARBOR_KEEP_FAILED:?}/$SCEN"; mv "$R" "$ARBOR_KEEP_FAILED/$SCEN"
    echo "   kept: $ARBOR_KEEP_FAILED/$SCEN"
  else
    rm -rf "$R"
  fi
}

# Scenarios that rely on permissions being enforced can't show anything when run as root.
as_root() { [ "$(id -u)" = 0 ]; }
skip_as_root() { echo "   skip  (running as root: permissions aren't enforced, so the access-denied case can't occur)"; finish "skipped: run as root"; }

# run <start folder or -> <script> [VAR=value…]: one headless launch (killed after 120 s).
run() {
  local start="$1" script="$2"; shift 2
  [ "$start" = "-" ] && start=""
  env ARBOR_HEADLESS=1 ARBOR_TEST_TRASH="$R/trash" ARBOR_JOURNAL_DIR="$R/journal" ARBOR_HISTORY_FILE="$R/history.json" \
    ARBOR_SCRIPT="$script" "$@" perl -e 'alarm shift; exec @ARGV' "${RUN_LIMIT:-120}" "$APP" ${start:+"$start"} >/dev/null 2>&1
}

ok()   { echo "   pass  $1"; }
bad()  { echo "   FAIL  $1"; SCEN_FAILS=$((SCEN_FAILS + 1)); }

check() {   # check <name> <file> <exact line>
  if [ -f "$2" ] && grep -qxF -- "$3" "$2"; then ok "$1"; else
    bad "$1: expected line “$3”"
    [ -f "$2" ] && grep -E "^(location|rows|selected|status|sheet|search box|tree|operations)" "$2" | head -12 | sed 's/^/          /'
  fi
}
contains() {   # contains <name> <file> <fixed text>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then ok "$1"; else
    bad "$1: expected to contain “$3”"
    [ -f "$2" ] && grep -E "^(location|rows|selected|status|sheet|search box|operations|system open)" "$2" | head -12 | sed 's/^/          /'
  fi
}
lacks() {   # lacks <name> <file> <fixed text>
  if [ -f "$2" ] && ! grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: did not expect “$3”"; fi
}
fact() {   # fact <name> <command…>
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# ---------------------------------------------------------------------------------------------------------------
if want T01; then
  begin T01 "Expand and browse hierarchy"
  mkdir -p "$R/fx/A/A1" "$R/fx/B"; echo 1 > "$R/fx/A/a.txt"
  # Pin the fixture so it has a tree node; ⇧F6 moves focus from the items to the tree; → expands, ↓ moves, Return opens.
  run "$R/fx" "wait:1;click:file.pin;wait:0.5;key:shift+F6;focus:$R/f0.txt;key:right;wait:0.8;focus:$R/f1.txt;log:$R/l1.txt;key:down;wait:1.2;focus:$R/f2.txt;log:$R/l2.txt;key:F6;wait:0.5;focus:$R/f3.txt;quit"
  contains "focus reaches the tree on the current folder" "$R/f0.txt" "region=navigationPane view=NavOutlineView row=\"fx\" expanded=false"
  contains "→ expands the node" "$R/f1.txt" "row=\"fx\" expanded=true"
  contains "expanded node shows its subfolders" "$R/l1.txt" "fx (pinned) |   A |   B |"
  check "expanding does not navigate" "$R/l1.txt" "location: folder:$K/fx  view: details"
  contains "↓ moves the tree selection and keeps focus in the tree" "$R/f2.txt" "region=navigationPane view=NavOutlineView row=\"A\""
  check "the selected node is shown in the list" "$R/l2.txt" "location: folder:$K/fx/A  view: details"
  check "the list shows the node's contents" "$R/l2.txt" "rows: A1 | a.txt"
  contains "F6 moves focus on to the items" "$R/f3.txt" "region=items"
  finish
fi

if want T02; then
  begin T02 "Back/Forward/Up across tabs"
  mkdir -p "$R/fx/A/A1" "$R/fx/A/A2" "$R/fx/B/B1"; echo 1 > "$R/fx/A/A1/x.txt"
  run "$R/fx" "wait:1;location:$R/fx/A;wait:0.8;select:A2;location:$R/fx/A/A1;wait:0.8;newtab;wait:0.8;location:$R/fx/B;wait:0.8;location:$R/fx/B/B1;wait:0.8;tab:1;wait:0.8;back;wait:0.8;log:$R/a.txt;tab:2;wait:0.8;back;wait:0.8;log:$R/b.txt;forward;wait:0.8;log:$R/c.txt;up;wait:0.8;log:$R/d.txt;tab:1;wait:0.8;forward;wait:0.8;log:$R/e.txt;quit"
  check "tab 1 Back returns to its previous folder" "$R/a.txt" "location: folder:$K/fx/A  view: details"
  check "Back restores the selection left there" "$R/a.txt" "selected: A2"
  check "tab 2 Back uses tab 2's own history" "$R/b.txt" "location: folder:$K/fx/B  view: details"
  check "tab 2 Forward" "$R/c.txt" "location: folder:$K/fx/B/B1  view: details"
  check "Up goes to the parent" "$R/d.txt" "location: folder:$K/fx/B  view: details"
  check "Up selects the folder just left" "$R/d.txt" "selected: B1"
  check "tab 1 Forward is unaffected by tab 2" "$R/e.txt" "location: folder:$K/fx/A/A1  view: details"
  finish
fi

if want T03; then
  begin T03 "Enter invalid/quoted/network path"
  mkdir -p "$R/fx/My Folder" "$R/fx/B"
  run "$R/fx/B" "wait:1;address:\"$R/fx/My Folder\";wait:1;log:$R/a.txt;address:$R/fx/nope/missing;wait:1;log:$R/b.txt;address:C:\\Windows;wait:1;log:$R/c.txt;address:open -a Calculator;wait:1;log:$R/d.txt;address:\\\\NAS-01\\Public;wait:3;log:$R/e.txt;address:smb://;wait:1;log:$R/f.txt;quit" ARBOR_FAKE_NETWORK=1 ARBOR_STATE_DIR="$R/state"
  check "quoted path with a space opens" "$R/a.txt" "location: folder:$K/fx/My Folder  view: details"
  contains "missing path: specific error" "$R/b.txt" "Can't find “$R/fx/nope/missing”. Check the spelling and try again."
  check "missing path: location unchanged" "$R/b.txt" "location: folder:$K/fx/My Folder  view: details"
  contains "drive letter is explained, not guessed" "$R/c.txt" "is a Windows drive path. Macs don't use drive letters"
  contains "command-like text is only a path" "$R/d.txt" "My Folder/open -a Calculator”. Check the spelling"
  check "typed text is never run" "$R/d.txt" "system open: none"
  contains "UNC path opens the share" "$R/e.txt" "NAS-01/Public  view: details"
  check "breadcrumb shows server and share" "$R/e.txt" "address: segments: Network > NAS-01 > Public; collapsed: 0"
  contains "address without a server is refused" "$R/f.txt" "isn't a valid address"
  finish
fi

if want T04; then
  begin T04 "Switch tabs with search/selection"
  mkdir -p "$R/fx/one" "$R/fx/two"; echo 1 > "$R/fx/one/readme.txt"; echo 2 > "$R/fx/two/readme-old.txt"; echo 3 > "$R/fx/notes.md"
  run "$R/fx" "wait:1;search:readme;event;wait:3;select:readme-old.txt;wait:0.5;log:$R/a.txt;newtab;wait:1;location:$R/fx;wait:1;select:notes.md;log:$R/b.txt;tab:1;wait:1.5;log:$R/c.txt;tab:2;wait:1;log:$R/d.txt;quit"
  check "search results in tab 1" "$R/a.txt" "rows: readme.txt | readme-old.txt"
  check "tab 2 has its own empty search box" "$R/b.txt" "search box: “”"
  check "back in tab 1: query kept" "$R/c.txt" "search box: “readme”"
  contains "back in tab 1: still the results" "$R/c.txt" "location: search?q=readme&scope=$K/fx"
  check "back in tab 1: its selection kept" "$R/c.txt" "selected: readme-old.txt"
  check "back in tab 2: its selection kept" "$R/d.txt" "selected: notes.md"
  check "back in tab 2: no query leaked" "$R/d.txt" "search box: “”"
  finish
fi

if want T05; then
  begin T05 "Read similar long filenames"
  mkdir -p "$R/fx"
  for v in "A.xlsx" "B.xlsx" "A.docx"; do echo x > "$R/fx/Quarterly financial report for the northern region 2024 final version $v"; done
  run "$R/fx" "wait:1;windowsize:900,560;wait:0.8;log:$R/a.txt;axdump:$R/ax.txt;snapshot:$R/long-light.png;quit" ARBOR_APPEARANCE=light
  check "all three names listed in full" "$R/a.txt" "rows: Quarterly financial report for the northern region 2024 final version A.docx | Quarterly financial report for the northern region 2024 final version A.xlsx | Quarterly financial report for the northern region 2024 final version B.xlsx"
  contains "each row has a full-name tooltip" "$R/ax.txt" "help=\"Quarterly financial report for the northern region"
  fact "snapshot taken (middle truncation keeps “A.xlsx” / “B.xlsx” visible; read the PNG)" test -s "$R/long-light.png"
  finish
fi

if want T06; then
  begin T06 "Change sort/group/columns"
  mkdir -p "$R/fx/Folder 9" "$R/fx/Folder 10"; echo 1 > "$R/fx/file2.txt"; echo 1 > "$R/fx/file10.txt"; head -c 5000 /dev/zero > "$R/fx/big.md"
  run "$R/fx" "wait:1;log:$R/a.txt;select:file10.txt;sortcol:size:desc;wait:1;log:$R/b.txt;groupby:type;wait:1;log:$R/c.txt;showcolumn:dateCreated;wait:0.8;log:$R/d.txt;hidecolumn:dateCreated;wait:0.8;log:$R/e.txt;groupby:none;sortcol:name:desc;wait:1;log:$R/f.txt;quit"
  check "natural order, folders first" "$R/a.txt" "rows: Folder 9 | Folder 10 | big.md | file2.txt | file10.txt"
  check "size descending; ties by name; folders stay first" "$R/b.txt" "rows: Folder 9 | Folder 10 | big.md | file2.txt | file10.txt"
  contains "previous key becomes the tie-breaker" "$R/b.txt" "sort: size↓ then name↑"
  check "sorting keeps the selection" "$R/b.txt" "selected: file10.txt"
  check "group by Type shows headers" "$R/c.txt" "table rows: [Folder] | Folder 9 | Folder 10 | [Markdown Document] | big.md | [Plain Text Document] | file2.txt | file10.txt"
  check "grouping keeps the selection" "$R/c.txt" "selected: file10.txt"
  contains "column added" "$R/d.txt" "dateCreated(160)"
  check "adding a column keeps the selection" "$R/d.txt" "selected: file10.txt"
  check "removing a column keeps the selection" "$R/e.txt" "selected: file10.txt"
  check "name descending, folders still first" "$R/f.txt" "rows: Folder 10 | Folder 9 | file10.txt | file2.txt | big.md"
  finish "no per-comparison disk I/O is shown by unit tests (BackgroundSortTests, LargeSort), not by this run"
fi

if want T07; then
  begin T07 "Revisit folder with override"
  mkdir -p "$R/fx/A" "$R/fx/B"; echo 1 > "$R/fx/A/a.txt"
  run "$R/fx/A" "wait:1;view:largeIcons;wait:1;location:$R/fx/B;wait:1;log:$R/a.txt;back;wait:1;log:$R/b.txt;menu:view:$R/m.txt;quit" ARBOR_STATE_DIR="$R/state"
  run "$R/fx/A" "wait:1.5;log:$R/c.txt;quit" ARBOR_STATE_DIR="$R/state"
  check "another folder keeps the default view" "$R/a.txt" "location: folder:$K/fx/B  view: details"
  check "returning shows the folder's own view" "$R/b.txt" "location: folder:$K/fx/A  view: largeIcons"
  contains "the source of the rule is stated" "$R/b.txt" "folder view: source=Saved for this folder"
  contains "View menu explains which rule applies" "$R/m.txt" "Folder view: Saved for this folder (Documents)"
  check "the override survives a relaunch" "$R/c.txt" "location: folder:$K/fx/A  view: largeIcons"
  finish
fi

if want T08; then
  begin T08 "Range/disjoint selection after updates"
  mkdir -p "$R/fx"; for n in a b c d e f; do echo $n > "$R/fx/$n.txt"; done
  # Files appear and disappear while the selection is shown (after a.txt is written).
  ( until [ -f "$R/a.txt" ]; do sleep 0.2; done; touch "$R/fx/bb.txt" "$R/fx/zz.txt"; rm -f "$R/fx/f.txt" ) &
  run "$R/fx" "wait:1;select:b.txt;key:shift+down;key:shift+down;log:$R/a.txt;wait:3;log:$R/b.txt;key:shift+up;wait:0.5;log:$R/c.txt;select:a.txt|e.txt;wait:0.5;refresh;wait:1;log:$R/d.txt;quit"
  wait
  check "⇧↓ twice extends from the anchor" "$R/a.txt" "selected: b.txt | c.txt | d.txt"
  check "listing updated by outside changes" "$R/b.txt" "rows: a.txt | b.txt | bb.txt | c.txt | d.txt | e.txt | zz.txt"
  check "the same items stay selected after the update" "$R/b.txt" "selected: b.txt | c.txt | d.txt"
  check "⇧↑ shrinks the range toward the same anchor" "$R/c.txt" "selected: b.txt | c.txt"
  check "a disjoint selection survives Refresh" "$R/d.txt" "selected: a.txt | e.txt"
  finish "a file that appears inside a selected range isn't added by the next ⇧↑/⇧↓ (Explorer reselects the whole anchor-to-focus range)"
fi

if want T09; then
  begin T09 "Right-click a selected batch"
  mkdir -p "$R/fx"; for n in a b c d; do echo $n > "$R/fx/$n.txt"; done
  run "$R/fx" "wait:1;view:largeIcons;wait:1;select:a.txt|b.txt|c.txt;iconclick:b.txt:right;wait:1;log:$R/a.txt;key:shift+F10;wait:1;contextkey:$R/b.txt;log:$R/b.txt;menu:item:$R/m.txt;click:edit.copy;event;wait:0.5;log:$R/c.txt;iconclick:d.txt:right;wait:1;log:$R/d.txt;quit"
  check "right-click on a selected item keeps the batch" "$R/a.txt" "selected: a.txt | b.txt | c.txt"
  contains "context menu for the focused batch (⇧F10) offers batch commands" "$R/b.txt" "Batch rename…"
  check "menu doesn't drop the batch" "$R/b.txt" "selected: a.txt | b.txt | c.txt"
  contains "a command acts on all three" "$R/c.txt" "clipboard: names=[a.txt,b.txt,c.txt] paste=copy"
  check "right-click outside the batch selects that item" "$R/d.txt" "selected: d.txt"
  finish "pointer menus can't be drawn headless; the menu's titles come from the ⇧F10 path"
fi

if want T10; then
  begin T10 "Rename dotfile/case-only/conflict"
  mkdir -p "$R/fx"; echo e > "$R/fx/.env"; echo r > "$R/fx/Readme.md"; echo a > "$R/fx/a.txt"; echo b > "$R/fx/b.txt"
  run "$R/fx" "wait:1;click:view.hiddenItems;wait:1;log:$R/a.txt;select:Readme.md;click:file.rename;event;wait:0.5;log:$R/b.txt;type:README.md;enter;event;wait:1;log:$R/c.txt;select:.env;click:file.rename;event;wait:0.5;log:$R/d.txt;type:.env.local;enter;event;wait:1;sheetlog:$R/e.txt;button:Use .local;wait:1.5;log:$R/f.txt;select:b.txt;click:file.rename;event;type:a.txt;enter;wait:1;sheetlog:$R/g.txt;button:OK;wait:1;log:$R/h.txt;quit"
  check "dotfile listed with hidden items shown" "$R/a.txt" "rows: .env | a.txt | b.txt | Readme.md"
  contains "F2 selects the base name only" "$R/b.txt" "rename field: editing “Readme.md” selected {0, 6}"
  check "case-only rename" "$R/c.txt" "rows: .env | a.txt | b.txt | README.md"
  fact "case-only rename changed the name on disk" test -n "$(ls "$R/fx" | grep -x README.md)"
  contains "a dotfile's whole name is selected" "$R/d.txt" "rename field: editing “.env” selected {0, 4}"
  contains "adding an extension to a dotfile is named correctly" "$R/e.txt" "If you add “.local” to the name"
  check "dotfile renamed after confirming" "$R/f.txt" "rows: .env.local | a.txt | b.txt | README.md"
  contains "a name conflict is refused" "$R/g.txt" "Couldn't rename “b.txt”."
  contains "the typed name stays in the field" "$R/h.txt" "rename field: editing “a.txt”"
  fact "nothing was overwritten" test "$(cat "$R/fx/a.txt")" = a -a "$(cat "$R/fx/b.txt")" = b
  finish
fi

if want T11; then
  begin T11 "Cut, change clipboard, cancel"
  mkdir -p "$R/A" "$R/B"; echo one > "$R/A/one.txt"; echo two > "$R/A/two.txt"; echo old > "$R/B/three.txt"; echo new > "$R/A/three.txt"
  run "$R/A" "wait:1;select:one.txt;click:edit.cut;event;wait:0.3;log:$R/a.txt;select:two.txt;click:edit.copy;event;wait:0.3;log:$R/b.txt;location:$R/B;wait:1;click:edit.paste;event;wait:2;log:$R/c.txt;location:$R/A;wait:1;select:three.txt;click:edit.cut;event;location:$R/B;wait:1;click:edit.paste;event;wait:2;log:$R/c2.txt;opbutton:Cancel;wait:1.5;log:$R/d.txt;location:$R/A;wait:1;log:$R/e.txt;quit"
  check "cut marks the item" "$R/a.txt" "clipboard: names=[one.txt] paste=move cut marks=[one.txt]"
  check "copying something else clears the stale cut mark" "$R/b.txt" "clipboard: names=[two.txt] paste=copy cut marks=[]"
  check "paste copies what the clipboard now holds" "$R/c.txt" "rows: three.txt | two.txt"
  fact "the cut item never moved" test -f "$R/A/one.txt" -a ! -e "$R/B/one.txt"
  contains "moving onto an existing name asks" "$R/c2.txt" "Replace or Skip Files"
  check "cancelling the conflict leaves the destination alone" "$R/d.txt" "rows: three.txt | two.txt"
  fact "destination file unchanged" test "$(cat "$R/B/three.txt")" = old
  check "the source of the cancelled move is still there" "$R/e.txt" "rows: one.txt | three.txt | two.txt"
  finish
fi

if want T12; then
  begin T12 "Copy promised/virtual content"
  mkdir -p "$R/src/docs" "$R/fx" "$R/dest" "$R/drop"
  echo "notes inside" > "$R/src/docs/notes.txt"; head -c 3000000 /dev/urandom > "$R/src/big.bin"
  (cd "$R/src" && /usr/bin/zip -qr "$R/fx/pack.zip" docs big.bin)
  run "$R/fx" "wait:1;location:archive?file=$K/fx/pack.zip&inner=docs;wait:1.5;log:$R/a.txt;select:notes.txt;click:edit.copy;event;wait:2;location:$R/dest;wait:1;click:edit.paste;event;wait:2;log:$R/b.txt;location:archive?file=$K/fx/pack.zip&inner=;wait:1.5;promise:big.bin:$R/drop;wait:3;log:$R/c.txt;quit"
  check "archive browsed as a folder" "$R/a.txt" "rows: notes.txt"
  fact "copied member arrived with its content" test "$(cat "$R/dest/notes.txt" 2>/dev/null)" = "notes inside"
  fact "a promised member is written when dropped, byte for byte" cmp -s "$R/src/big.bin" "$R/drop/big.bin"
  fact "the archive itself is unchanged" test -f "$R/fx/pack.zip"
  finish "memory while streaming isn't measured here; bsdtar extracts into a staging folder on disk"
fi

if want T13; then
  begin T13 "Cross-volume move and cancellation"
  mkdir -p "$R/A" "$R/mnt"
  if hdiutil create -size 40m -fs HFS+ -volname ArborT13 -quiet "$R/v.dmg" && \
     hdiutil attach -nobrowse -noautoopen -quiet -mountpoint "$R/mnt" "$R/v.dmg"; then
    for n in 1 2 3 4; do head -c 3000000 /dev/urandom > "$R/A/f$n.bin"; done
    run "$R/A" "wait:1;opstart:move:$R/A/f1.bin|$R/A/f2.bin|$R/A/f3.bin|$R/A/f4.bin:$R/mnt;wait:4;log:$R/a.txt;opcancel;wait:2;log:$R/b.txt;quit" ARBOR_TRANSFER_THROTTLE=1500000
    contains "the move was running when cancelled" "$R/a.txt" "operations: move phase="
    check "no job left after cancelling" "$R/b.txt" "operations: none"
    left=0; both=0; none=0
    for n in 1 2 3 4; do
      a=0; m=0; [ -f "$R/A/f$n.bin" ] && a=1; [ -f "$R/mnt/f$n.bin" ] && m=1
      [ $a = 1 ] && [ $m = 1 ] && both=$((both + 1)); [ $a = 0 ] && [ $m = 0 ] && none=$((none + 1)); [ $a = 1 ] && left=$((left + 1))
    done
    fact "no file was lost (each is in one place)" test $none = 0
    fact "no half-copied duplicate left on the destination" test $both = 0
    fact "items not yet moved stay in the source" test $left -ge 1
    fact "moved items arrived whole" sh -c "for f in '$R'/mnt/*.bin; do [ -e \"\$f\" ] || continue; [ \$(stat -f %z \"\$f\") = 3000000 ] || exit 1; done"
    contains "the partial outcome is recorded in Operation history" "$R/b.txt" "history: 1 records"
    hdiutil detach -force -quiet "$R/mnt" >/dev/null 2>&1
    finish
  else
    echo "   skip  (no disk image)"; finish "skipped: hdiutil unavailable"
  fi
fi

if want T14; then
  begin T14 "Merge or replace folders"
  mkdir -p "$R/src/X" "$R/dest/X" "$R/src2" "$R/dest2" "$R/src3/Y" "$R/dest3/Y"
  echo new > "$R/src/X/new.txt"; echo new > "$R/src/X/same.txt"; echo old > "$R/dest/X/old.txt"; echo old > "$R/dest/X/same.txt"
  echo new > "$R/src2/file.txt"; echo old > "$R/dest2/file.txt"; echo new > "$R/src3/Y/y.txt"; echo old > "$R/dest3/Y/old.txt"
  # Default (Windows' "Hide folder merge conflicts" on): folders merge, same-named files are asked about.
  run "$R/src" "wait:1;opstart:copy:$R/src/X:$R/dest;wait:2;log:$R/a.txt;opbutton:Skip this file;wait:2;log:$R/c.txt;opstart:copy:$R/src2/file.txt:$R/dest2;wait:2;log:$R/d.txt;opbutton:Replace the file in the destination;wait:2;log:$R/e.txt;opprefs:mergeprompt=on;opstart:copy:$R/src3/Y:$R/dest3;wait:2;log:$R/f.txt;opbutton:No;wait:2;log:$R/g.txt;quit"
  contains "same-named files inside merged folders are asked about" "$R/a.txt" "file-op dialogs: Replace or Skip Files"
  contains "with the merge prompt turned on, a folder conflict asks first" "$R/f.txt" "file-op dialogs: Confirm Folder Replace"
  check "No to the merge leaves nothing running" "$R/g.txt" "operations: none"
  fact "No to the merge copied nothing" test ! -e "$R/dest3/Y/y.txt" -a -f "$R/dest3/Y/old.txt"
  fact "merge kept the destination's own files" test -f "$R/dest/X/old.txt"
  fact "merge added the new files" test -f "$R/dest/X/new.txt"
  fact "Skip kept the existing file's content" test "$(cat "$R/dest/X/same.txt")" = old
  fact "Replace put the new content in place" test "$(cat "$R/dest2/file.txt")" = new
  fact "the replaced file went to the Trash, not erased" grep -rqx old "$R/trash"
  finish
fi

if want T15; then
  begin T15 "Change destination while prompt open"
  mkdir -p "$R/src" "$R/dest"; echo new > "$R/src/a.txt"; echo old > "$R/dest/a.txt"
  ( until [ -f "$R/open.txt" ]; do sleep 0.2; done; echo "edited elsewhere" > "$R/dest/a.txt" ) &
  run "$R/src" "wait:1;opstart:copy:$R/src/a.txt:$R/dest;wait:2;log:$R/open.txt;wait:1.5;opbutton:Replace the file in the destination;wait:2;log:$R/b.txt;opbutton:Skip this file;wait:2;log:$R/c.txt;quit"
  wait
  contains "the conflict was asked" "$R/open.txt" "Replace or Skip Files"
  contains "after the outside edit the decision is asked again" "$R/b.txt" "Replace or Skip Files"
  fact "the edit made while the prompt was open survived" test "$(cat "$R/dest/a.txt")" = "edited elsewhere"
  fact "nothing went to the Trash" test -z "$(ls -A "$R/trash")"
  finish
fi

if want T16; then
  begin T16 "Recover interrupted operation"
  mkdir -p "$R/A" "$R/B"; for n in 1 2 3; do head -c 2000000 /dev/urandom > "$R/A/f$n.bin"; done
  # The first launch is killed (SIGALRM) in the middle of the copy: a crash, not a quit.
  RUN_LIMIT=6 run "$R/A" "wait:1;opstart:copy:$R/A/f1.bin|$R/A/f2.bin|$R/A/f3.bin:$R/B;wait:60;quit" ARBOR_TRANSFER_THROTTLE=800000
  fact "the crash left a journal" test "$(ls "$R/journal" | wc -l | tr -d ' ')" -ge 1
  before=$(ls "$R/B" | wc -l | tr -d ' ')
  run "$R/A" "wait:3;sheetlog:$R/a.txt;log:$R/a.txt;quit"
  contains "the next launch lists what finished, what didn't and what is uncertain" "$R/a.txt" "    Uncertain: "
  contains "retrying is the user's choice" "$R/a.txt" "buttons: Retry remaining, Dismiss"
  lacks "nothing is retried by itself" "$R/a.txt" "operations: copy"
  fact "no write was replayed without asking" test "$(ls "$R/B" | wc -l | tr -d ' ')" = "$before"
  finish
fi

if want T17; then
  begin T17 "Undo after an external edit"
  mkdir -p "$R/F/sub"; echo e > "$R/F/e.txt"; echo r > "$R/F/r.txt"
  ( until [ -f "$R/copied.txt" ]; do sleep 0.2; done; echo "edited after the copy" > "$R/F/sub/e.txt"; echo "someone else's" > "$R/F/r.txt" ) &
  run "$R/F" "wait:1;select:e.txt;click:edit.copy;event;location:$R/F/sub;wait:1;click:edit.paste;event;wait:2;location:$R/F;wait:1;select:r.txt;click:file.rename;event;type:r2.txt;enter;event;wait:1;log:$R/copied.txt;wait:1.5;action:undo:;event;wait:1.5;log:$R/a.txt;sheetlog:$R/a.txt;action:undo:;event;wait:2;log:$R/b.txt;sheetlog:$R/b.txt;quit"
  wait
  fact "undo of the rename refused: the old name is taken" test -f "$R/F/r2.txt" -a "$(cat "$R/F/r.txt")" = "someone else's"
  fact "undo of the copy kept the edited copy" test "$(cat "$R/F/sub/e.txt" 2>/dev/null)" = "edited after the copy"
  fact "the original was never touched" test "$(cat "$R/F/e.txt")" = e
  finish
fi

if want T18 && as_root; then begin T18 "Search with missing coverage"; skip_as_root
elif want T18; then
  begin T18 "Search with missing coverage"
  mkdir -p "$R/fx/open" "$R/fx/locked"; echo 1 > "$R/fx/open/report.txt"; echo 2 > "$R/fx/locked/report-2.txt"; chmod 000 "$R/fx/locked"
  run "$R/fx" "wait:1;search:report;event;wait:3;log:$R/a.txt;searchdetails:$R/d.txt;quit"
  chmod 755 "$R/fx/locked"
  check "readable match found" "$R/a.txt" "rows: report.txt"
  contains "status says the search is incomplete and why" "$R/a.txt" "Search incomplete: 1 folder couldn't be opened (access denied)"
  contains "scope shown in the address bar" "$R/a.txt" "Search Results in fx"
  contains "details name the unreadable folder" "$R/d.txt" "locked"
  finish
fi

if want T19; then
  begin T19 "Mixed AQS query/localized properties"
  mkdir -p "$R/fx"; echo a > "$R/fx/a.txt"; head -c 5000 /dev/zero > "$R/fx/big.md"; echo c > "$R/fx/c.md"; head -c 5000 /dev/zero > "$R/fx/big.txt"
  run "$R/fx" "wait:1;search:ext:md OR ext:txt size:>1KB;event;wait:3;log:$R/a.txt;searchclose;wait:1;search:ext:md OR (ext:txt size:>1KB);event;wait:3;log:$R/b.txt;searchclose;wait:1;search:größe:>1KB;event;wait:3;log:$R/c.txt;searchclose;wait:1;search:kind:game;event;wait:3;log:$R/d.txt;quit"
  check "AND/OR fold left to right" "$R/a.txt" "rows: big.md | big.txt"
  check "parentheses override the order" "$R/b.txt" "rows: big.md | big.txt | c.md"
  contains "a localized property name is rejected visibly" "$R/c.txt" "Search couldn't run"
  contains "a Windows-only kind is rejected visibly" "$R/d.txt" "Search couldn't run"
  finish
fi

if want T20; then
  begin T20 "Preview a cloud-only large file"
  CL="$R/OneDrive-Personal"; mkdir -p "$CL"; head -c 20000000 /dev/zero > "$CL/video.mov"; echo x > "$CL/b.txt"
  run "$CL" "wait:1;select:video.mov;click:view.previewPane;wait:1.5;log:$R/a.txt;axdump:$R/ax.txt;snapshot:$R/cloud-preview.png;click:view.previewPane;wait:1;log:$R/b.txt;quit" \
    ARBOR_TEST_CLOUD_ROOT="$CL" ARBOR_TEST_CLOUD_ACCOUNT=Personal ARBOR_TEST_CLOUD_STATUS="video.mov=online,b.txt=available"
  contains "status column reports online-only" "$R/a.txt" "video.mov=Online-only"
  contains "preview offers a download instead of fetching" "$R/ax.txt" "is available when online"
  contains "the download is a separate, explicit button" "$R/ax.txt" "Download to preview"
  check "closing the pane releases it" "$R/b.txt" "side pane: none  nav pane: true"
  finish "download policy shown with a simulated provider; real File Provider downloads weren't run"
fi

if want T21 && as_root; then begin T21 "Paste into library"; skip_as_root
elif want T21; then
  begin T21 "Paste into library"
  mkdir -p "$R/L1" "$R/L2" "$R/RO" "$R/src"; echo x > "$R/src/doc.txt"; echo y > "$R/src/doc2.txt"; echo l2 > "$R/L2/in-l2.txt"; chmod 555 "$R/RO"
  run "$R/src" "wait:1;librarydef:Documents=$R/L1|$R/L2;select:doc.txt;click:edit.copy;event;location:library?name=Documents;wait:1.5;log:$R/a.txt;click:edit.paste;event;wait:2;log:$R/b.txt;librarydef:Documents=$R/RO;wait:1;location:$R/src;wait:1;select:doc2.txt;click:edit.copy;event;location:library?name=Documents;wait:1.5;click:edit.paste;event;wait:1.5;log:$R/c.txt;sheetlog:$R/c.txt;quit"
  chmod 755 "$R/RO"
  contains "the library merges its folders" "$R/a.txt" "in-l2.txt"
  fact "Paste wrote to the save location (first folder)" test -f "$R/L1/doc.txt" -a ! -e "$R/L2/doc.txt"
  contains "no writable folder: the reason is shown" "$R/c.txt" "This library has no save location."
  fact "nothing was written anywhere else" test ! -e "$R/RO/doc2.txt"
  finish
fi

if want T22; then
  begin T22 "Remove a collection source/recent entry"
  mkdir -p "$R/fx" "$R/L1" "$R/L2"; echo r > "$R/fx/report.txt"; echo k > "$R/L2/keep.txt"
  run "$R/fx" "wait:1;homerecord:$R/fx/report.txt;location:home;wait:1.5;log:$R/a.txt;homeselect:recent:report.txt;homeperform:home.removeFromRecent;wait:1;log:$R/b.txt;librarydef:Documents=$R/L1|$R/L2;managelibrary:Documents;wait:1;dialog:remove:$R/L2;dialog:ok;wait:1;location:library?name=Documents;wait:1.5;log:$R/c.txt;quit" ARBOR_STATE_DIR="$R/state"
  contains "Recent lists the opened file" "$R/a.txt" "report.txt"
  lacks "Remove from Recent removes the entry" "$R/b.txt" "recent=[report.txt"
  fact "the file itself stays" test -f "$R/fx/report.txt"
  lacks "the removed folder's items leave the library" "$R/c.txt" "keep.txt"
  fact "the removed folder's files stay on disk" test -f "$R/L2/keep.txt"
  finish
fi

if want T23 && as_root; then begin T23 "Delete on nonrecycling provider"; skip_as_root
elif want T23; then
  begin T23 "Delete on nonrecycling provider"
  mkdir -p "$R/fx"; echo a > "$R/fx/a.txt"; chmod 555 "$R/trash"   # the Trash can't take anything
  run "$R/fx" "wait:1;select:a.txt;click:file.trash;event;wait:1.5;log:$R/a.txt;opsnap:dialog:$R/cannot-trash.png;opbutton:No;wait:1;log:$R/b.txt;select:a.txt;click:file.trash;event;wait:1.5;opbutton:Yes;wait:1.5;log:$R/e.txt;quit"
  chmod 755 "$R/trash"
  contains "a failed move to the Trash asks before deleting permanently" "$R/a.txt" "file-op dialogs: Delete File"
  check "No keeps the file" "$R/b.txt" "rows: a.txt"
  fact "only after Yes is the file gone" test ! -e "$R/fx/a.txt"
  finish
fi

if want T24; then
  begin T24 "Same-name network shares"
  mkdir -p "$R/fx"
  run "$R/fx" "wait:1;address:\\\\NAS-01\\Public;wait:3;log:$R/a.txt;address:smb://OFFICE-PC/Public/;wait:3;log:$R/b.txt;back;wait:2;log:$R/c.txt;quit" ARBOR_FAKE_NETWORK=1 ARBOR_STATE_DIR="$R/state"
  check "first share: its server in the breadcrumb" "$R/a.txt" "address: segments: Network > NAS-01 > Public; collapsed: 0"
  check "second share with the same name: its own server" "$R/b.txt" "address: segments: Network > OFFICE-PC > Public; collapsed: 0"
  fact "the two shares are different folders" sh -c "[ \"\$(grep '^location:' '$R/a.txt')\" != \"\$(grep '^location:' '$R/b.txt')\" ]"
  check "Back returns to the first server's share" "$R/c.txt" "address: segments: Network > NAS-01 > Public; collapsed: 0"
  finish "simulated servers (ARBOR_FAKE_NETWORK); no real SMB server was available"
fi

if want T25; then
  begin T25 "Extract/create/modify each archive"
  mkdir -p "$R/fx/docs" "$R/out"; echo "a" > "$R/fx/docs/a.txt"; echo "b" > "$R/fx/b.txt"
  /usr/bin/python3 -I - "$R/fx/evil.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../escaped.txt", "outside")
    z.writestr("/abs.txt", "absolute")
    z.writestr("ok.txt", "fine")
PY
  run "$R/fx" "wait:1;select:docs;click:archive.compress.zip;event;wait:3;escape;wait:0.5;select:b.txt;click:archive.compress.7z;event;wait:3;escape;wait:0.5;select:b.txt;click:archive.compress.tar;event;wait:3;escape;wait:1;log:$R/a.txt;location:archive?file=$K/fx/docs.zip&inner=docs;wait:1.5;log:$R/b.txt;location:$R/fx;wait:1;select:evil.zip;click:archive.extractAll;wait:1;sheetpath:$R/out;sheetshow:off;button:Extract;wait:3;log:$R/c.txt;quit"
  contains "ZIP, 7z and TAR created next to the items" "$R/a.txt" "docs.zip"
  fact "7z archive written" test -s "$R/fx/b.7z"
  fact "tar archive written" test -s "$R/fx/b.tar"
  check "the new ZIP opens as a folder" "$R/b.txt" "rows: a.txt"
  contains "archives are read-only: Rename/Delete/Paste off inside" "$R/b.txt" "file.rename(off)"
  fact "a member with ../ was not written outside" test ! -e "$R/escaped.txt" -a ! -e "$R/out/../escaped.txt" -a ! -e /abs.txt
  fact "the safe member was extracted" sh -c "find '$R/out' -name ok.txt | grep -q ."
  finish "RAR extraction untested (no fixture can be made with built-in tools); modifying archives is not offered (read-only)"
fi

if want T26; then
  begin T26 "Offline device/cloud disconnect"
  mkdir -p "$R/fx/local" "$R/mnt"; echo l > "$R/fx/local/l.txt"
  run "$R/fx" "wait:1;address:\\\\OFFLINE-PC\\Data;wait:1;log:$R/a.txt;newtab;wait:0.5;location:$R/fx/local;wait:1;log:$R/b.txt;tab:1;wait:4;log:$R/c.txt;quit" ARBOR_FAKE_NETWORK=1 ARBOR_STATE_DIR="$R/state" ARBOR_NETWORK_TIMEOUT=3 ARBOR_NETWORK_MOUNT_TIMEOUT=3
  contains "the slow server shows a loading state" "$R/a.txt" "Loading “Data”…"
  check "another tab browses local folders meanwhile" "$R/b.txt" "rows: l.txt"
  contains "after the deadline: an explicit error" "$R/c.txt" "didn't respond in time"
  contains "…with Retry" "$R/c.txt" "[Retry]"
  if hdiutil create -size 8m -fs HFS+ -volname ArborT26 -quiet "$R/v.dmg" && \
     hdiutil attach -nobrowse -noautoopen -quiet -mountpoint "$R/mnt" "$R/v.dmg"; then
    echo x > "$R/mnt/x.txt"
    ( until [ -f "$R/d.txt" ]; do sleep 0.2; done; hdiutil detach -force -quiet "$R/mnt" ) &
    run "$R/mnt" "wait:1.5;log:$R/d.txt;wait:4;log:$R/e.txt;quit"
    wait
    check "a tab on the disk image lists it" "$R/d.txt" "rows: x.txt"
    contains "after the disk disappears the tab leaves it instead of hanging" "$R/e.txt" "location: thismac"
  else
    echo "   skip  disk disconnect (hdiutil couldn't create or attach a disk image here)"
  fi
  finish "simulated servers; real network loss and File Provider disconnects weren't run"
fi

if want T27; then
  begin T27 "Keyboard and VoiceOver task sequence"
  mkdir -p "$R/fx/Dest"; echo b > "$R/fx/budget.txt"; echo c > "$R/fx/cat.txt"
  # Keys go through the real keyboard path: `key:` for the file list, `menukey:` for menu shortcuts (⌘X, ⌘V, ⌘Z).
  run "$R/fx" "wait:1;key:b;wait:1.2;log:$R/a.txt;menukey:cmd+x;wait:0.5;key:d;wait:1.2;key:return;wait:1.2;log:$R/b.txt;menukey:cmd+v;wait:2;log:$R/c.txt;menukey:cmd+z;wait:2;key:delete;wait:1.2;log:$R/d.txt;axaudit:$R/ax.txt;quit"
  check "type-to-select finds the file" "$R/a.txt" "selected: budget.txt"
  contains "Return opens the selected folder" "$R/b.txt" "location: folder:$K/fx/Dest"
  check "⌘V moves the cut file in" "$R/c.txt" "rows: budget.txt"
  check "⌘Z, then Delete (Back): the file is back where it was" "$R/d.txt" "rows: Dest | budget.txt | cat.txt"
  fact "after undo the file is in its original folder only" test -f "$R/fx/budget.txt" -a ! -e "$R/fx/Dest/budget.txt"
  contains "accessibility audit: no unnamed controls or empty rows" "$R/ax.txt" "0 problems"
  finish "VoiceOver itself wasn't run; the accessibility tree it reads was audited"
fi

if want T28; then
  begin T28 "Large directory and event churn"
  mkdir -p "$R/big"; (cd "$R/big" && for i in $(seq 1 20000); do : > "f$i.txt"; done)
  ( until [ -f "$R/a.txt" ]; do sleep 0.2; done
    (cd "$R/big" && for i in $(seq 1 2000); do : > "new$i.txt"; done; for i in $(seq 1 1000); do rm -f "f$i.txt"; done) ) &
  run "$R/big" "wait:3;select:f15000.txt;stalls:open:$R/s.txt;log:$R/a.txt;wait:8;log:$R/b.txt;stalls:churn:$R/s.txt;memlog:end:$R/s.txt;quit"
  wait
  contains "20,000 entries listed" "$R/a.txt" "status: 20,000 items"
  contains "after 2,000 new and 1,000 deleted files the count is right" "$R/b.txt" "status: 21,000 items"
  check "the selection survived the churn" "$R/b.txt" "selected: f15000.txt"
  fact "no main-thread stall over 350 ms during the churn" sh -c "! grep -E '^stall churn ms=([4-9][0-9]{2}|[0-9]{4,})' '$R/s.txt' | grep -q ."
  finish
fi

if want T29; then
  begin T29 "Repeated previews/search/tab closure"
  mkdir -p "$R/fx"; for i in $(seq 1 40); do echo "line $i" > "$R/fx/note$i.txt"; done
  CYCLE="select:note1.txt;click:view.previewPane;wait:0.3;select:note2.txt;wait:0.3;click:view.previewPane;newtab;location:$R/fx;wait:0.5;search:note;event;wait:1;searchclose;closetab;wait:0.3"
  S="wait:1;$CYCLE;$CYCLE;memlog:warm:$R/m.txt"
  # Two warm-up cycles, then two rounds of eight; the second round must not keep growing.
  for i in $(seq 1 8); do S+=";$CYCLE"; done
  S+=";wait:2;memlog:round1:$R/m.txt"
  for i in $(seq 1 8); do S+=";$CYCLE"; done
  S+=";wait:2;memlog:round2:$R/m.txt;quit"
  RUN_LIMIT=400 run "$R/fx" "$S"
  fact "memory measured three times" test "$(grep -c '^mem ' "$R/m.txt")" = 3
  growth=$(awk '/^mem round1 /{split($3,a,"="); x=a[2]} /^mem round2 /{split($3,a,"="); y=a[2]} END{if (x == "" || y == "") print "none"; else printf "%.1f", y - x}' "$R/m.txt")
  echo "   info  footprint change over the second round of 8 cycles: $growth MB"
  fact "no monotonic growth: the second round adds at most 4 MB" awk -v g="$growth" 'BEGIN { exit !(g != "none" && g + 0 <= 4) }'
  finish
fi

if want T30; then
  begin T30 "Quit/close during active work"
  mkdir -p "$R/A" "$R/B"; for n in 1 2 3; do head -c 2000000 /dev/urandom > "$R/A/f$n.bin"; done
  run "$R/A" "wait:1;newtab;wait:0.5;opstart:copy:$R/A/f1.bin|$R/A/f2.bin|$R/A/f3.bin:$R/B;wait:1;closetab;wait:1;log:$R/a.txt;terminate" ARBOR_TRANSFER_THROTTLE=800000
  contains "closing the tab doesn't stop the job" "$R/a.txt" "operations: copy phase="
  fact "quitting kept the job's journal" test "$(ls "$R/journal" | wc -l | tr -d ' ')" -ge 1
  fact "the file being copied at quit isn't left half-written" sh -c "for f in '$R'/B/*.bin; do [ -e \"\$f\" ] || continue; [ \$(stat -f %z \"\$f\") = 2000000 ] || exit 1; done"
  run "$R/A" "wait:3;sheetlog:$R/b.txt;quit"
  contains "the next launch reports what was left unfinished" "$R/b.txt" "sheet: "
  finish "the quit confirmation itself is an app-modal alert; the script uses its Quit Anyway path"
fi

# ---------------------------------------------------------------------------------------------------------------
echo
echo "Summary"
printf '%s\n' "${SUMMARY[@]}"
exit $FAILED_ANY
