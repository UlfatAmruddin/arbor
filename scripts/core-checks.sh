#!/usr/bin/env bash
# Headless regression checks for core browsing and file operations (docs/features/qa-core.md).
# Usage: scripts/build-app.sh debug && scripts/core-checks.sh
set -uo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Arbor.app/Contents/MacOS/Arbor"
[ -x "$APP" ] || { echo "Build first: scripts/build-app.sh debug"; exit 2; }
FAILED=0

run() {   # run <root> <start folder> <script>
  ARBOR_HEADLESS=1 ARBOR_TEST_TRASH="$1/trash" ARBOR_SCRIPT="$3" \
    perl -e 'alarm shift; exec @ARGV' 90 "$APP" "$2" >/dev/null 2>&1
}

check() {   # check <name> <file> <expected line>
  if grep -qxF -- "$3" "$2"; then echo "pass  $1"; else
    echo "FAIL  $1: expected “$3”"; grep -E "^(rows|selected|location)" "$2" | sed 's/^/        /'; FAILED=1; fi
}

# QA-CORE-3: after cut and paste, Paste is disabled (the clipboard no longer names moved files).
R=$(mktemp -d); mkdir -p "$R/trash" "$R/A" "$R/B"; echo 1 > "$R/A/one.txt"
run "$R" "$R/A" "wait:1;select:one.txt;click:edit.cut;event;location:$R/B;wait:1;click:edit.paste;event;wait:2;menu:background:$R/menu.txt;quit"
check "cut and paste empties the clipboard" "$R/menu.txt" "Paste [⌘V] (disabled)"
[ -f "$R/B/one.txt" ] && [ ! -e "$R/A/one.txt" ] || { echo "FAIL  cut and paste moved the file"; FAILED=1; }
rm -rf "$R"

# QA-CORE-4: one of several same-named search results stays the only selected item.
R=$(mktemp -d); mkdir -p "$R/trash" "$R/P/one" "$R/P/two" "$R/P/three"
for d in one two three; do echo "$d" > "$R/P/$d/readme.txt"; done
run "$R" "$R/P" "wait:1;search:readme;event;enter;wait:3;log:$R/a.txt;newtab;wait:1;tab:1;wait:1.5;log:$R/b.txt;view:largeIcons;wait:1;refresh;wait:2;log:$R/c.txt;click:edit.invertSelection;wait:0.5;log:$R/d.txt;quit"
check "Return in search selects one result" "$R/a.txt" "selected: readme.txt"
check "tab switch keeps one same-named item" "$R/b.txt" "selected: readme.txt"
check "icon view refresh keeps one same-named item" "$R/c.txt" "selected: readme.txt"
check "invert selection with same names" "$R/d.txt" "selected: readme.txt | readme.txt"
rm -rf "$R"

# QA-CORE-2: a path typed in other letter case opens the folder as spelled on disk.
R=$(mktemp -d); mkdir -p "$R/trash" "$R/Docs/Sub"
LOWER=$(printf '%s' "$R/docs/sub")
run "$R" "$R/Docs" "wait:1;address:$LOWER;wait:1.5;log:$R/a.txt;quit"
if [ -e "$LOWER" ]; then   # case-insensitive volume
  check "typed path uses the on-disk spelling" "$R/a.txt" "location: folder:$R/Docs/Sub  view: details"
fi
rm -rf "$R"

exit $FAILED
