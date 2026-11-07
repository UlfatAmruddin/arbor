#!/usr/bin/env bash
# Builds build/Arbor.app. Usage: scripts/build-app.sh [release|debug]
# The result is ad-hoc signed for local use. Public releases need a Developer ID
# signature and Apple notarization (see docs/DECISIONS.md, DEC-004).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Arbor
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Arbor"
APP="build/Arbor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Arbor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
