# In-app updates

Spec: FE-259 ("Proposed improvement"). Reference: none; File Explorer is updated by Windows Update, so nothing here
claims parity. Decision: DEC-028 in [DECISIONS.md](../DECISIONS.md).
Code: `Sources/ArborCore/Updates/` (configuration, button state, release notes, feed), `Sources/Arbor/Features/Updates/`
(Sparkle, the button, the menu item, the switch), `Sources/ArborAppcast/` (the release tool), `scripts/make-update.sh`,
`scripts/update-e2e.sh`, `scripts/lib/codesign-app.sh`.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-259 | A quiet **Update** button at the right end of the tab row of every window when a daily check finds a newer release; its tooltip names the version | Implemented | `behavior-checks.sh updates`, `update-e2e.sh` (scenario 1) |
| FE-259 | The button opens Sparkle's update window with the release notes and **Install Update**, then **Install and Relaunch**; Arbor is replaced in place and starts again | Implemented | `update-e2e.sh` (scenario 1, on this Mac, outside /Applications) |
| FE-259 | Arbor ▸ Check for Updates… and "Check for updates automatically" in Settings (Folder Options ▸ General) | Implemented | `update-e2e.sh` (present with a feed), `behavior-checks.sh updates` (absent without one) |
| FE-259 | Only signed updates install: the feed and the zip both carry an EdDSA signature checked against the key inside the running app | Implemented | Unit tests (`UpdatesTests.swift`), `update-e2e.sh` (scenarios 2 and 3 are refused) |
| FE-259 | No system profiling; nothing is sent but the feed request; no updater at all in builds without a feed, or in headless runs | Implemented | Info.plist, unit tests, `behavior-checks.sh updates` |
| FE-259 | Keyboard: F6 to the tab row, then arrows or End reach the button; VoiceOver reads "Update to Arbor 0.4.0" and the tooltip as help; light, dark, increased contrast and right to left follow Theme | Implemented | `behavior-checks.sh updates`, snapshots |

## What testers see

- About once a day Arbor asks the release feed whether there is a newer version: a few seconds after it opens
  when a day has passed since the last check (and at once on its very first run), then daily. When there is,
  a small **Update** pill appears at the right end of the tab row, in every window. Nothing pops up.
- Clicking it (or pressing it from the keyboard) opens the update window: what's new in that version, then
  **Install Update**. Arbor downloads the update, checks its signature and offers **Install and Relaunch**. Arbor
  quits, the new version replaces it where it is, and it opens again. "Remind Me Later" and "Skip This Version"
  work as their names say; the pill goes away and the daily check brings it back for a newer release.
- Arbor ▸ Check for Updates… checks at once and always shows the result in a window.
- Settings (Arbor ▸ Settings…, General page, **Updates**) has "Check for updates automatically", with a note saying
  what it does. It takes effect at once, like Clear history, rather than with OK or Apply. Turned off, Arbor never
  checks on its own.
- If files are being copied when Install and Relaunch is pressed, Arbor's usual quit question comes first.
- Sparkle's windows follow the language macOS is set to when Sparkle has it, so they may not be in English while
  Arbor is (DEC-026).

### After an update

- Releases are ad-hoc signed (DEC-027), so each version is a new identity to macOS: permissions given to the previous
  version, such as **Full Disk Access** or access to Desktop, Documents, Downloads, removable drives and network
  volumes, may be asked for again, or need turning on again in System Settings ▸ Privacy & Security.
- Versions released before the updater (0.3.1 and older) have no updater: install the first version that has one
  by hand from the disk image. Later versions update themselves.

## How it works

- [Sparkle 2](https://github.com/sparkle-project/Sparkle) (MIT, THIRD-PARTY-NOTICES.md), the first external
  dependency, pinned to an exact version in `Package.swift` and `Package.resolved`. SwiftPM downloads its binary
  framework and checks it against the checksum in Sparkle's own package manifest. `scripts/build-app.sh` copies
  `Sparkle.framework` into `Contents/Frameworks` with `ditto` (its symlinks matter), adds the
  `@executable_path/../Frameworks` rpath, copies the notices into `Contents/Resources`, and signs inside out:
  Sparkle's XPC services, `Updater.app` and `Autoupdate`, the framework, then the app (`scripts/lib/codesign-app.sh`;
  never `--deep`). `scripts/sign-and-notarize.sh` signs the same way with the hardened runtime, and checks that every
  one of them has it.
