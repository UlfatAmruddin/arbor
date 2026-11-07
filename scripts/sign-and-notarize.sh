#!/usr/bin/env bash
# Signs build/Arbor.app, packages it into build/Arbor-<version>.dmg, and (when credentials are
# available) notarizes and staples the disk image.
#
# Usage: scripts/sign-and-notarize.sh [--format ULFO|UDZO]
#
# Run scripts/build-app.sh release --universal first.
#
# Environment:
#   DEVELOPER_ID_APPLICATION  signing identity, e.g. "Developer ID Application: Jane Doe (TEAMID1234)"
#                             (must be in the keychain). Without it the app is ad-hoc signed only.
#   Notarization, either:
#     NOTARY_KEYCHAIN_PROFILE  a profile saved with `xcrun notarytool store-credentials`
#   or all of:
#     APPLE_ID                 Apple Account email of the developer
#     APPLE_TEAM_ID            ten-character team ID
#     APPLE_APP_PASSWORD       app-specific password from account.apple.com
#   Without notarization credentials a Developer ID signed image is produced but not notarized.
#
# See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --format) DMG_ARGS+=(--format "${2:?--format needs ULFO or UDZO}"); shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sign-and-notarize.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

APP="build/Arbor.app"
ENTITLEMENTS="Resources/Arbor.entitlements"
[ -d "$APP" ] || { echo "sign-and-notarize.sh: $APP not found; run scripts/build-app.sh release --universal first" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DMG="build/Arbor-$VERSION.dmg"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

# --- Ad-hoc path -------------------------------------------------------------------------------
if [ -z "$IDENTITY" ]; then
  codesign --force --sign - "$APP"
  codesign --verify --strict "$APP"
  scripts/make-dmg.sh --skip-build ${DMG_ARGS[@]+"${DMG_ARGS[@]}"}
  cat <<EOF

$DMG is ad-hoc signed: not signed with a Developer ID and not notarized.
It runs on this Mac. On other Macs, Gatekeeper blocks the first launch; people then open it with
right-click > Open, or System Settings > Privacy & Security > Open Anyway (see README, Install).

To make a signed, notarized release:
  1. Join the Apple Developer Program and create a "Developer ID Application" certificate.
  2. Install it in your login keychain and find its exact name:
       security find-identity -v -p codesigning
  3. Save notarization credentials once (stored in your keychain):
       xcrun notarytool store-credentials arbor-notary \\
         --apple-id you@example.com --team-id TEAMID1234 --password <app-specific password>
  4. Run:
       DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID1234)" \\
       NOTARY_KEYCHAIN_PROFILE=arbor-notary scripts/sign-and-notarize.sh
EOF
  exit 0
fi

# --- Developer ID path -------------------------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
  echo "sign-and-notarize.sh: signing identity not found in the keychain: $IDENTITY" >&2
  echo "  (security find-identity -v -p codesigning lists the available ones)" >&2
  exit 1
fi

echo "Signing $APP with hardened runtime"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

scripts/make-dmg.sh --skip-build ${DMG_ARGS[@]+"${DMG_ARGS[@]}"}

echo "Signing $DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

NOTARY=()
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  NOTARY=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
if [ ${#NOTARY[@]} -eq 0 ]; then
  echo
  echo "$DMG is signed but NOT notarized (set NOTARY_KEYCHAIN_PROFILE, or APPLE_ID, APPLE_TEAM_ID"
  echo "and APPLE_APP_PASSWORD). Gatekeeper still warns about un-notarized downloads."
  exit 0
fi

echo "Submitting $DMG for notarization (this usually takes a few minutes)"
SUBMIT_LOG="$(mktemp "${TMPDIR:-/tmp}/arbor-notary.XXXXXX")"
if ! xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --output-format plist > "$SUBMIT_LOG"; then
  cat "$SUBMIT_LOG" >&2
  exit 1
fi
STATUS="$(plutil -extract status raw "$SUBMIT_LOG" 2>/dev/null || echo unknown)"
SUBMISSION="$(plutil -extract id raw "$SUBMIT_LOG" 2>/dev/null || echo unknown)"
rm -f "$SUBMIT_LOG"
if [ "$STATUS" != "Accepted" ]; then
  echo "sign-and-notarize.sh: notarization finished with status '$STATUS'. Details:" >&2
  xcrun notarytool log "$SUBMISSION" "${NOTARY[@]}" >&2 || true
  exit 1
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo
echo "$DMG is signed, notarized and stapled."
shasum -a 256 "$DMG"
