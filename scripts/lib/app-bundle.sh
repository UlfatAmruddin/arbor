# Shared by the scripted suites that drive the built app, build/<name>.app (scripts/lib/product.sh):
# behavior-checks.sh, core-checks.sh, acceptance.sh, bench.sh. Source it from the repository root:
#
#   . scripts/lib/app-bundle.sh
#   better_explorer_prepare_app <suite name> [debug|release]
#
# 1. Stale-bundle guard. The suites test the built app, not the sources, so a bundle older than the
#    sources gives failures that have nothing to do with the code. A suite refuses (exit 2) when any
#    file under Sources/ or Resources/, or Package.swift / Package.resolved, is newer than
#    the app's executable, build/<name>.app/Contents/MacOS/BetterExplorer.
#      BETTER_EXPLORER_REBUILD=1       rebuild the bundle instead of refusing (debug, or what the suite asks for)
#      BETTER_EXPLORER_ALLOW_STALE=1   run the old bundle anyway (prints a warning)
#
# 2. One suite at a time. Two suites running at once compete for the CPU (their timed waits and the
#    benchmarks go wrong) and can replace the built app under each other (bench.sh and BETTER_EXPLORER_REBUILD
#    rebuild it). Each suite holds a lock directory for its whole run; a second suite waits for it.
#      BETTER_EXPLORER_LOCK_WAIT=<s>   how long to wait for another suite (default 3600; 0 = exit at once)
#      BETTER_EXPLORER_LOCK_DIR=<dir>  the lock directory (default $TMPDIR/better-explorer-app-suites.lock)
#    A lock left by a suite that no longer runs (crash, kill -9) is taken over.
#
# 3. One temporary folder per suite run. While a suite holds the lock, TMPDIR points into
#    $TMPDIR/better-explorer-suite.<pid>.XXXXXX, so every fixture (better_explorer_mktemp_dir), the app's own temporary files and
#    the build tools' scratch land there. It is removed when the suite exits, also after Ctrl-C or a
#    failure; folders of suites that were killed are removed when the next suite starts.
#      BETTER_EXPLORER_KEEP_TMP=1      keep it (its path is printed); ACCEPT_KEEP=1 keeps it too
#
# 4. Smoke launch. Before the first check, the app is started headless once; when it can't start at
#    all here (no window server session, a broken bundle) the suite stops with that reason instead of
#    reporting every check as failed.
#
# 5. Private copy. The suites run a copy of the bundle in their temporary folder, with its own identifier and no
#    Dock icon. macOS treats copies started from one bundle as the same app, so a Dock icon or double-click on
#    the built app would otherwise land on a test window.

BETTER_EXPLORER_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$BETTER_EXPLORER_REPO/scripts/lib/product.sh"
BETTER_EXPLORER_APP_BIN="${BETTER_EXPLORER_APP_BIN:-$BETTER_EXPLORER_REPO/$PRODUCT_APP/Contents/MacOS/BetterExplorer}"
BETTER_EXPLORER_LOCK_DIR="${BETTER_EXPLORER_LOCK_DIR:-${TMPDIR:-/tmp}}"
case "$BETTER_EXPLORER_LOCK_DIR" in *.lock) ;; *) BETTER_EXPLORER_LOCK_DIR="${BETTER_EXPLORER_LOCK_DIR%/}/better-explorer-app-suites.lock" ;; esac
BETTER_EXPLORER_SUITE="${BETTER_EXPLORER_SUITE:-$(basename "$0")}"
BETTER_EXPLORER_LOCK_HELD=0
BETTER_EXPLORER_REAL_TMPDIR="${TMPDIR:-/tmp}"; BETTER_EXPLORER_REAL_TMPDIR="${BETTER_EXPLORER_REAL_TMPDIR%/}"
BETTER_EXPLORER_SUITE_TMP=""

better_explorer_say() { echo "$BETTER_EXPLORER_SUITE: $*" >&2; }

