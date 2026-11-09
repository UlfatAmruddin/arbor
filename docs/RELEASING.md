# Releasing Arbor

Releases are disk images (`Arbor-<version>.dmg`) attached to the repository's
[GitHub Releases](../../../releases) page. Each holds one universal `Arbor.app` (Apple silicon
and Intel, macOS 14+) and a link to `/Applications`. See DEC-003, DEC-004 and DEC-005 in
[DECISIONS.md](DECISIONS.md).

## How versions work

- `VERSION` (repository root) is the only place the version is written, e.g. `0.2.0`. It becomes
  `CFBundleShortVersionString`, the disk image name and the release tag (`v0.2.0`).
- The build number (`CFBundleVersion`) is the number of commits, `git rev-list --count HEAD`, so
  every build from a later commit has a higher number. Builds from a shallow clone print a warning;
  set `ARBOR_BUILD_NUMBER` to override.
- The minimum macOS comes from `platforms` in `Package.swift` and is written to
  `LSMinimumSystemVersion`; the build checks that every architecture slice targets the same version.
- Arbor ▸ About Arbor shows "Version 0.2.0 (123)": version and build number.

## Scripts

| Script | Does |
|---|---|
| `scripts/build-app.sh release --universal` | `build/Arbor.app` for arm64 + x86_64 (each built separately, joined with `lipo`; no Xcode needed) |
| `scripts/make-dmg.sh [--universal] [--skip-build]` | `build/Arbor-<version>.dmg` (LZFSE-compressed, `--format UDZO` for zlib), with a drawn background and a fixed window layout. Mounts the result privately and checks its contents |
| `scripts/sign-and-notarize.sh` | Marks the app for distribution (`ArborDistribution` in Info.plist, which turns off the `ARBOR_*` test hooks), signs it with the hardened runtime and `Resources/Arbor.entitlements` (Developer ID, or ad-hoc with a warning when no identity is set), makes the disk image, signs it, notarizes it with `xcrun notarytool` and staples the ticket. `--rehearsal` stops short of Apple's services (CI only needs it) |
| `scripts/ci-import-certificate.sh` | Workflows only: puts a `.p12` in a new keychain. Refuses to run outside a GitHub-hosted runner |

## One-time setup

### Without an Apple Developer account
Nothing to set up. Releases are ad-hoc signed; the release notes and the README tell people how to
open an ad-hoc signed app the first time.

### Once you have a Developer ID (signed and notarized releases)
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

CI's signing rehearsal covers the certificate import, hardened-runtime signing, the disk image and
the signature checks with a throwaway identity. It can't cover Apple's timestamp, notarization,
stapling or Gatekeeper, so step 9 and step 5 of the checklist are the first test of those.

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
   creates a **draft** release with the disk image and its `.sha256`.
   (To release from your own Mac instead: `scripts/build-app.sh release --universal`, then
   `DEVELOPER_ID_APPLICATION=… NOTARY_KEYCHAIN_PROFILE=arbor-notary scripts/sign-and-notarize.sh`,
   and upload `build/Arbor-<version>.dmg` to a new release.)
5. [ ] Download the image from the draft, then on a Mac that has never run Arbor:
   - signed builds: `spctl --assess --type open --context context:primary-signature -v Arbor-<version>.dmg`
     says "accepted, source=Notarized Developer ID", and the app opens without warnings;
   - ad-hoc signed builds: the README's first-launch steps work.
6. [ ] Edit the release notes (what's new, known issues, signed or not) and publish the draft.
7. [ ] Homebrew: update `version` and `sha256` in `packaging/homebrew/arbor.rb` (the `.sha256`
   file attached to the release has the checksum) and copy it to the tap (see the comments in
   that file).
8. [ ] Bump `VERSION` on `main` to the next planned version if you like to keep it ahead.

## Notes

- Notarization covers the disk image and the app inside it; the ticket is stapled to the disk image.
  An app copied out of it is checked online by Gatekeeper the first time it opens.
- Every release, ad-hoc ones included, has the hardened runtime, so `DYLD_*` variables cannot load code into Arbor; the script fails if the signature lacks it.
- After `sign-and-notarize.sh`, `build/Arbor.app` ignores `ARBOR_*`; rebuild it before running the scripted suites.
- Entitlements are intentionally empty: Arbor is not sandboxed and needs no hardened-runtime
  exceptions. Add a key only with a comment naming the feature that needs it.
- The disk image layout is written directly (`scripts/dmg-layout.swift`), not by scripting
  Finder, so it builds on CI and headless Macs. If Finder ever ignores it, `make-dmg.sh --plain`
  makes a plain image.
