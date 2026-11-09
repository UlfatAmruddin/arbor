#!/usr/bin/env bash
# Signs build/Arbor.app, packages it into build/Arbor-<version>.dmg, and (when credentials are
# available) notarizes and staples the disk image.
#
# Usage: scripts/sign-and-notarize.sh [--format ULFO|UDZO] [--rehearsal]
#
# Run scripts/build-app.sh release --universal first.
#
#   --rehearsal  needs an identity and does all but contact Apple: no secure timestamp, no notarization.
#                What it makes is not for release. CI uses it with a throwaway identity.
#
# Environment:
#   DEVELOPER_ID_APPLICATION  signing identity, e.g. "Developer ID Application: Jane Doe (TEAMID1234)"
#                             (must be in the keychain). Without it the app is ad-hoc signed only
#                             (still with the hardened runtime), and a warning says so.
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
REHEARSAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format) DMG_ARGS+=(--format "${2:?--format needs ULFO or UDZO}"); shift ;;
    --rehearsal) REHEARSAL=1 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# Falling back to ad-hoc would let a rehearsal pass while proving nothing.
if [ "$REHEARSAL" = 1 ] && [ -z "$IDENTITY" ]; then
  echo "sign-and-notarize.sh: --rehearsal needs DEVELOPER_ID_APPLICATION" >&2
  exit 2
fi
# The timestamp service is Apple's.
TIMESTAMP=--timestamp
if [ "$REHEARSAL" = 1 ]; then TIMESTAMP=--timestamp=none; fi

# Distribution builds ignore the ARBOR_* test hooks (ArborCore/Automation.swift); ad-hoc ones have no Team ID to tell.
plutil -replace ArborDistribution -bool YES "$APP/Contents/Info.plist"

require_hardened_runtime() {
  local info
  info="$(codesign --display --verbose=1 "$APP" 2>&1)"
  grep -q '^CodeDirectory .*flags=.*runtime' <<< "$info" \
    || { echo "sign-and-notarize.sh: $APP is not signed with the hardened runtime" >&2; exit 1; }
}

# --- Ad-hoc path -------------------------------------------------------------------------------
if [ -z "$IDENTITY" ]; then
  WARNING="DEVELOPER_ID_APPLICATION is not set: $DMG will be ad-hoc signed, NOT Developer ID signed or notarized"
  echo "WARNING: $WARNING" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$WARNING"; fi
  # Hardened runtime even ad-hoc, so DYLD_* injection cannot borrow Arbor's privacy grants.
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
  codesign --verify --strict "$APP"
  require_hardened_runtime
  scripts/make-dmg.sh --skip-build ${DMG_ARGS[@]+"${DMG_ARGS[@]}"}
  cat <<EOF

$DMG is ad-hoc signed (hardened runtime): not signed with a Developer ID and not notarized.
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
codesign --force --options runtime "$TIMESTAMP" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
require_hardened_runtime

scripts/make-dmg.sh --skip-build ${DMG_ARGS[@]+"${DMG_ARGS[@]}"}

echo "Signing $DMG"
codesign --force "$TIMESTAMP" --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [ "$REHEARSAL" = 1 ]; then
  echo
  echo "$DMG is a rehearsal: no secure timestamp and not notarized. Do not release it."
  exit 0
fi

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
