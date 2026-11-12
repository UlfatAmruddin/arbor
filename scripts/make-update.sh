#!/usr/bin/env bash
# Makes the in-app update of build/Arbor.app (FE-259, DEC-028): build/Arbor-<version>.zip and
# build/appcast.xml, both signed with Sparkle's EdDSA private key.
#
# Usage: scripts/make-update.sh [--app <Arbor.app>] [--out <folder>] <download URL of the zip> < private-key
#
#   --app   the app to publish (default build/Arbor.app; relative paths start at the repository root)
#   --out   where the zip and appcast.xml go (default build)
#
# The private key, as Sparkle's generate_keys exports it, is read from standard input only, never from an
# argument or a file, and reaches sign_update the same way. Run it after scripts/sign-and-notarize.sh, so
# the zip holds the same app as the disk image; the app must have been built with an update feed
# (scripts/build-app.sh). sign_update is the one in the Sparkle package that Package.resolved pins.
# The feed carries one item, this version: its notes are this version's section of CHANGELOG.md, and
# the zip's signature is checked against the app's SUPublicEDKey before the feed is written.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
APP="build/Arbor.app"
OUT="build"
URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?--app needs a path}"; shift ;;
    --out) OUT="${2:?--out needs a folder}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "make-update.sh: unknown option '$1'" >&2; exit 2 ;;
    *) [ -z "$URL" ] || { echo "make-update.sh: one download URL only" >&2; exit 2; }; URL="$1" ;;
  esac
  shift
done
[ -n "$URL" ] || { usage >&2; exit 2; }
# The key is read first, so no other tool below can read it from standard input.
KEY="$(cat)"
[ -n "$KEY" ] || { echo "make-update.sh: no private key on standard input" >&2; exit 1; }
exec </dev/null
[ -d "$APP" ] || { echo "make-update.sh: $APP not found; build and sign it first" >&2; exit 1; }
mkdir -p "$OUT"
PLIST="$APP/Contents/Info.plist"
plutil -extract SUFeedURL raw "$PLIST" >/dev/null 2>&1 \
  || { echo "make-update.sh: $APP has no update feed; build it with ARBOR_UPDATE_FEED_URL and ARBOR_UPDATE_PUBLIC_KEY" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$PLIST")"
ZIP="$OUT/Arbor-$VERSION.zip"
FEED="$OUT/appcast.xml"

swift package --disable-keychain resolve >/dev/null
SIGN_UPDATE="$(find .build/artifacts -type f -perm -u+x -path '*/Sparkle/bin/sign_update' | head -n 1)"
[ -n "$SIGN_UPDATE" ] || { echo "make-update.sh: sign_update not found in the Sparkle package" >&2; exit 1; }

# printf is a shell builtin, so the key never appears in a process's arguments.
sign() { printf '%s' "$KEY" | "$SIGN_UPDATE" --ed-key-file - "$@"; }

rm -f "$ZIP" "$FEED"
# ditto keeps Sparkle.framework's symlinks; --keepParent puts Arbor.app at the top of the zip.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGNATURE="$(sign -p "$ZIP")"
swift run --disable-keychain --quiet ArborAppcast --app "$APP" --archive "$ZIP" --signature "$SIGNATURE" --url "$URL" \
  --changelog CHANGELOG.md --output "$FEED"
# The feed carries its own signature too (SURequireSignedFeed in Info.plist).
sign "$FEED" >/dev/null
sign --verify "$FEED" >/dev/null
unset KEY
echo "Made $ZIP and $FEED (version $VERSION, build $BUILD_NUMBER)"
