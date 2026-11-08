#!/usr/bin/env bash
# Runs the unit tests. Works with full Xcode or with only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
# Fixtures of earlier runs that were interrupted (a killed run never reaches the tests' own cleanup):
# folders and disk images the tests create in the temporary folder, once they are two hours old.
# Newer ones may belong to a run still in progress. Mounted test volumes are detached first.
sweep_stale_fixtures() {
  local tmp="${TMPDIR:-/tmp}" d
  while IFS= read -r d; do
    hdiutil detach -force -quiet "$d" >/dev/null 2>&1 || true
    # Tests leave locked items and "deny delete" access rules; clear both before deleting.
    chflags -R nouchg "$d" 2>/dev/null || true
    chmod -R -N "$d" 2>/dev/null || true
    chmod -R u+rwx "$d" 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true   # never stop the test run over a leftover
  done < <(find "$tmp" -maxdepth 1 -type d \( -name 'arbor-tests-*' -o -name 'arbor-vol-*' -o -name 'arbor-qa-*' \) -mmin +120 2>/dev/null)
  find "$tmp" -maxdepth 1 -type f \( -name 'arbor-vol-*.dmg' -o -name 'arbor-qa-*.dmg' \) -mmin +120 -delete 2>/dev/null || true
}
sweep_stale_fixtures

# The English string table must list every routed string (FE-204).
scripts/extract-strings.sh --check
EXTRA=()
if ! xcodebuild -version >/dev/null 2>&1; then
  # Command Line Tools ship Swift Testing outside the default search paths.
  CLT=/Library/Developer/CommandLineTools/Library/Developer
  EXTRA=(-Xswiftc -F -Xswiftc "$CLT/Frameworks"
         -Xlinker -F -Xlinker "$CLT/Frameworks"
         -Xlinker -rpath -Xlinker "$CLT/Frameworks"
         -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi
swift test ${EXTRA[@]+"${EXTRA[@]}"} "$@"
