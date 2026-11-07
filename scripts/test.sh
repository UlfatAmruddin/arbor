#!/usr/bin/env bash
# Runs the unit tests. Works with full Xcode or with only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
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
