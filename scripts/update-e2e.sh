#!/usr/bin/env bash
# End-to-end check of in-app updates (FE-259, docs/features/updates.md) on this Mac, away from /Applications:
#
#   1. An older and a newer ad-hoc signed Arbor (hardened runtime, like a release) and a throwaway EdDSA key.
#      scripts/make-update.sh makes the newer one's zip and signed feed, served from 127.0.0.1.
#      The older one, pointed at that feed by the debug-only ARBOR_UPDATE_FEED, runs its scheduled check
#      (due at once on a first launch), shows the Update button and no window, opens Sparkle's window from
#      the button, installs and relaunches.
#   2. A zip signed with another key, in a feed signed with the right one, is refused and nothing changes.
#   3. A feed signed with another key is refused before anything is downloaded.
#
# Usage: scripts/build-app.sh debug && scripts/update-e2e.sh [1] [2] [3]   (no numbers = all three)
#   ARBOR_KEEP_E2E=<dir>   copy the logs, snapshots and feed there before the temporary folder goes
#
# It shows windows (Arbor and Sparkle's), so run it at the Mac and leave it alone for about a minute.
# The copies use their own bundle identifier, whose preferences and caches are removed at the end;
# keys, apps and the feed live in a temporary folder that is removed too. Needs python3 (the server).
# A refusal is read from Sparkle's own entries in the unified log, for these copies' processes only.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/codesign-app.sh

