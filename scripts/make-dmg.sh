#!/usr/bin/env bash
# Packages build/Arbor.app into build/Arbor-<version>.dmg.
#
# Usage: scripts/make-dmg.sh [--universal] [--skip-build] [--format ULFO|UDZO] [--plain]
#
#   --universal   build the app for Apple silicon and Intel first (scripts/build-app.sh release --universal)
#   --skip-build  package the existing build/Arbor.app as it is (used after signing)
#   --format      compressed image format: ULFO (LZFSE, default, macOS 10.11+) or UDZO (zlib)
#   --plain       no background picture or window layout
#
# The disk image holds Arbor.app and a link to /Applications. Its Finder window shows a drawn
# background with an arrow, at a fixed size, with the two icons side by side. Everything is made
# with the Command Line Tools (hdiutil, swift); Finder is never scripted, so it runs headless.
# The image is verified by mounting it privately (hidden from Finder) and checking its contents.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=0
BUILD=1
FORMAT=ULFO
PLAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --skip-build) BUILD=0 ;;
    --format) FORMAT="${2:?--format needs ULFO or UDZO}"; shift ;;
    --plain) PLAIN=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "make-dmg.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
case "$FORMAT" in ULFO|UDZO) ;; *) echo "make-dmg.sh: --format must be ULFO or UDZO" >&2; exit 2 ;; esac

APP="build/Arbor.app"
if [ "$BUILD" = 1 ]; then
  if [ "$UNIVERSAL" = 1 ]; then scripts/build-app.sh release --universal; else scripts/build-app.sh release; fi
fi
[ -d "$APP" ] || { echo "make-dmg.sh: $APP not found; run scripts/build-app.sh first" >&2; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
VOLNAME="Arbor"
DMG="build/Arbor-$VERSION.dmg"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/arbor-dmg.XXXXXX")"
MOUNT="$WORK/mount"
CHECK="$WORK/check"
cleanup() {
  for dir in "$MOUNT" "$CHECK"; do
    if mount | grep -qF " on $dir ("; then hdiutil detach -quiet -force "$dir" || true; fi
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Writable image with the app and the Applications link.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Arbor.app"
ln -s /Applications "$STAGE/Applications"
APP_MB=$(du -sm "$STAGE" | awk '{ print $1 }')
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW \
  -size "$((APP_MB + 20))m" "$WORK/rw.dmg"

# 2. Layout: background picture, window settings and icon positions, plus the volume icon.
#    Mounted outside /Volumes and with -nobrowse so it never shows up in Finder.
if [ "$PLAIN" = 0 ]; then
  mkdir -p "$MOUNT"
  hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" "$WORK/rw.dmg"
  mkdir -p "$MOUNT/.background"
  swift scripts/dmg-layout.swift background "$WORK/art"
  # One TIFF with both resolutions, so the background is sharp on Retina displays.
  tiffutil -cathidpicheck "$WORK/art/background.png" "$WORK/art/background@2x.png" \
    -out "$MOUNT/.background/background.tiff" 2>/dev/null
  swift scripts/dmg-layout.swift dsstore "$MOUNT" "$MOUNT/.background/background.tiff"
  if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
    # Mark the volume as having a custom icon (Finder flag C). SetFile needs Xcode or the
    # Command Line Tools; without it the disk keeps the standard icon.
    if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MOUNT"; fi
  fi
  rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
  sync
  hdiutil detach -quiet "$MOUNT"
fi

# 3. Compressed, read-only image.
mkdir -p build
rm -f "$DMG"
KEYS=()
if [ "$FORMAT" = UDZO ]; then KEYS=(-imagekey zlib-level=9); fi
hdiutil convert -quiet "$WORK/rw.dmg" -format "$FORMAT" ${KEYS[@]+"${KEYS[@]}"} -o "$DMG"
hdiutil verify -quiet "$DMG"

# 4. Check what a user gets: mount read-only, privately, and look inside.
mkdir -p "$CHECK"
hdiutil attach -quiet -readonly -noverify -noautoopen -nobrowse -mountpoint "$CHECK" "$DMG"
fail() { echo "make-dmg.sh: check failed: $1" >&2; exit 1; }   # cleanup detaches
[ -d "$CHECK/Arbor.app/Contents/MacOS" ] || fail "Arbor.app missing"
[ "$(readlink "$CHECK/Applications")" = "/Applications" ] || fail "Applications link missing"
[ "$(plutil -extract CFBundleShortVersionString raw "$CHECK/Arbor.app/Contents/Info.plist")" = "$VERSION" ] || fail "version mismatch"
codesign --verify --strict "$CHECK/Arbor.app" 2>/dev/null || fail "Arbor.app signature does not verify"
if [ "$PLAIN" = 0 ]; then
  [ -f "$CHECK/.DS_Store" ] || fail "window layout missing"
  [ -f "$CHECK/.background/background.tiff" ] || fail "background missing"
fi
ARCHS="$(lipo -archs "$CHECK/Arbor.app/Contents/MacOS/Arbor")"
CONTENTS="$(ls -A "$CHECK" | tr '\n' ' ')"
hdiutil detach -quiet "$CHECK"

echo "Built $DMG ($FORMAT, $(du -h "$DMG" | awk '{ print $1 }'), $ARCHS)"
echo "  contains: $CONTENTS"
