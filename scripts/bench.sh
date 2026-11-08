#!/usr/bin/env bash
# Memory and responsiveness benchmarks (spec §15.4, FE-252). See docs/PERFORMANCE.md.
#
# Usage: scripts/bench.sh [--check] [--repeats N] [--quick] [--app PATH] [--skip-build]
#                         [--workloads "idle browse tabs large media search copy"] [--out DIR] [--margin 0.25]
#
#   --check       compare the medians with scripts/bench-budgets.txt; exit 1 if any exceeds its budget
#                 by more than the margin (default 25 %, or BENCH_MARGIN)
#   --repeats N   launches per workload (default 3; the first one is reported separately as "first")
#   --quick       smaller fixtures (10,000-entry large folder, fewer photos); budgets still apply but
#                 are looser than necessary
#   --app PATH    benchmark an existing Arbor.app instead of building build/Arbor.app (release)
#   --skip-build  benchmark build/Arbor.app as it is (refused when older than the sources)
#
#   BENCH_TOLERANCE=F         multiply the time budgets (ms, stalls, CPU) by F (default 1)
#   BENCH_MEMORY_TOLERANCE=F  multiply the memory budgets (MB) by F (default 1); counts are never scaled
#   BENCH_SAMPLE_IDLE=1       the idle run logs CPU per thread and stacks of busy threads (<out>/idle-N.log)
#
# Every run is headless (ARBOR_HEADLESS=1), uses fixtures generated into a fresh mktemp -d folder,
# and never touches user files. Results: <out>/results.txt (metric median first min max) and
# <out>/environment.txt; raw per-run logs next to them. Lock and stale guard: scripts/lib/app-bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
. scripts/lib/app-bundle.sh
TOLERANCE="${BENCH_TOLERANCE:-1}"; MEMORY_TOLERANCE="${BENCH_MEMORY_TOLERANCE:-1}"

CHECK=0; REPEATS=3; QUICK=""; APP=""; SKIP_BUILD=0; OUT=""; MARGIN="${BENCH_MARGIN:-0.25}"
WORKLOADS="idle browse tabs large media search copy"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --repeats) REPEATS="$2"; shift ;;
    --quick) QUICK="--quick" ;;
    --app) APP="$2"; shift ;;
    --skip-build) SKIP_BUILD=1 ;;
    --workloads) WORKLOADS="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --margin) MARGIN="$2"; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