WANTED=" ${*:-1 2 3} "
want() { [[ "$WANTED" == *" $1 "* ]]; }
ID="io.github.arbor-files.Arbor.updatecheck"
SOURCE="build/Arbor.app"
[ -d "$SOURCE" ] || { echo "update-e2e.sh: $SOURCE not found; run scripts/build-app.sh debug first" >&2; exit 1; }
R="$(mktemp -d "${TMPDIR:-/tmp}/arbor-update-e2e.XXXXXX")"
R="$(cd "$R" && pwd -P)"
SERVER=""
FAILED=0
cleanup() {
  if [ -n "${ARBOR_KEEP_E2E:-}" ]; then
    mkdir -p "$ARBOR_KEEP_E2E"
    cp "$R"/*.txt "$R"/*.png "$R"/*.out "$R"/*.log "$R/www/appcast.xml" "$ARBOR_KEEP_E2E/" 2>/dev/null || true
  fi
  if [ -n "$SERVER" ]; then kill "$SERVER" 2>/dev/null || true; fi
  pkill -9 -f "$R/" 2>/dev/null || true
  defaults delete "$ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/Saved Application State/$ID.savedState"
  rm -rf "$R"
}
trap cleanup EXIT

pass() { echo "pass  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
expect() {   # expect <name> <file> <fixed text>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; return; fi
  fail "$1: expected “$3”"
  if [ -f "$2" ]; then sed 's/^/        /' "$2"; fi
}

# --- Throwaway keys, made here so no keychain is touched -----------------------------------------
cat > "$R/keygen.swift" <<'EOF'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
for name in good other; do
  swift "$R/keygen.swift" > "$R/$name.keys"
  sed -n 1p "$R/$name.keys" > "$R/$name.private"
  sed -n 2p "$R/$name.keys" > "$R/$name.public"
done

# --- Server ----------------------------------------------------------------------------------------
PORT=$((20000 + RANDOM % 20000))
mkdir -p "$R/www" "$R/F" "$R/trash"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$R/www" >"$R/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
BASE="http://127.0.0.1:$PORT"

# make_app <dest> <version> <build> <public key file>: a copy signed the way sign-and-notarize.sh signs releases.
VERSION="$(tr -d '[:space:]' < VERSION)"
make_app() {
  rm -rf "$1"; mkdir -p "$(dirname "$1")"
  ditto "$SOURCE" "$1"
  local plist="$1/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$ID" "$plist"
  plutil -replace CFBundleShortVersionString -string "$2" "$plist"
  plutil -replace CFBundleVersion -string "$3" "$plist"
  plutil -replace SUPublicEDKey -string "$(cat "$4")" "$plist"
  # A feed that goes nowhere, so the relaunched copy reaches no server.
  plutil -replace SUFeedURL -string "https://127.0.0.1:9/appcast.xml" "$plist"
  ARBOR_ENTITLEMENTS=Resources/Arbor-adhoc.entitlements arbor_codesign_app "$1" - --options runtime
}
# publish <app> <key file>: the zip and the feed in the server's folder.
publish() {
  rm -f "$R/www/"*
  scripts/make-update.sh --app "$1" --out "$R/www" "$BASE/Arbor-$VERSION.zip" < "$2" >/dev/null
}
# run_old <name> <script>: the older copy, with its files in the temporary folder, until it exits.
run_old() {
  ARBOR_UPDATE_FEED="$BASE/appcast.xml" ARBOR_TEST_TRASH="$R/trash" ARBOR_JOURNAL_DIR="$R/journal" \
    ARBOR_HISTORY_FILE="$R/history.json" ARBOR_STATE_DIR="$R/state" ARBOR_SCRIPT="$2" \
    perl -e 'alarm shift; exec @ARGV' 120 "$R/Apps/Arbor.app/Contents/MacOS/Arbor" "$R/F" >"$R/$1.out" 2>&1 || true
}
installed_build() { plutil -extract CFBundleVersion raw "$R/Apps/Arbor.app/Contents/Info.plist"; }
defaults delete "$ID" >/dev/null 2>&1 || true   # a first launch each time
defaults write "$ID" openTo thismac   # if the relaunched copy shows a page, not Home's folders

untouched() { if [ "$(installed_build)" = 100 ]; then pass "$1: the older app is untouched"; else fail "$1: the older app is untouched"; fi; }
# refused <name> <script> <text>: Sparkle's error alert is modal and holds the script, so watch Sparkle's own
# log (the unified log, these copies' processes only) for its reason, then stop the app.
refused() {
  local predicate="subsystem == \"org.sparkle-project.Sparkle\" AND processImagePath CONTAINS \"$(basename "$R")\""
  /usr/bin/log stream --style compact --predicate "$predicate" > "$R/$1-sparkle.log" 2>&1 &
  local stream=$!
  run_old "$1" "$2" &
  local app=$! found=0
  for _ in $(seq 60); do
    sleep 1
    if grep -qF -- "$3" "$R/$1-sparkle.log"; then found=1; break; fi
  done
  pkill -9 -f "$R/Apps/Arbor.app/Contents/MacOS/Arbor" 2>/dev/null || true
  kill "$stream" 2>/dev/null || true
  wait "$app" "$stream" 2>/dev/null || true
  if [ "$found" = 1 ]; then pass "$1: refused (Sparkle: “$3”)"; else fail "$1: refused (no “$3” in Sparkle's log)"; fi
}

# --- 1. Install and relaunch ------------------------------------------------------------------------
if want 1; then
  make_app "$R/Apps/Arbor.app" 0.0.1 100 "$R/good.public"
  make_app "$R/newer/Arbor.app" "$VERSION" 200 "$R/good.public"
  publish "$R/newer/Arbor.app" "$R/good.private"
  if grep -q "sparkle-signatures" "$R/www/appcast.xml"; then pass "the feed carries its signature"; else fail "the feed carries its signature"; fi
  # A first launch has never checked, so the scheduled check runs a moment after the updater starts.
  S="wait:8;log:$R/1-found.txt;snapshot:$R/1-found.png;menu:main:Arbor:$R/1-menu.txt"
  S+=";folderoptions:general;wait:1;log:$R/1-settings.txt;fosnapshot:$R/1-settings.png"
  S+=";updatepill;wait:3;log:$R/1-seen.txt;updatepress:Install Update;wait:10;updatepress:Install and Relaunch;wait:60"
  run_old 1 "$S" &
  OLD=$!
  for _ in $(seq 120); do
    if [ "$(installed_build 2>/dev/null)" = 200 ] && ! kill -0 "$OLD" 2>/dev/null \
       && pgrep -f "$R/Apps/Arbor.app/Contents/MacOS/Arbor" >/dev/null; then break; fi
    sleep 1
  done
  expect "the updater runs for the test feed" "$R/1-found.txt" "updates: updater=on"
  expect "the scheduled check shows the Update button" "$R/1-found.txt" "update button: shown title=Update tooltip=Arbor $VERSION is available."
  expect "and no window" "$R/1-found.txt" "windows=0"
  expect "Check for Updates… is in the Arbor menu" "$R/1-menu.txt" "Check for Updates…"
  expect "the Settings switch is there and on" "$R/1-settings.txt" "settings=on"
  expect "pressing the button opens Sparkle's window" "$R/1-seen.txt" "windows=1"
  expect "and the button goes" "$R/1-seen.txt" "update button: none"
  if [ "$(installed_build 2>/dev/null)" = 200 ]; then pass "the newer build replaced the older one in place"; else fail "the newer build replaced the older one in place"; fi
  if pgrep -f "$R/Apps/Arbor.app/Contents/MacOS/Arbor" >/dev/null; then pass "and it relaunched"; else fail "and it relaunched"; fi
  if codesign --verify --deep --strict "$R/Apps/Arbor.app" 2>/dev/null; then pass "the installed app's signature verifies"; else fail "the installed app's signature verifies"; fi
  pkill -9 -f "$R/Apps/Arbor.app/Contents/MacOS/Arbor" 2>/dev/null || true
  sleep 1
fi

# --- 2. A zip signed with another key, in a feed signed with the right one ------------------------------
if want 2; then
  make_app "$R/Apps/Arbor.app" 0.0.1 100 "$R/good.public"
  make_app "$R/newer/Arbor.app" "$VERSION" 200 "$R/other.public"
  publish "$R/newer/Arbor.app" "$R/other.private"
  SIGN_UPDATE="$(find .build/artifacts -type f -perm -u+x -path '*/Sparkle/bin/sign_update' | head -n 1)"
  "$SIGN_UPDATE" --ed-key-file - "$R/www/appcast.xml" < "$R/good.private" >/dev/null
  "$SIGN_UPDATE" --verify --ed-key-file - "$R/www/appcast.xml" < "$R/good.private" >/dev/null
  : > "$R/server.log"
  refused "archive" "wait:4;updatecheck;wait:5;log:$R/2-offered.txt;updatepress:Install Update;wait:60" \
    "signature validation before unarchiving failed"
  expect "archive: the update was offered" "$R/2-offered.txt" "updates: updater=on"
  if grep -q "GET /Arbor-$VERSION.zip" "$R/server.log"; then pass "archive: and downloaded"; else fail "archive: and downloaded"; fi
  untouched "archive"
fi

# --- 3. A feed signed with another key ----------------------------------------------------------------
if want 3; then
  make_app "$R/Apps/Arbor.app" 0.0.1 100 "$R/good.public"
  make_app "$R/newer/Arbor.app" "$VERSION" 200 "$R/other.public"
  publish "$R/newer/Arbor.app" "$R/other.private"
  : > "$R/server.log"
  refused "feed" "wait:4;updatecheck;wait:60" "Data of the appcast being checked is different than data that has been signed"
  if grep -q "GET /Arbor-" "$R/server.log"; then fail "feed: nothing is downloaded"; else pass "feed: nothing is downloaded"; fi
  untouched "feed"
fi

exit $FAILED
