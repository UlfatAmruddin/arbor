#!/usr/bin/env bash
# Lists every extension point with its contributions in run order, the per-command overrides, the
# script steps and the feature registration order, by running the app headless with the `extensions`
# script step (docs/EXTENSION-POINTS.md, DEC-024). Fails when registration reported an error.
#
# Usage: scripts/list-extension-points.sh [--markdown FILE]
#
#   (no option)       print the listing
#   --markdown FILE   write the tables of docs/EXTENSION-POINTS.md's generated section to FILE
#
# Uses build/Arbor.app; build it first with scripts/build-app.sh debug.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Arbor.app/Contents/MacOS/Arbor
if [ ! -x "$APP" ]; then
  echo "list-extension-points.sh: $APP not found; run scripts/build-app.sh debug first" >&2
  exit 1
fi
# A bundle older than the sources would list stale registrations (scripts/lib/app-bundle.sh).
. scripts/lib/app-bundle.sh
arbor_require_fresh_app

MODE=text
OUT=""
case "${1:-}" in
  --markdown) MODE=markdown; OUT="${2:?--markdown needs a file}" ;;
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "list-extension-points.sh: unknown argument '$1'" >&2; exit 2 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/fixture"
STEP="extensions:$WORK/listing.txt"
[ "$MODE" = markdown ] && STEP="extensions:md:$WORK/listing.md;extensions:$WORK/listing.txt"

ARBOR_HEADLESS=1 ARBOR_TEST_TRASH="$WORK/trash" ARBOR_SCRIPT="wait:1;$STEP;quit" "$APP" "$WORK/fixture" >"$WORK/app.log" 2>&1 || {
  echo "list-extension-points.sh: the app failed to start:" >&2
  tail -20 "$WORK/app.log" >&2
  exit 1
}

if [ ! -s "$WORK/listing.txt" ]; then
  echo "list-extension-points.sh: no listing was written" >&2
  exit 1
fi
if [ "$MODE" = markdown ]; then
  cp "$WORK/listing.md" "$OUT"
else
  cat "$WORK/listing.txt"
fi
if ! grep -q '^errors: none$' "$WORK/listing.txt"; then
  grep '^errors: ' "$WORK/listing.txt" >&2
  exit 1
fi