for f in "$TOLERANCE" "$MEMORY_TOLERANCE"; do
  [[ "$f" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v f="$f" 'BEGIN { exit !(f >= 1) }' || { echo "bench.sh: tolerances must be numbers ≥ 1 (got $f)" >&2; exit 2; }
done

# The lock is held for the whole run, the build included: building replaces build/Arbor.app, which
# another suite may be testing.
CONFIGURATION="given app bundle"
if [ -z "$APP" ]; then
  APP="$REPO/build/Arbor.app"
  CONFIGURATION="build/Arbor.app as found"
  if [ "$SKIP_BUILD" = 0 ]; then
    arbor_take_suite_lock
    scripts/build-app.sh release >/dev/null; CONFIGURATION="release (scripts/build-app.sh release)"
  else
    arbor_prepare_app bench.sh release
  fi
else
  arbor_take_suite_lock
fi
BIN="$APP/Contents/MacOS/Arbor"
[ -x "$BIN" ] || { echo "no app at $APP" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/arbor-bench.XXXXXX")"
FX="$ROOT/fx"
[ -n "$OUT" ] || OUT="$REPO/build/bench/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
trap 'rm -rf "$ROOT"; arbor_release_suite_lock' EXIT

echo "Fixtures in $ROOT"
swift scripts/bench-fixtures.swift "$FX" $QUICK

{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit: $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$REPO" diff --quiet 2>/dev/null || echo '+changes')"
  echo "app: $APP"
  echo "configuration: $CONFIGURATION"
  echo "machine: $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))"
  echo "os: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "fixtures: $(cat "$FX/FIXTURE" | tr '\n' ' ')"
  echo "repeats: $REPEATS (first launch reported separately; disk cache is warm: fixtures were just written)"
  echo "memory metric: phys_footprint (task_info TASK_VM_INFO), sampled in-process"
  echo "stall threshold: 50 ms main run-loop pass"
  echo "memory pressure at start: $(memory_pressure 2>/dev/null | tail -1 || echo n/a)"
  echo "budget tolerance: time ×$TOLERANCE, memory ×$MEMORY_TOLERANCE, margin $MARGIN"
} > "$OUT/environment.txt"
cat "$OUT/environment.txt"

# Builds the step list for one workload. $1 = workload, $2 = output log.
script_for() {
  local w="$1" o="$2" s=""
  case "$w" in
    idle)
      s="phase:idle;waitload;wait:1;launchlog:$o;idle:idle:$o:5;memlog:idle:$o;stalls:idle:$o" ;;
    browse)
      s="phase:browse;waitload;memlog:start:$o"
      for r in 1 2 3 4 5; do
        for f in 01 02 03 04 05 06 07 08 09 10; do s="$s;nav:nav:$o:$FX/browse/f$f"; done
        [ $r = 1 ] && s="$s;wait:1;memlog:round1:$o"
      done
      s="$s;scroll:scroll:$o:20;wait:1;memlog:round5:$o;stalls:browse:$o" ;;
    tabs)
      s="phase:tabs;waitload;wait:1;memlog:base:$o"
      for c in 1 2 3; do
        for t in 01 02 03 04 05 06 07 08 09 10 01 02 03 04 05 06 07 08 09; do s="$s;newtabnav:tab:$o:$FX/browse/f$t"; done
        s="$s;wait:1;memlog:open$c:$o;closeothertabs;wait:2;memlog:closed$c:$o"
      done
      for c in 1 2 3; do
        for n in 1 2 3 4; do s="$s;newwindow:$FX/browse/f0$n;waitload"; done
        s="$s;wait:1;memlog:windows$c:$o;closewindow;closewindow;closewindow;closewindow;wait:2;memlog:wclosed$c:$o"
      done
      s="$s;stalls:tabs:$o" ;;
    large)
      s="phase:large;waitload;memlog:before:$o;nav:first:$o:$FX/big;memlog:big:$o"
      s="$s;timecmd:sort_size:$o:sort.size;timecmd:sort_date:$o:sort.dateModified;timecmd:sort_type:$o:sort.type;timecmd:sort_desc:$o:sort.descending;timecmd:sort_name:$o:sort.name;timecmd:sort_asc:$o:sort.ascending"
      s="$s;scroll:details:$o:150;stalls:large_details:$o"
      s="$s;view:largeIcons;wait:1;scroll:icons:$o:60;view:details;wait:1;stalls:large_icons:$o"
      s="$s;nav:away:$o:$FX/idle;wait:2;memlog:away:$o;nav:again:$o:$FX/big;memlog:again:$o"
      s="$s;nav:away2:$o:$FX/idle;wait:2;memlog:away2:$o;stalls:large:$o" ;;
    media)
      s="phase:media;waitload;memlog:before:$o;view:extraLargeIcons;thumbwait;memlog:thumbs:$o"
      s="$s;scroll:icons:$o:40;thumbwait;memlog:scrolled:$o;view:details;wait:1"
      s="$s;click:view.previewPane;wait:1;selectcycle:preview:$o:30:0.35;wait:1;memlog:preview:$o"
      s="$s;click:view.previewPane;wait:3;memlog:paneclosed:$o;nav:away:$o:$FX/idle;wait:2;memlog:away:$o;stalls:media:$o" ;;
    search)
      s="phase:search;waitload;memlog:before:$o;searchchurn:churn1:$o:100:report;wait:1;memlog:after1:$o"
      s="$s;nav:back:$o:$FX/search;searchchurn:churn2:$o:100:budget;wait:1;memlog:after2:$o"
      s="$s;nav:back2:$o:$FX/search;searchchurn:churn3:$o:100:invoice;wait:2;memlog:after3:$o;stalls:search:$o" ;;
    copy)
      s="phase:copy;waitload;memlog:before:$o;copy:small:$o:$FX/copy-small/tree|$3/small;wait:1;memlog:aftersmall:$o"
      s="$s;copy:large:$o:$FX/copy-large/large.bin|$3/large;wait:1;memlog:afterlarge:$o;stalls:copy:$o" ;;
  esac
  echo "$s;quit"
}