# Prints why the built app is stale and returns 0, or returns 1 when it is current.
better_explorer_stale_reason() {
  if [ ! -x "$BETTER_EXPLORER_APP_BIN" ]; then
    echo "there is no app at ${BETTER_EXPLORER_APP_BIN#"$BETTER_EXPLORER_REPO"/}"
    return 0
  fi
  local newer
  newer="$(cd "$BETTER_EXPLORER_REPO" && find Sources Resources Package.swift Package.resolved -type f ! -name .DS_Store \
             -newer "$BETTER_EXPLORER_APP_BIN" 2>/dev/null | head -n 5 || true)"
  [ -n "$newer" ] || return 1
  echo "the app is older than the sources; newer than ${BETTER_EXPLORER_APP_BIN#"$BETTER_EXPLORER_REPO"/}:"
  printf '%s\n' "$newer" | sed 's/^/    /'
  return 0
}

# Refuses (exit 2) when the bundle is stale, unless BETTER_EXPLORER_ALLOW_STALE=1.
better_explorer_require_fresh_app() {
  local reason
  reason="$(better_explorer_stale_reason)" || return 0
  if [ "${BETTER_EXPLORER_ALLOW_STALE:-0}" = 1 ]; then
    better_explorer_say "warning: $reason"
    better_explorer_say "warning: running it anyway (BETTER_EXPLORER_ALLOW_STALE=1)"
    return 0
  fi
  better_explorer_say "$reason"
  better_explorer_say "Rebuild first (scripts/build-app.sh ${BETTER_EXPLORER_BUILD_CONFIG:-debug}), or set BETTER_EXPLORER_REBUILD=1 to rebuild automatically."
  exit 2
}

# The process holding the lock, if it still runs this suite (guards against a reused pid).
better_explorer_lock_holder_alive() {   # <pid> <suite>
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  ps -p "$1" -o command= 2>/dev/null | grep -qF -- "$2"
}