- **The feed** is `appcast.xml`, an asset of each GitHub release, read from
  `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`. "latest" only moves when the owner
  publishes a draft, so testers never see a draft. The owner and repository are never written in the tree: the
  Release workflow passes `${{ github.repository }}` to `scripts/build-app.sh`, which writes `SUFeedURL` and the
  public key (`SUPublicEDKey`, from the `SPARKLE_ED_PUBLIC_KEY` repository variable) into the built Info.plist.
- **The update** is `Arbor-<version>.zip`, made by `ditto -c -k --sequesterRsrc --keepParent` from the app in the
  disk image. A zip rather than the disk image: Sparkle unpacks it without mounting anything, `ditto` keeps the
  framework's symlinks, and the disk image stays the download for a first install.
- **The feed's one item** (`scripts/make-update.sh`, `ArborAppcast`, logic in `ArborCore/Updates`):
  `sparkle:version` is CFBundleVersion (the commit count), `sparkle:shortVersionString` is `VERSION`,
  `sparkle:minimumSystemVersion` is LSMinimumSystemVersion (14.0), the enclosure is the zip on this release's tag
  with its length and EdDSA signature, and the description is this version's CHANGELOG.md section as HTML:
  `###` headings, `- ` bullets and backtick code; every `&`, `<`, `>`, `"` and `'` escaped, everything else
  (links, emphasis, HTML) shown as written, and the whole escaped again as XML text. Before the feed is written,
  the zip's signature is checked against the app's `SUPublicEDKey`, so a key pair that doesn't match fails the
  release instead of every tester's update. Then `sign_update` signs the feed itself.
- **In the app** (`UpdatesFeature.plan`, decided once at launch): an updater exists only when Info.plist has a
  valid https feed and a 32-byte public key, and the run isn't headless or scripted. It starts two seconds after the
  first window, so launch and the bench budgets don't change. A scheduled check that finds an update goes through
  Sparkle's gentle reminders: `standardUserDriverShouldHandleShowingScheduledUpdate` answers no, so Sparkle shows no
  window and Arbor shows the pill; `standardUserDriverDidReceiveUserAttention` and
  `standardUserDriverWillFinishUpdateSession` take it away. Clicking the pill calls `checkForUpdates()`, which brings
  that update into view.

### Info.plist

| Key | Value | Why |
|---|---|---|
| `SUFeedURL`, `SUPublicEDKey` | written by `build-app.sh` only when both are given | No feed, no updater |
| `SUEnableAutomaticChecks` | YES | Checks are on without asking; the Settings switch turns them off |
| `SUScheduledCheckInterval` | 86400 | About once a day |
| `SUAutomaticallyUpdate`, `SUAllowsAutomaticUpdates` | NO | The user clicks; Sparkle never offers silent installs |
| `SUEnableSystemProfiling` | NO | No system profile is ever sent |
| `SURequireSignedFeed` | YES | A feed without a valid signature is refused |
| `SUVerifyUpdateBeforeExtraction` | YES | The zip's signature is checked before anything is unpacked |

## Privacy and security

- The only request is an HTTPS GET of the feed, and of the zip when the user installs. Sparkle adds no profile
  (`SUEnableSystemProfiling` is off); the request's headers name only the app, its version and Sparkle's version.
- Debug and local builds, CI builds, forks without the setup, and every headless or scripted run have no updater and
  make no request. In debug builds only, `ARBOR_UPDATE_FEED=<url>` points a scripted run at a test feed (plain http
  is allowed only to this Mac); release builds don't contain that code (`#if DEBUG`), and distribution builds ignore
  `ARBOR_*` anyway.
- Version text from the feed reaches the pill only when it is short and plain (letters, digits, `.-+()` and spaces);
  otherwise the tooltip doesn't name a version.