start_folder() {
  case "$1" in
    media) echo "$FX/media" ;;
    search) echo "$FX/search" ;;
    *) echo "$FX/idle" ;;
  esac
}

# Turns one run's log into "metric value" lines.
metrics_of() {
  local w="$1" log="$2"
  awk -v w="$w" '
    function emit(k, v) { print w "." k " " v }
    $1 == "mem" { for (i = 3; i <= NF; i++) { split($i, kv, "="); if (kv[1] ~ /_mb$|^tabs$|^listed_rows$/) emit($2 "." kv[1], kv[2]) } }
    $1 == "time" { split($3, kv, "="); if (kv[1] == "ms") { n[$2]++; t[$2, n[$2]] = kv[2] } }
    $1 == "launch" { split($2, kv, "="); emit("launch." kv[1], kv[2]) }
    $1 == "idle" { for (i = 3; i <= NF; i++) if ($i ~ /^(cpu_ms_per_s|main_wakeups_per_s)=/) { split($i, kv, "="); emit($2 "." kv[1], kv[2]) } }
    $1 == "scroll" || $1 == "copy" || $1 == "search" || $1 == "stalls" || $1 == "cycle" {
      for (i = 3; i <= NF; i++) { split($i, kv, "="); v = kv[2]; sub(/ms$/, "", v); if (v ~ /^-?[0-9.]+$/) emit($2 "." kv[1], v) } }
    END {
      for (label in n) {
        m = n[label]
        for (i = 1; i <= m; i++) a[i] = t[label, i] + 0
        for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (a[j] < a[i]) { x = a[i]; a[i] = a[j]; a[j] = x }
        emit(label ".ms", a[int((m + 1) / 2)])
        if (m > 1) { emit(label ".p95_ms", a[int(m * 0.95 + 0.999) > m ? m : int(m * 0.95 + 0.999)]); emit(label ".max_ms", a[m]) }
      }
    }' "$log"
}

