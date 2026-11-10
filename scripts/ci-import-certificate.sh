#!/usr/bin/env bash
# Imports a signing identity (.p12) into a new keychain, $RUNNER_TEMP/signing.keychain-db, and puts that first
# on the keychain search list. Used by the release workflow; the .p12 is removed.
#
# Usage: CERTIFICATE_PASSWORD=<.p12 password> scripts/ci-import-certificate.sh <file.p12>
#
# GitHub-hosted runners only: it replaces the keychain search list, which must never happen on someone's own Mac.
set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ] || [ -z "${RUNNER_TEMP:-}" ]; then
  echo "ci-import-certificate.sh: refusing to run outside a GitHub-hosted runner" >&2
  exit 1
fi

P12="${1:?usage: ci-import-certificate.sh <file.p12>}"
: "${CERTIFICATE_PASSWORD:?CERTIFICATE_PASSWORD is not set}"
trap 'rm -f "$P12"' EXIT

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
# shellcheck disable=SC2046   # one path per word; these have no spaces on a runner
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
