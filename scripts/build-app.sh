#!/usr/bin/env bash
# Builds build/Arbor.app.
#
# Usage: scripts/build-app.sh [release|debug] [--universal]
#
#   release      optimized build (default)
#   debug        debug build
#   --universal  one app that runs natively on Apple silicon (arm64) and Intel (x86_64)
#
# Without --universal the app is built for this Mac's architecture only.
#
# In-app updates (FE-259, DEC-028): set both ARBOR_UPDATE_FEED_URL (https) and ARBOR_UPDATE_PUBLIC_KEY
# (Sparkle's base64 EdDSA public key) to write SUFeedURL and SUPublicEDKey into Info.plist. Without
# them the app has no updater at all. The Release workflow sets them; nothing in the tree names the feed.
#
# Version: CFBundleShortVersionString comes from the VERSION file and CFBundleVersion from the
# number of commits (git rev-list --count HEAD). Set ARBOR_BUILD_NUMBER to override the latter.
# Minimum macOS: taken from `platforms` in Package.swift and written to LSMinimumSystemVersion;
# the binary's own minimum (LC_BUILD_VERSION) is checked against it.
#
# Sparkle.framework is copied into Contents/Frameworks with its symlinks, and everything is ad-hoc
# signed inside out for local use. Releases are signed again by scripts/sign-and-notarize.sh
# (see docs/RELEASING.md and docs/DECISIONS.md, DEC-027).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/codesign-app.sh

CONFIG=release
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --universal) UNIVERSAL=1 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build-app.sh: unknown argument '$arg' (expected release, debug or --universal)" >&2; exit 2 ;;
  esac
done

# --- Version -----------------------------------------------------------------------------------
VERSION="$(tr -d '[:space:]' < VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "build-app.sh: VERSION must look like 1.2.3 (got '$VERSION')" >&2
  exit 1
fi
if [ -n "${ARBOR_BUILD_NUMBER:-}" ]; then
  BUILD_NUMBER="$ARBOR_BUILD_NUMBER"
elif BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null)"; then
  :
else
  BUILD_NUMBER=1
fi
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ] && [ -z "${ARBOR_BUILD_NUMBER:-}" ]; then
  echo "build-app.sh: warning: shallow clone, so the build number ($BUILD_NUMBER) is too low; fetch full history or set ARBOR_BUILD_NUMBER" >&2
fi

# --- Update feed (optional) --------------------------------------------------------------------
FEED_URL="${ARBOR_UPDATE_FEED_URL:-}"
PUBLIC_KEY="${ARBOR_UPDATE_PUBLIC_KEY:-}"
if [ -n "$FEED_URL" ] || [ -n "$PUBLIC_KEY" ]; then
  if [ -z "$FEED_URL" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "build-app.sh: set both ARBOR_UPDATE_FEED_URL and ARBOR_UPDATE_PUBLIC_KEY, or neither" >&2
    exit 1
  fi
  if ! [[ "$FEED_URL" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~%/-]*)?$ ]]; then
    echo "build-app.sh: ARBOR_UPDATE_FEED_URL must be a plain https URL" >&2
    exit 1
  fi
  # 32 bytes in base64, the form Sparkle's generate_keys prints.
  if ! [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "build-app.sh: ARBOR_UPDATE_PUBLIC_KEY is not an EdDSA public key from generate_keys" >&2
    exit 1
  fi
fi

# --- Minimum macOS, from Package.swift ----------------------------------------------------------
MIN_MAJOR="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)(_([0-9]+))?\).*/\1/p' Package.swift | head -n 1)"
MIN_MINOR="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)(_([0-9]+))?\).*/\3/p' Package.swift | head -n 1)"
if [ -z "$MIN_MAJOR" ]; then
  echo "build-app.sh: could not read the macOS platform from Package.swift" >&2
  exit 1
fi
MIN_MACOS="$MIN_MAJOR.${MIN_MINOR:-0}"

# --- Compile -----------------------------------------------------------------------------------
if [ "$UNIVERSAL" = 1 ]; then
  # `swift build --arch arm64 --arch x86_64` needs full Xcode, so build each architecture on its
  # own (this works with just the Command Line Tools) and join the two with lipo.
  SLICES=()
  for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx$MIN_MACOS"
    swift build --disable-keychain -c "$CONFIG" --product Arbor --triple "$TRIPLE"
    SLICES+=("$(swift build --disable-keychain -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)/Arbor")
  done
  mkdir -p build
  BIN="build/Arbor-universal"
  lipo -create "${SLICES[@]}" -output "$BIN"
  FRAMEWORK="$(dirname "${SLICES[0]}")/Sparkle.framework"
else
  swift build --disable-keychain -c "$CONFIG" --product Arbor
  BIN="$(swift build --disable-keychain -c "$CONFIG" --show-bin-path)/Arbor"
  FRAMEWORK="$(dirname "$BIN")/Sparkle.framework"
fi

# Every slice must target the same minimum macOS as Info.plist.
for ARCH in $(lipo -archs "$BIN"); do
  MINOS="$(vtool -arch "$ARCH" -show-build "$BIN" | awk '$1 == "minos" { print $2; exit }')"
  if [ "$MINOS" != "$MIN_MACOS" ]; then
    echo "build-app.sh: $ARCH slice targets macOS $MINOS, expected $MIN_MACOS" >&2
    exit 1
  fi
done

# --- Bundle ------------------------------------------------------------------------------------
APP="build/Arbor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Arbor"
if [ "$UNIVERSAL" = 1 ]; then rm -f "$BIN"; fi
# Sparkle (in-app updates): ditto keeps the framework's Versions symlinks, which its signature covers.
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
for ARCH in $(lipo -archs "$APP/Contents/MacOS/Arbor"); do
  if ! lipo -archs "$APP/Contents/Frameworks/Sparkle.framework/Sparkle" | tr ' ' '\n' | grep -qx "$ARCH"; then
    echo "build-app.sh: Sparkle.framework has no $ARCH slice" >&2
    exit 1
  fi
done
if ! otool -l "$APP/Contents/MacOS/Arbor" | grep -q "path @executable_path/../Frameworks "; then
  # The linker's signature goes first, or install_name_tool warns that it breaks it; the bundle is signed below.
  codesign --remove-signature "$APP/Contents/MacOS/Arbor"
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Arbor"
fi
PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$PLIST"
if [ -n "$FEED_URL" ]; then
  plutil -replace SUFeedURL -string "$FEED_URL" "$PLIST"
  plutil -replace SUPublicEDKey -string "$PUBLIC_KEY" "$PLIST"
fi
plutil -lint -s "$PLIST"
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sparkle's license travels with its binary.
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
# String tables (en.lproj is the English base; see scripts/extract-strings.sh).
LANGUAGES=()
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
  LANGUAGES+=("\"$(basename "$lproj" .lproj)\"")
done
plutil -replace CFBundleLocalizations -json "[$(IFS=,; echo "${LANGUAGES[*]}")]" "$PLIST"
arbor_codesign_app "$APP" - >/dev/null
UPDATES="no update feed"
if [ -n "$FEED_URL" ]; then UPDATES="update feed set"; fi
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/Arbor" | sed 's/ / + /g'), macOS $MIN_MACOS+, $UPDATES)"