ALL="$OUT/all-metrics.txt"; : > "$ALL"
for w in $WORKLOADS; do
  for r in $(seq 1 "$REPEATS"); do
    log="$OUT/$w-$r.log"; : > "$log"
    dest="$ROOT/dest-$w-$r"; mkdir -p "$dest/small" "$dest/large"
    script="$(script_for "$w" "$log" "$dest")"
    printf "%-7s run %d… " "$w" "$r"
    start=$(date +%s)
    # BENCH_SAMPLE_IDLE=1: the idle run also records, from inside the app, CPU per thread and the call
    # stacks of threads that ran (lines idlethread / idleprofile / idlestack in its log).
    profile=0; [ "${BENCH_SAMPLE_IDLE:-0}" = 1 ] && [ "$w" = idle ] && profile=1
    ARBOR_IDLE_PROFILE=$profile \
    ARBOR_HEADLESS=1 ARBOR_APPEARANCE=light ARBOR_TEST_TRASH="$ROOT/trash" ARBOR_STALL_LOG="$OUT/$w-$r.stalls" \
      ARBOR_SCRIPT="$script" "$BIN" "$(start_folder "$w")" >"$OUT/$w-$r.stdout" 2>&1 &
    pid=$!
    # Watchdog: stop a run that hangs (polls once a second; holds no pipe open).
    ( for _ in $(seq 900); do sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; done; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" || echo "(exit $?)"
    wait "$watchdog" 2>/dev/null || true
    rm -rf "$dest"
    echo "$(( $(date +%s) - start ))s"
    metrics_of "$w" "$log" | sed "s/\$/ $r/" >> "$ALL"
  done
done

# Summary: median over all runs, plus the first run (closest to a cold start) and the range.
RESULTS="$OUT/results.txt"
awk '
  { k = $1; n[k]++; v[k, n[k]] = $2 + 0; if ($3 == 1) first[k] = $2 }
  END {
    for (k in n) {
      m = n[k]; for (i = 1; i <= m; i++) a[i] = v[k, i]
      for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (a[j] < a[i]) { x = a[i]; a[i] = a[j]; a[j] = x }
      med = (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
      printf "%-44s %10.1f %10.1f %10.1f %10.1f\n", k, med, first[k], a[1], a[m]
    }
  }' "$ALL" | sort > "$RESULTS.tmp"
{ printf "%-44s %10s %10s %10s %10s\n" metric median first min max; cat "$RESULTS.tmp"; } > "$RESULTS"
rm -f "$RESULTS.tmp"
cat "$RESULTS"
echo "Results: $RESULTS"

[ "$CHECK" = 1 ] || exit 0

# Budgets: "metric max" lines; derived metrics are computed here from the medians.
BUDGETS="$REPO/scripts/bench-budgets.txt"
fail=0
while read -r metric limit _; do
  case "$metric" in ''|\#*) continue ;; esac
  value=$(awk -v k="$metric" '$1 == k { print $2 }' "$RESULTS")
  if [ -z "$value" ]; then
    case "$metric" in
      tabs.per_tab_mb) value=$(awk '$1=="tabs.open1.footprint_mb"{o=$2} $1=="tabs.base.footprint_mb"{b=$2} END{if(o!="")printf "%.2f",(o-b)/19}' "$RESULTS") ;;
      tabs.plateau_growth_mb) value=$(awk '$1=="tabs.closed3.footprint_mb"{c=$2} $1=="tabs.closed1.footprint_mb"{f=$2} END{if(c!="")printf "%.2f",c-f}' "$RESULTS") ;;
      tabs.window_plateau_growth_mb) value=$(awk '$1=="tabs.wclosed3.footprint_mb"{c=$2} $1=="tabs.wclosed1.footprint_mb"{f=$2} END{if(c!="")printf "%.2f",c-f}' "$RESULTS") ;;
      browse.retained_growth_mb) value=$(awk '$1=="browse.round5.footprint_mb"{c=$2} $1=="browse.round1.footprint_mb"{f=$2} END{if(c!="")printf "%.2f",c-f}' "$RESULTS") ;;
      search.retained_growth_mb) value=$(awk '$1=="search.after3.footprint_mb"{c=$2} $1=="search.after1.footprint_mb"{f=$2} END{if(c!="")printf "%.2f",c-f}' "$RESULTS") ;;
      large.retained_after_leaving_mb) value=$(awk '$1=="large.away2.footprint_mb"{c=$2} $1=="large.before.footprint_mb"{f=$2} END{if(c!="")printf "%.2f",c-f}' "$RESULTS") ;;
      media.retained_after_pane_mb) value=$(awk '$1=="media.paneclosed.footprint_mb"{c=$2} $1=="media.scrolled.footprint_mb"{f=$2} END{if(c!="")printf "%.2f",c-f}' "$RESULTS") ;;
    esac
  fi
  if [ -z "$value" ]; then echo "SKIP  $metric (not measured in this run)"; continue; fi
  # Time budgets scale with BENCH_TOLERANCE, memory budgets with BENCH_MEMORY_TOLERANCE; counts never.
  case "$metric" in
    *_mb) factor="$MEMORY_TOLERANCE" ;;
    *ms*|*.max) factor="$TOLERANCE" ;;
    *) factor=1 ;;
  esac
  budget=$(awk -v l="$limit" -v f="$factor" 'BEGIN { printf "%g", l * f }')
  shown="$limit"; [ "$budget" = "$limit" ] || shown="$limit ×$factor = $budget"
  allowed=$(awk -v l="$budget" -v m="$MARGIN" 'BEGIN { a = l * (1 + m); printf "%.2f", a }')
  if awk -v v="$value" -v a="$allowed" 'BEGIN { exit !(v > a) }'; then
    echo "FAIL  $metric = $value (budget $shown, allowed $allowed)"; fail=1
  else
    echo "ok    $metric = $value (budget $shown)"
  fi
done < "$BUDGETS"
exit $fail
