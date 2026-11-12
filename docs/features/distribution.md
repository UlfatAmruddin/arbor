# Distribution: download, signing and project governance

Spec: FE-220 (signed, notarized universal releases), FE-221 (public open-source governance).
Decisions: DEC-003 (macOS 14+), DEC-004 (direct download, Developer ID + notarization), DEC-005 (MIT).
Files: `VERSION`, `scripts/build-app.sh`, `scripts/make-dmg.sh`, `scripts/dmg-layout.swift`,
`scripts/sign-and-notarize.sh`, `scripts/ci-import-certificate.sh`, `Resources/Arbor.entitlements`, `.github/workflows/`,
`packaging/homebrew/arbor.rb`, `docs/RELEASING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/`,
`.github/pull_request_template.md`, `CONTRIBUTING.md`, README "Install".

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-220 | Universal app (arm64 + x86_64) with Command Line Tools only | Implemented (`build-app.sh --universal`) | `lipo -info`: x86_64 arm64. Both slices launched headless (`arch -arm64` / `arch -x86_64` under Rosetta) and listed a fixture folder; x86_64 snapshot checked |
| FE-220 | One minimum macOS (14.0) everywhere | Implemented | Read from `Package.swift`, stamped into `LSMinimumSystemVersion`, used in the build triples; the build fails if `vtool` reports another `minos` for any slice (both report 14.0) |
| FE-220 | Single version source, build number, About panel | Implemented | `VERSION` → `CFBundleShortVersionString`; commit count → `CFBundleVersion` (0.2.0, build 67 at the time of writing); the standard About panel shows both |
| FE-220 | Disk image with Applications link, drawn background, window layout | Implemented | Built, `hdiutil verify`, mounted privately (`-nobrowse`) and checked: app, `/Applications` link, version, signature, `.DS_Store`, Retina background TIFF, custom volume icon flag. `.DS_Store` read back with an independent parser (allocator, sorted records, plists). **Not checked:** how Finder draws the window, because that needs Finder on screen |
| FE-220 | Developer ID signing with hardened runtime, notarization, stapling | Implemented, not used: no Developer ID by decision (DEC-027) | Ad-hoc path run end to end; an unknown identity fails early with a clear message; the hardened runtime with `Arbor.entitlements` (ad-hoc) launches both slices |
| FE-220 | CI on every push and pull request | Running | `ci.yml`'s three jobs (build and unit tests, app checks, performance budgets) have run on GitHub's `macos-26` hosted runner since the repository went public; the runner tolerances in `ci.yml` come from those runs |
| FE-220 | Tagged releases | Implemented, **has never run** | `release.yml` runs only for a `v*` tag and none exists. YAML parsed, every `run:` block checked with `bash -n`; actions pinned to exact versions |
| FE-220 | Homebrew cask | Template | `ruby -c`; needs a real sha256 per release and a tap (see the file) |
| FE-221 | License, build instructions, contribution guide, security policy, issue and PR templates | Implemented | MIT `LICENSE` (existing), README Install, CONTRIBUTING, SECURITY, templates |
| FE-221 | Roadmap | Partial | `docs/FEATURE-STATUS.md` serves as the roadmap; no separate file |

## Decisions

- **DEC-distribution-1** The universal binary is built per architecture (`--triple <arch>-apple-macosx14.0`) and joined with `lipo`, because `swift build --arch arm64 --arch x86_64` requires full Xcode. Same result, works on Command Line Tools and CI.
- **DEC-distribution-2** `VERSION` holds `MAJOR.MINOR.PATCH` (Apple's version string allows only numbers). The build number is the commit count so it always increases on `main`; CI checks out full history for it. Started at 0.2.0 to match the README's "v0.2 foundation".
- **DEC-distribution-3** The minimum macOS is defined once, in `Package.swift`; the build reads it from there.
- **DEC-distribution-4** Disk image: LZFSE-compressed (ULFO, needs macOS 10.11+, smaller than zlib) with `--format UDZO` available; HFS+ volume named "Arbor".
- **DEC-distribution-5** The Finder window layout is written directly as a `.DS_Store` (plus a classic alias record and a bookmark for the background picture), instead of scripting Finder with AppleScript. Scripting Finder needs a logged-in session, opens windows and asks for Automation permission, so it doesn't work headless or reliably on CI. `--plain` remains as a fallback.
- **DEC-distribution-6** Entitlements are empty: Arbor is not sandboxed (DEC-004), and `com.apple.security.network.client` only applies to sandboxed apps, so SMB, Bonjour and helper tools need nothing. No hardened-runtime exceptions are used, except library validation in ad-hoc releases, for Sparkle (DEC-028, `Resources/Arbor-adhoc.entitlements`).
- **DEC-distribution-7** Without signing credentials every script still succeeds and produces an ad-hoc signed image, printing what to do next. Release builds without secrets are labeled unsigned in the release notes.
- **DEC-distribution-8** The release workflow creates a **draft** release, so a maintainer checks the download before publishing.
- **DEC-distribution-9** Vulnerabilities are reported through GitHub's private vulnerability reporting (no email address is published); it has to be turned on in the repository settings.
- **DEC-distribution-10** CI uses the `macos-26` runner so it compiles with the same Swift version (6.2+) the project is developed with.
- **DEC-distribution-11** Removed by DEC-027: CI no longer rehearses Developer ID signing.
- **DEC-distribution-12** The release workflow imports a Developer ID, if one is ever set, through `scripts/ci-import-certificate.sh`. The script refuses to run outside a GitHub-hosted runner, because it replaces the keychain search list.

## Known gaps

- Finder's rendering of the disk image window (background, icon positions, window size) has not been seen; check it once by opening the image (RELEASING.md, step 3).
- Releases are ad-hoc signed (DEC-027): Developer ID signing, notarization and stapling never run, and macOS asks once on first launch. The release workflow has never run either.
- The release notes say "Signed with a Developer ID and notarized" whenever `DEVELOPER_ID_CERTIFICATE_P12` is set, even if the other secrets are missing. RELEASING.md requires all six.
- No in-app update mechanism (none planned; Homebrew or a new download updates the app).