- The private key never leaves the `SPARKLE_ED_PRIVATE_KEY` secret: the workflow pipes it to `make-update.sh`, which
  hands it to `sign_update` on standard input. It is never echoed, written to a file or passed as an argument.
- An ad-hoc signature has no Team ID, and library validation only loads code from the app's own team, so ad-hoc
  releases carry `com.apple.security.cs.disable-library-validation` (`Resources/Arbor-adhoc.entitlements`) to load
  Sparkle. DYLD_* variables stay blocked by the hardened runtime. A Developer ID release would sign Sparkle with the
  same team and use `Resources/Arbor.entitlements`, without the exception (DEC-028).

## Checks

- `scripts/test.sh`: `UpdatesTests.swift` (configuration, the button's state, version text from the feed, changelog
  sections, HTML and XML escaping, the feed's fields, signatures).
- `scripts/behavior-checks.sh updates` drives the pill with `updatestate:available:<version>`, `updatestate:available`
  and `updatestate:none` at a pinned 720 × 520 window with seven tabs: it shows and hides, its tooltip and VoiceOver
  label, no overlap with tabs or New tab while the row overflows, End in the tab row reaches it; without a feed there
  is no menu item or Settings switch; a copy with a feed, a key and a test feed still has no updater headless.
  `log:` adds `updates:` (updater state, menu item, Settings switch) and `update button:` lines.
- `scripts/update-e2e.sh` (not in CI: it shows windows) builds an older and a newer ad-hoc signed copy with a
  throwaway key in a temporary folder and serves the feed from 127.0.0.1. Script steps: `updatecheck` (as the user),
  `updatepill` (presses the button), `updatepress:<title>` (a button in Sparkle's windows); `log:` counts Sparkle's
  windows (`windows=`). Results of the runs on 2026-11-11 (Apple silicon, macOS 26): the scheduled check due on a
  first launch showed the pill naming the version and opened no window; pressing the pill opened Sparkle's window
  and the pill went; Install Update and Install and Relaunch replaced the older copy in place (build 100 → 200), the
  new one started, and its signature verified. The menu item and the Settings switch (on) were there.
  A zip signed with another key, in a correctly signed feed, was downloaded and refused before unpacking
  ("(Ed)DSA signature validation before unarchiving failed"); a feed signed with another key was refused before any
  download. The older copy stayed as it was in both.

## Decisions

- **DEC-updates-1** The pill is a `ChromeButton` with a resting fill (`Theme.toggled`), an accent icon and the
  primary text color, so it is visible in every theme without competing with the tabs. It lives in the tab strip's
  trailing slot (`TabStripView.trailingAccessory`), which the tabs' width leaves room for.
- **DEC-updates-2** Without an update there is no pill view at all, so VoiceOver and the keyboard never meet a
  hidden button.
- **DEC-updates-3** The Settings switch is bound to Sparkle's own setting (kept in Arbor's user defaults by Sparkle)
  and applies at once; it is not part of the Folder Options draft that OK and Apply commit.
  It reaches the dialog through `FolderOptionsWindowController.generalGroups`.
- **DEC-updates-4** The public key comes from a repository variable, not the committed Info.plist, so the feed and
  its key always travel together and a fork or local build without them has no updater. The release fails if only
  one of the secret and the variable is set.
- **DEC-updates-5** Scripted runs start the updater only for a debug build's test feed, so no check suite ever
  reaches the network.

## Known gaps

- Installing into `/Applications` itself isn't covered by the end-to-end check (it runs in a temporary folder). macOS
  App Management may ask the user to allow the replacement there; Sparkle then shows that request.
- The install itself ran with arm64 debug copies. A universal release build with a feed and a throwaway key was
  built, signed by `sign-and-notarize.sh`, packaged by `make-dmg.sh` (its checks passed) and given its zip and
  signed feed by `make-update.sh`, and both of its slices started with Sparkle loaded (x86_64 under Rosetta).
- The Release workflow's update steps run for the first time on the first release after the owner sets up the key
  (docs/RELEASING.md); read its log then.
