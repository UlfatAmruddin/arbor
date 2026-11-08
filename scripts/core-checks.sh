#!/usr/bin/env bash
# Headless regression checks for core browsing and file operations (docs/features/qa-core.md).
# Usage: scripts/build-app.sh debug && scripts/core-checks.sh
#   ARBOR_KEEP_FAILED=<dir>   move the folder (logs, fixture) of each block with a failure into <dir>
#   Stale-bundle guard, one-suite-at-a-time lock, ARBOR_REBUILD: scripts/lib/app-bundle.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/app-bundle.sh
arbor_prepare_app core-checks.sh debug
APP="$ARBOR_APP_BIN"
FAILED=0
BLOCK_FAILED=0

run() {   # run <root> <start folder> <script>
  ARBOR_HEADLESS=1 ARBOR_TEST_TRASH="$1/trash" ARBOR_JOURNAL_DIR="$1/journal" ARBOR_HISTORY_FILE="$1/history.json" \
    ARBOR_SCRIPT="$3" perl -e 'alarm shift; exec @ARGV' 90 "$APP" "$2" >/dev/null 2>&1
}

fail() { echo "FAIL  $1"; FAILED=1; BLOCK_FAILED=1; }

check() {   # check <name> <file> <expected line>
  if [ -f "$2" ] && grep -qxF -- "$3" "$2"; then echo "pass  $1"; else
    fail "$1: expected “$3”"; [ -f "$2" ] && grep -E "^(rows|selected|location)" "$2" | sed 's/^/        /'; fi
}

# discard <block> <folder>: remove a block's folder, or keep it in $ARBOR_KEEP_FAILED after a failure.
discard() {
  if [ "$BLOCK_FAILED" = 1 ] && [ -n "${ARBOR_KEEP_FAILED:-}" ]; then
    mkdir -p "$ARBOR_KEEP_FAILED"; mv "$2" "$ARBOR_KEEP_FAILED/$1"; echo "kept  $1 → $ARBOR_KEEP_FAILED/$1"
  else
    rm -rf "$2"
  fi
  BLOCK_FAILED=0
}

# QA-CORE-3: after cut and paste, Paste is disabled (the clipboard no longer names moved files).
R=$(mktemp -d); mkdir -p "$R/trash" "$R/A" "$R/B"; echo 1 > "$R/A/one.txt"
run "$R" "$R/A" "wait:1;select:one.txt;click:edit.cut;event;location:$R/B;wait:1;click:edit.paste;event;wait:2;menu:background:$R/menu.txt;quit"
check "cut and paste empties the clipboard" "$R/menu.txt" "Paste [⌘V] (disabled)"
[ -f "$R/B/one.txt" ] && [ ! -e "$R/A/one.txt" ] || fail "cut and paste moved the file"
discard qa-core-3 "$R"

# QA-CORE-4: one of several same-named search results stays the only selected item.
R=$(mktemp -d); mkdir -p "$R/trash" "$R/P/one" "$R/P/two" "$R/P/three"
for d in one two three; do echo "$d" > "$R/P/$d/readme.txt"; done
run "$R" "$R/P" "wait:1;search:readme;event;enter;wait:3;log:$R/a.txt;newtab;wait:1;tab:1;wait:1.5;log:$R/b.txt;view:largeIcons;wait:1;refresh;wait:2;log:$R/c.txt;click:edit.invertSelection;wait:0.5;log:$R/d.txt;quit"
check "Return in search selects one result" "$R/a.txt" "selected: readme.txt"
check "tab switch keeps one same-named item" "$R/b.txt" "selected: readme.txt"
check "icon view refresh keeps one same-named item" "$R/c.txt" "selected: readme.txt"
check "invert selection with same names" "$R/d.txt" "selected: readme.txt | readme.txt"
discard qa-core-4 "$R"

# QA-CORE-2: a path typed in other letter case opens the folder as spelled on disk.
R=$(mktemp -d); mkdir -p "$R/trash" "$R/Docs/Sub"
LOWER=$(printf '%s' "$R/docs/sub")
if [ -e "$LOWER" ]; then   # case-insensitive volume
  run "$R" "$R/Docs" "wait:1;address:$LOWER;wait:1.5;log:$R/a.txt;quit"
  check "typed path uses the on-disk spelling" "$R/a.txt" "location: folder:$R/Docs/Sub  view: details"
else
  echo "skip  typed path uses the on-disk spelling (the temporary folder is on a case-sensitive volume)"
fi
discard qa-core-2 "$R"

exit $FAILED