better_explorer_take_suite_lock() {
  local limit="${BETTER_EXPLORER_LOCK_WAIT:-3600}" waited=0 pid suite started announced=0
  mkdir -p "$(dirname "$BETTER_EXPLORER_LOCK_DIR")"
  until mkdir "$BETTER_EXPLORER_LOCK_DIR" 2>/dev/null; do
    pid="$(cat "$BETTER_EXPLORER_LOCK_DIR/pid" 2>/dev/null || true)"
    suite="$(cat "$BETTER_EXPLORER_LOCK_DIR/suite" 2>/dev/null || true)"
    started="$(cat "$BETTER_EXPLORER_LOCK_DIR/started" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
      # Just created by another suite (it writes its pid next), or left empty by a crash right after mkdir.
      if [ -n "$(find "$BETTER_EXPLORER_LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        better_explorer_say "removing an empty lock left behind: $BETTER_EXPLORER_LOCK_DIR"
        rm -rf "$BETTER_EXPLORER_LOCK_DIR"; continue
      fi
    elif ! better_explorer_lock_holder_alive "$pid" "$suite"; then
      # Re-read right before removing it, so a lock another waiter has just taken over is left alone.
      if [ "$(cat "$BETTER_EXPLORER_LOCK_DIR/pid" 2>/dev/null || true)" = "$pid" ]; then
        better_explorer_say "taking over a stale lock ($suite, process $pid, has ended)"
        rm -rf "$BETTER_EXPLORER_LOCK_DIR"
      fi
      continue
    fi
    if [ "$limit" -le 0 ] || [ "$waited" -ge "$limit" ]; then
      better_explorer_say "another suite is running: ${suite:-?} (process ${pid:-?}, started ${started:-?}); lock $BETTER_EXPLORER_LOCK_DIR"
      better_explorer_say "two suites at once give false failures. Wait for it to finish, or raise BETTER_EXPLORER_LOCK_WAIT (now ${limit}s)."
      exit 2
    fi
    if [ "$announced" = 0 ] || [ $((waited % 60)) -eq 0 ]; then
      better_explorer_say "waiting for ${suite:-another suite} (process ${pid:-?}, started ${started:-?}) to finish…"
      announced=1
    fi
    sleep 5; waited=$((waited + 5))
  done
  echo $$ > "$BETTER_EXPLORER_LOCK_DIR/pid"
  echo "$BETTER_EXPLORER_SUITE" > "$BETTER_EXPLORER_LOCK_DIR/suite"
  date "+%Y-%m-%d %H:%M:%S" > "$BETTER_EXPLORER_LOCK_DIR/started"
  BETTER_EXPLORER_LOCK_HELD=1
  better_explorer_enter_suite_temp
  # Interrupted, terminated or writing into a closed pipe (`scripts/acceptance.sh | head`): release, then exit.
  trap 'better_explorer_release_suite_lock' EXIT
  trap 'better_explorer_release_suite_lock; exit 130' INT
  trap 'better_explorer_release_suite_lock; exit 143' TERM
  trap 'better_explorer_release_suite_lock; exit 129' HUP
  trap 'better_explorer_release_suite_lock; exit 141' PIPE
}

# A fresh fixture folder inside the suite's temporary folder. (A bare `mktemp -d` on macOS ignores
# TMPDIR and would put it in the system temporary folder, where an interrupted run leaves it.)
better_explorer_mktemp_dir() {
  mktemp -d "${TMPDIR%/}/better-explorer-check.XXXXXX"
}

# Deletes a folder even when the app left locked or read-only items in it.
better_explorer_remove_tree() {
  chflags -R nouchg "$1" 2>/dev/null || true
  chmod -R -N "$1" 2>/dev/null || true   # "deny delete" access rules
  chmod -R u+rwx "$1" 2>/dev/null || true
  rm -rf "$1" 2>/dev/null || true
}

# Removes the temporary folders of suites that no longer run (killed, crashed, closed terminal).
better_explorer_sweep_suite_temp() {
  local d pid
  for d in "$BETTER_EXPLORER_REAL_TMPDIR"/better-explorer-suite.*; do
    [ -d "$d" ] || continue
    pid="${d##*/better-explorer-suite.}"; pid="${pid%%.*}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    kill -0 "$pid" 2>/dev/null && continue
    better_explorer_remove_tree "$d"
  done
}

better_explorer_enter_suite_temp() {
  [ -z "$BETTER_EXPLORER_SUITE_TMP" ] || return 0
  better_explorer_sweep_suite_temp
  BETTER_EXPLORER_SUITE_TMP="$(mktemp -d "$BETTER_EXPLORER_REAL_TMPDIR/better-explorer-suite.$$.XXXXXX")" || { BETTER_EXPLORER_SUITE_TMP=""; return 0; }
  export TMPDIR="$BETTER_EXPLORER_SUITE_TMP/"
}

better_explorer_leave_suite_temp() {
  [ -n "$BETTER_EXPLORER_SUITE_TMP" ] || return 0
  if [ "${BETTER_EXPLORER_KEEP_TMP:-0}" = 1 ] || [ "${ACCEPT_KEEP:-0}" = 1 ]; then
    better_explorer_say "kept the temporary files in $BETTER_EXPLORER_SUITE_TMP"
  else
    better_explorer_remove_tree "$BETTER_EXPLORER_SUITE_TMP"
  fi
  export TMPDIR="$BETTER_EXPLORER_REAL_TMPDIR/"
  BETTER_EXPLORER_SUITE_TMP=""
}

# Releases the lock if this process holds it. Scripts that set their own EXIT trap must call it there.
better_explorer_release_suite_lock() {
  better_explorer_leave_suite_temp
  [ "$BETTER_EXPLORER_LOCK_HELD" = 1 ] || return 0
  # `read`, not $(cat …): after a write to a closed pipe, bash 3.2 flushes the unwritten text into the
  # next command substitution, which would then never match the pid.
  local owner=""
  read -r owner < "$BETTER_EXPLORER_LOCK_DIR/pid" 2>/dev/null || true
  if [ "$owner" = "$$" ]; then rm -rf "$BETTER_EXPLORER_LOCK_DIR"; fi
  BETTER_EXPLORER_LOCK_HELD=0
}

# Points BETTER_EXPLORER_APP_BIN at a private copy of the bundle. Needs the suite's temporary folder, so call it with the lock held.
better_explorer_use_private_app() {
  [ -n "$BETTER_EXPLORER_SUITE_TMP" ] || { better_explorer_say "no temporary folder for a private copy of the app"; exit 2; }
  case "$BETTER_EXPLORER_APP_BIN" in "$BETTER_EXPLORER_SUITE_TMP"/*) return 0 ;; esac
  local source="${BETTER_EXPLORER_APP_BIN%/Contents/MacOS/BetterExplorer}" private="$BETTER_EXPLORER_SUITE_TMP/app/$PRODUCT_NAME.app"
  mkdir -p "$BETTER_EXPLORER_SUITE_TMP/app"
  if ! ditto "$source" "$private" \
     || ! plutil -replace CFBundleIdentifier -string io.github.arbor-files.Arbor.checks "$private/Contents/Info.plist" \
     || ! plutil -replace LSUIElement -bool YES "$private/Contents/Info.plist" \
     || ! codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$private" 2>/dev/null; then
    better_explorer_say "couldn't make a private copy of the app from $source"
    exit 2
  fi
  BETTER_EXPLORER_APP_BIN="$private/Contents/MacOS/BetterExplorer"
}

# Starts the app headless once and checks that it lists a folder.
better_explorer_smoke_launch() {
  local tmp status=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/better-explorer-smoke.XXXXXX")"
  mkdir -p "$tmp/folder"; echo smoke > "$tmp/folder/smoke.txt"
  BETTER_EXPLORER_HEADLESS=1 BETTER_EXPLORER_TEST_TRASH="$tmp/trash" BETTER_EXPLORER_JOURNAL_DIR="$tmp/journal" BETTER_EXPLORER_HISTORY_FILE="$tmp/history.json" \
    BETTER_EXPLORER_SCRIPT="wait:1;log:$tmp/log.txt;quit" perl -e 'alarm shift; exec @ARGV' 60 "$BETTER_EXPLORER_APP_BIN" "$tmp/folder" \
    > "$tmp/output.txt" 2>&1 || status=$?
  if ! grep -qx "rows: smoke.txt" "$tmp/log.txt" 2>/dev/null; then
    better_explorer_say "the app didn't start headless here (exit status $status), so no check can run."
    better_explorer_say "It needs a logged-in macOS session with a window server. Last output:"
    tail -n 15 "$tmp/output.txt" | sed 's/^/    /' >&2
    rm -rf "$tmp"
    exit 2
  fi
  rm -rf "$tmp"
}

# Everything a suite does before its first check: stale guard, lock, optional rebuild, smoke launch.
better_explorer_prepare_app() {   # <suite name> [debug|release]
  BETTER_EXPLORER_SUITE="$1"; BETTER_EXPLORER_BUILD_CONFIG="${2:-debug}"
  # Refuse a stale bundle before waiting for the lock; check again once it is held (it may have changed).
  [ "${BETTER_EXPLORER_REBUILD:-0}" = 1 ] || better_explorer_require_fresh_app
  better_explorer_take_suite_lock
  if [ "${BETTER_EXPLORER_REBUILD:-0}" = 1 ] && better_explorer_stale_reason > /dev/null; then
    better_explorer_say "rebuilding: $(better_explorer_stale_reason | head -n 1)"
    (cd "$BETTER_EXPLORER_REPO" && scripts/build-app.sh "$BETTER_EXPLORER_BUILD_CONFIG") >&2 || { better_explorer_say "the build failed"; exit 2; }
  fi
  better_explorer_require_fresh_app
  better_explorer_use_private_app
  better_explorer_smoke_launch
}
