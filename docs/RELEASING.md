# Releasing Arbor

Releases are disk images (`Arbor-<version>.dmg`) attached to the repository's
[GitHub Releases](../../../releases) page. Each holds one universal `Arbor.app` (Apple silicon
and Intel, macOS 14+) and a link to `/Applications`. See DEC-003, DEC-004 and DEC-005 in
[DECISIONS.md](DECISIONS.md).

## How versions work

- `VERSION` (repository root) is the only place the version is written, e.g. `0.3.0`. It becomes
  `CFBundleShortVersionString`, the disk image name and the release tag (`v0.3.0`).
- The build number (`CFBundleVersion`) is the number of commits, `git rev-list --count HEAD`, so
  every build from a later commit has a higher number. Builds from a shallow clone print a warning;
  set `ARBOR_BUILD_NUMBER` to override.
- The minimum macOS comes from `platforms` in `Package.swift` and is written to
  `LSMinimumSystemVersion`; the build checks that every architecture slice targets the same version.
- Arbor ▸ About Arbor shows "Version 0.3.0 (123)": version and build number.

## Scripts

| Script | Does |
|---|---|
| `scripts/build-app.sh release --universal` | `build/Arbor.app` for arm64 + x86_64 (each built separately, joined with `lipo`; no Xcode needed) |
| `scripts/make-dmg.sh [--universal] [--skip-build]` | `build/Arbor-<version>.dmg` (LZFSE-compressed, `--format UDZO` for zlib), with a drawn background and a fixed window layout. Mounts the result privately and checks its contents |
| `scripts/sign-and-notarize.sh` | Marks the app for distribution (`ArborDistribution` in Info.plist, which turns off the `ARBOR_*` test hooks), signs Sparkle's nested code first and then the app, inside out through `scripts/lib/codesign-app.sh`, with the hardened runtime (Developer ID with `Resources/Arbor.entitlements`, or ad-hoc with a warning and `Resources/Arbor-adhoc.entitlements` when no identity is set, DEC-028), makes the disk image, signs it, notarizes it with `xcrun notarytool` and staples the ticket. `--rehearsal` stops short of Apple's services (CI only needs it) |
| `scripts/ci-import-certificate.sh` | Workflows only: puts a `.p12` in a new keychain. Refuses to run outside a GitHub-hosted runner |
| `scripts/make-update.sh <zip URL> < key` | The in-app update (FE-259): `build/Arbor-<version>.zip` of the signed app and `build/appcast.xml`, both signed with the EdDSA private key read from standard input. Checks the zip's signature against the app's public key first |
| `scripts/update-e2e.sh` | At the Mac, not CI: an older copy installs a newer one from a feed on 127.0.0.1 and relaunches, and badly signed updates are refused (docs/features/updates.md) |

## One-time setup

### Without an Apple Developer account
Nothing to set up. Releases are ad-hoc signed; the release notes and the README tell people how to
open an ad-hoc signed app the first time.

### In-app updates (once)

Testers get later releases through Arbor's Update button (FE-259, docs/features/updates.md). Updates are
accepted only when they are signed with your EdDSA key, so the key pair is made once and kept for good: if the
private key is lost or changed, apps already installed can't update any more and need one manual install.

1. Make the key pair with Sparkle's own tool, from the package this repository pins (no download from elsewhere):
   ```bash
   swift package --disable-keychain resolve
   GENERATE_KEYS="$(find .build/artifacts -type f -path '*/Sparkle/bin/generate_keys' | head -n 1)"
   "$GENERATE_KEYS"            # stores the private key in your login keychain and prints the public key
   "$GENERATE_KEYS" -p         # prints the public key again whenever you need it
   ```
2. Put the public key (44 characters, ending in `=`) in a repository **variable**, not a secret: it ships inside
   every app. The Release workflow writes it into Info.plist.
   ```bash
   gh variable set SPARKLE_ED_PUBLIC_KEY --body "<the public key>"
   ```
3. Store the private key as a repository **secret**, straight from the keychain export, and delete the export:
   ```bash
   "$GENERATE_KEYS" -x private-key.txt
   gh secret set SPARKLE_ED_PRIVATE_KEY < private-key.txt
   ```
4. Keep an offline backup of `private-key.txt` (for example on an encrypted USB drive or in a password manager),
   then delete the file: `rm private-key.txt`. Never commit it, paste it into an issue or put it in a script.
   `"$GENERATE_KEYS" -f private-key.txt` brings a backup back into a keychain.
5. Set both or neither. With neither, releases work as before, the Release workflow notes that no update feed
   was made, and the app has no updater. With only one, the Release workflow stops with an error.

The feed address is never written in the repository: the workflow builds it from the repository's own name.

### If a Developer ID is ever added (signed and notarized releases)

Arbor ships without one (DEC-027). These steps are kept for a future maintainer.
Do these once, in order. No file in the repository has to change: the Release workflow reads the six
secrets in step 7.

1. Join the Apple Developer Program. Your ten-character **Team ID** is on developer.apple.com ▸
   Account ▸ Membership details.
2. On developer.apple.com ▸ Certificates, create a **Developer ID Application** certificate. Download
   it and double-click it to install it in your login keychain.
3. Copy the identity's exact name, e.g. `Developer ID Application: Jane Doe (TEAMID1234)`. It must be
   listed here:
   ```bash
   security find-identity -v -p codesigning
   ```
4. In Keychain Access ▸ login ▸ My Certificates, select that certificate with its private key, choose
   File ▸ Export Items, save as `cert.p12` and set a strong password.
5. Create an app-specific password at account.apple.com ▸ Sign-In and Security ▸ App-Specific
   Passwords.
6. Optional, to release from your own Mac: store notarization credentials once.
   ```bash
   xcrun notarytool store-credentials arbor-notary \
     --apple-id you@example.com --team-id TEAMID1234 --password <app-specific password>
   ```
7. Add all six repository secrets under Settings ▸ Secrets and variables ▸ Actions. Names must match
   exactly.

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_CERTIFICATE_P12` | the output of `base64 -i cert.p12` |
   | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the password from step 4 |
   | `DEVELOPER_ID_APPLICATION` | the identity name from step 3 |
   | `APPLE_ID` | your Apple Account email |
   | `APPLE_TEAM_ID` | the Team ID from step 1 |
   | `APPLE_APP_PASSWORD` | the app-specific password from step 5 |

   With the GitHub command line, `base64 -i cert.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12`
   sets the first, and `gh secret set <NAME>` asks for each of the others.

   Set all six or none. With none, the workflow still runs and makes an ad-hoc signed image labeled
   as such. With only some, the release notes can wrongly say the image is signed and notarized.
8. Delete `cert.p12`. The private key stays in your keychain; back it up somewhere safe.
9. Make the first signed release with the checklist below and watch the **Release** workflow. It has
   never run, so read its log: "Sign, package and notarize" must end with "is signed, notarized and
   stapled."


### Repository settings
In the repository settings, turn on **Private vulnerability reporting** (Security ▸ Settings) so the
process in [SECURITY.md](../SECURITY.md) works.

## Checklist for each release

1. [ ] `main` is green in CI and `docs/FEATURE-STATUS.md` describes what ships.
2. [ ] Bump `VERSION` (semantic versioning: `MAJOR.MINOR.PATCH`) and commit: "Release 0.3.0".
3. [ ] Local check:
   ```bash
   scripts/test.sh
   scripts/build-app.sh release --universal
   lipo -info build/Arbor.app/Contents/MacOS/Arbor     # x86_64 arm64
   scripts/make-dmg.sh --skip-build
   ```
   Open the disk image and check the window (background, icon positions), drag Arbor to a test
   folder, launch it, check About Arbor shows the new version. On an Apple silicon Mac with Rosetta,
   `arch -x86_64 build/Arbor.app/Contents/MacOS/Arbor` checks the Intel half.
4. [ ] Tag and push: `git tag v0.3.0 && git push origin v0.3.0`. The **Release** workflow checks the
   tag matches `VERSION`, runs the tests, builds, signs and notarizes (when the secrets are set) and
   creates a **draft** release with the disk image and its `.sha256`. With the update key set up, the draft
   also has `Arbor-<version>.zip` (the update) and `appcast.xml` (the feed, whose notes are this version's
   CHANGELOG.md section). Don't rename, replace or edit them: both are signed, and testers' copies check the
   feed as soon as the draft is published.
   (To release from your own Mac instead: `scripts/build-app.sh release --universal`, then
   `DEVELOPER_ID_APPLICATION=… NOTARY_KEYCHAIN_PROFILE=arbor-notary scripts/sign-and-notarize.sh`,
   and upload `build/Arbor-<version>.dmg` to a new release.)
5. [ ] Download the image from the draft, then on a Mac that has never run Arbor:
   - signed builds: `spctl --assess --type open --context context:primary-signature -v Arbor-<version>.dmg`
     says "accepted, source=Notarized Developer ID", and the app opens without warnings;
   - ad-hoc signed builds: the README's first-launch steps work.
6. [ ] Edit the release notes (what's new, known issues, signed or not) and publish the draft. Publishing
   makes it the latest release, so testers' Update button offers it within about a day (Arbor ▸ Check for
   Updates… at once). The page's notes don't reach the update window; its notes come from CHANGELOG.md.
7. [ ] Homebrew: update `version` and `sha256` in `packaging/homebrew/arbor.rb` (the `.sha256`
   file attached to the release has the checksum) and copy it to the tap (see the comments in
   that file).
8. [ ] Bump `VERSION` on `main` to the next planned version if you like to keep it ahead.

## Notes

- Notarization covers the disk image and the app inside it; the ticket is stapled to the disk image.
  An app copied out of it is checked online by Gatekeeper the first time it opens.
- Every release, ad-hoc ones included, has the hardened runtime, so `DYLD_*` variables cannot load code into Arbor; the script fails if the signature lacks it.
- After `sign-and-notarize.sh`, `build/Arbor.app` ignores `ARBOR_*`; rebuild it before running the scripted suites.
- `Resources/Arbor.entitlements` is intentionally empty: Arbor is not sandboxed. Ad-hoc releases use
  `Resources/Arbor-adhoc.entitlements`, which adds one hardened-runtime exception, library validation, so the
  embedded Sparkle.framework loads without a Team ID (DEC-028). Add a key only with a comment naming the feature
  that needs it.
- `scripts/build-app.sh` and `scripts/sign-and-notarize.sh` sign the code inside Sparkle.framework, then the framework,
  then the app (`scripts/lib/codesign-app.sh`), never with `codesign --deep`.
- The disk image layout is written directly (`scripts/dmg-layout.swift`), not by scripting
  Finder, so it builds on CI and headless Macs. If Finder ever ignores it, `make-dmg.sh --plain`
  makes a plain image.
