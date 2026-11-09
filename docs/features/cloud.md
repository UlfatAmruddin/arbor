# Cloud status (iCloud Drive and File Provider folders)

Spec: spec §13.4, FE-189–FE-198, FE-162, FE-113, FE-244. Reference: windows11-reference.md §2.1, §5.1–5.2.
Code: `Sources/Arbor/Features/Cloud/`, `Sources/ArborCore/CloudStatus.swift`, `CloudProviders.swift` (provider table, folder names), `CloudProviderError.swift`, `CloudCapabilityProbe.swift`.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-189 | Navigation pane: "iCloud Drive" (`~/Library/Mobile Documents/com~apple~CloudDocs`) and one node per `~/Library/CloudStorage/*` folder, after Gallery (where Explorer puts OneDrive), named "Provider – account"; root tabs and breadcrumbs use that name and a cloud icon; Go ▸ iCloud Drive (⇧⌘I) | Implemented | Unit tests (detection, naming); headless run with a test root |
| FE-190 | Status column (Name · Status · Date modified · Type · Size) in cloud folders: Available on this device / Available when online / Syncing / Sync pending / Sync conflict / Sync error / Status unknown, from `ubiquitousItem*` resource keys; glyph-only with the wording as tooltip/accessibility label | Implemented | Unit tests (`CloudStatusTests`); light/dark snapshots with test statuses |
| FE-190 | Status badge on item icons ≥ 32 pt (icon views) via `ItemBadges` in `IconProvider.icon(for:size:)` | Implemented (no icon view in this branch) | `iconpng:` step rendered a 64 pt icon with the badge |
| FE-191 | "Download to this device" (`startDownloadingUbiquitousItem`) and "Free up space" (`evictUbiquitousItem`) in the item context menu and File menu, only for items the system reports as ubiquitous; request errors shown per item, completion polled and reported from the real status | Implemented | Headless: the request on a non-provider file showed the system's error, nothing claimed |
| FE-162 | Preview pane: online-only files show "“x” is available when online" + **Download to preview**; nothing downloads on selection; progress and errors shown | Implemented | Snapshots (light/dark) |
| FE-113 | Copy (or move out of the provider) of cloud folders or online-only files asks "Download from … to copy these items?" first; moves inside one provider folder never ask | Implemented | Headless: Cancel left the destination empty |
| FE-192 | Sync errors and conflicts in the Status column, with the provider's own failure text from the download and upload error keys in the tooltip as plain text. **Open <Provider>** on items in error or conflict, only when that app is installed, from one fixed table; iCloud Drive opens its settings pane | Implemented; not seen on a real provider | Unit tests (table, error mapping, hostile text); `behavior-checks.sh cloudproviders` with simulated providers |
| FE-195 | Each CloudStorage folder is its own node labelled Personal, Work/School or Account unknown (node and tooltip), from the folder name only. Sign-in need comes from real error codes only, and shows **Sign in to <Provider>** on the node's tooltip, tree and item menus, and when the root can't be listed | Implemented; not seen on a real provider | Unit tests (parser with hostile and odd names, codes); `behavior-checks.sh cloudproviders` |
| FE-197 | iCloud Drive native state, coordinated downloads, optimized storage respected (never hydrates on browse) | Implemented | Status reads are metadata only, bounded to visible rows |
| FE-198 | Per-provider probe of which status keys that provider answers and whether listing worked, from metadata already read for visible rows; one read-only line in the node's tooltip; Download and Free up space say why when the probe shows they can't work | Partial: the probe is implemented and checked on simulated providers; a real OneDrive, Dropbox or Google Drive has never been observed. Eviction can't be probed without doing it | Unit tests (`CloudCapabilityProbeTests`); `behavior-checks.sh cloudproviders`; manual list below not yet run |
| FE-244 | Which provider capabilities a third-party browser can use | Documented below | API research |
| FE-231 | Unsupported actions are explained, for every provider | Implemented | `ProviderCapabilityMatrixTests` (every provider and action: a command runs exactly where the provider gives no reason; every reason is in the string table; greyed commands stay listed; a network share both connected and dropped, driven by the fake network), `VolumeCapabilityMatrixTests`, `behavior-checks.sh capabilities` |

## FE-244: what an unrelated app (Arbor) can actually do

| Capability | Public API available to Arbor | iCloud Drive | Other File Provider domains (OneDrive, Dropbox, Google Drive, Box…) |
|---|---|---|---|
| Enumerate | Plain directory listing (placeholders are "dataless" files) | Yes | Yes |
| Read status | `URLResourceKey.ubiquitousItemDownloadingStatusKey`, `…IsDownloadingKey`, `…IsUploadingKey`, `…IsUploadedKey`, `…DownloadingErrorKey`, `…UploadingErrorKey`, `…HasUnresolvedConflictsKey`, `isUbiquitousItemKey` | Yes | Yes for replicated (FileProvider) domains, as reported by the system; missing keys → "Status unknown" |
| Download now | `FileManager.startDownloadingUbiquitousItem(at:)`; also any coordinated read (open, Quick Look) | Yes | Yes (system materializes the item) |
| Free up space | `FileManager.evictUbiquitousItem(at:)` | Yes (fails for items not yet uploaded) | Yes when the provider allows eviction; errors are passed through |
| **Pin ("Always keep on this device")** | **None.** Keep-downloaded policy is set by the provider (`NSFileProviderContentPolicy`) or Finder; `NSFileProviderManager` only manages an app's *own* domains | No | No |
| Provider badges / custom actions (`NSFileProviderItemDecorating`, `NSFileProviderCustomAction`) | Finder only | No | No |
| Share link | `FileManager.url(forPublishingUbiquitousItemAt:expiration:)` (read-only public link) | Yes | No |
| Sharing state | `ubiquitousItemIsSharedKey`, `…SharedItemCurrentUserRoleKey`, `…PermissionsKey` | Yes | Provider-dependent |
| Conflicts / versions | `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`, `otherVersionsOfItem(at:)` | Conflict versions yes; full cloud history no | Provider-dependent; full history no |
| Account identity, quota | None (only the folder name under `~/Library/CloudStorage`) | No | No |
| Sign-in state | No query exists; only a not-signed-in code in the error keys above or from listing the root | When reported | When reported |
| Cancel a running download | None (no public cancel) | No | No |

## Decisions

- **DEC-cloud-1** Windows' "Always keep on this device" is offered as **"Download to this device"**: macOS gives third-party apps no pin API, so promising "always" would be false (DEC-019). "Free up space" keeps Windows' wording.
- **DEC-cloud-2** Status is never guessed: anything the keys don't establish (including items the system doesn't report as ubiquitous) is "Status unknown". Errors win over conflicts, then transfers, then download state.
- **DEC-cloud-3** iCloud Drive's node points at `com~apple~CloudDocs` (the user's iCloud Drive files); app containers elsewhere in `Mobile Documents` are not merged in.
- **DEC-cloud-4** The Status column shows the glyph only (Explorer style); wording is in the tooltip and accessibility label. Glyphs are SF Symbols in our colors (DEC-018).
- **DEC-cloud-5** Copying cloud **folders** always asks before starting, because whether they contain online-only files can't be known without a recursive scan (spec §15.3). Files ask only when known online-only.
- **DEC-cloud-6** The preview gate wraps the "preview" pane whenever one is created (`SidePaneRegistry.wrappers`, contribution `cloud.preview-gate`; archive member previews wrap it from outside, DEC-024).
- **DEC-cloud-7** Status reads are batched on a background queue for displayed rows only, cached (4,000 entries, 15 s freshness) and only redraw when a value changes.
- **DEC-cloud-8** Headless runs never read real cloud folders: only `ARBOR_TEST_CLOUD_ROOT` is used, with statuses from `ARBOR_TEST_CLOUD_STATUS`.
- **DEC-cloud-9** Every `LocationProvider` must implement `limitation(of:in:)` (no default): cloud roots forward to the folder provider underneath, so a cloud folder allows what a folder allows and a job failure there is explained by that failure. Context menus still leave out what can't run (`MenuAudit`); the command bar keeps it greyed with the reason as its tooltip, and pressing the key shows the reason in the status bar.

- **DEC-cloud-10** The hand-off takes a row of one fixed table (`CloudProviderCatalog`), so no folder name or path can reach a launch, and a prefix must match as a whole word. Bundle identifiers are listed only where a public source confirmed them (OneDrive's two editions, Google Drive, Dropbox, Box); the other providers keep their display name and offer no hand-off.
- **DEC-cloud-11** An account is labelled only from what its folder name documents: OneDrive and Dropbox say "Personal" or the organization's name; a Google address says Personal only on a consumer-only mail domain (gmail.com, googlemail.com), since Workspace can't own those. Everything else is "Account unknown". iCloud Drive has no folder name to read, so it has no label.
- **DEC-cloud-12** Sign-in need is read from error codes (`NSFileProviderError.notAuthenticated`, the URL loading system's two authentication codes, including when wrapped), never from an error's wording, which is provider-written and translated.
- **DEC-cloud-13** The probe adds no reads. It observes the metadata the status store already fetched for displayed rows and the listing the window already asked for, so it can't hydrate anything or wake a provider the user isn't browsing. Each item counts once, the provider's own top folder doesn't count, and commands are blocked only after three items. Error keys are empty on a healthy item, so their absence is never called unsupported.
- **DEC-cloud-14** A probe lasts five minutes from its first observation, is dropped when the set of roots changes, and a sign-in failure is dropped when Arbor becomes active again, since the user may have just signed in.
- **DEC-cloud-15** A probe change redraws the provider's own row in place (`NavigationPaneExtras.updateRoot`). Ordinary browsing changes the probe, so a rebuild there would collapse the tree in every window; only a change in the set of roots rebuilds it.

## What has and hasn't been seen on a real provider

None of OneDrive, Dropbox or Google Drive was installed on the Mac this was built on, so none has been observed. Everything in FE-192, FE-195 and FE-198 above has run against simulated providers and disposable folders only. iCloud Drive is read by the same code, but no headless run reaches it; its settings pane address comes from the scene name in the system's own settings extension, and it hasn't been opened. The folder name forms come from public descriptions of those products, and the sign-in codes from Apple's API documentation; whether a given provider really sets them is unknown until the list below is run.

### Manual verification (once per installed provider)

Run in a normal build, with the provider signed in, on files you can afford to re-download.

1. Navigation pane: the node shows the expected name and Personal, Work/School or Account unknown. Note the real folder name in `~/Library/CloudStorage` if the label is wrong.
2. Hover the node before opening it: "hasn't been checked yet". Open it, hover again: "Listing works" and a list of what it reports.
3. Check that the Status column shows real states, and that browsing downloads nothing (the file stays online-only in Finder).
4. File ▸ Download to this device and Free up space on an online-only and a local file: each works, or explains itself.
5. Cause a failure the provider reports (fill the quota, or pause sync and edit a file offline until it errors): the Status tooltip shows the provider's text, and the item's menu offers **Open <Provider>**, which opens the app.
6. Create a conflict by editing the same file in two places: the Status column says Sync conflict and offers the same command.
7. Sign out in the provider's app, then reopen the node: the tooltip and menus say **Sign in to <Provider>** and the command opens the app. If they don't, record what the Status tooltip says. Sign back in and return to Arbor: the message clears.
8. With two accounts of one provider, each has its own node and label.
9. iCloud Drive: on an item in error or conflict, **Open iCloud Settings** lands on the iCloud page of System Settings.

Record the provider, its version and the results here.

## Testing

```bash
ROOT=$(mktemp -d); CL="$ROOT/OneDrive-Personal"; mkdir -p "$CL"; for f in a.pdf b.txt; do echo x > "$CL/$f"; done
ARBOR_HEADLESS=1 ARBOR_APPEARANCE=dark ARBOR_TEST_CLOUD_ROOT="$CL" ARBOR_TEST_CLOUD_ACCOUNT=Personal \
ARBOR_TEST_CLOUD_STATUS="a.pdf=online,b.txt=available" \
ARBOR_SCRIPT="wait:1;location:$CL;wait:1.5;select:a.pdf;click:view.previewPane;wait:1;log:$ROOT/s.txt;snapshot:$ROOT/c.png;iconpng:a.pdf:$ROOT/i.png;quit" \
  build/Arbor.app/Contents/MacOS/Arbor "$CL"
```
Status words for `ARBOR_TEST_CLOUD_STATUS`: available, online, downloading/syncing, uploading, pending, conflict, error, `error:<text>` (a provider's failure text, through the real mapping), unknown.

Simulated providers, all ignored by distribution builds and used only with test roots:

| Variable | Does |
|---|---|
| `ARBOR_TEST_CLOUD_STORAGE=<folder>` | each folder inside stands in for one under `~/Library/CloudStorage`, read by the real name parser |
| `ARBOR_TEST_CLOUD_KEYS=ubiquitous,download,downloading,uploading,uploaded,conflicts` | the keys a simulated provider answers on rows with no test status; `none` answers nothing, `signin` adds a not-signed-in failure |
| `ARBOR_TEST_CLOUD_ROOT_ERROR=signin\|failed` | how listing a test root fails |
| `ARBOR_TEST_INSTALLED_APPS=<id,id>` | in a headless run, the whole list of installed apps |

`scripts/behavior-checks.sh cloudproviders` runs them. The `log` step gains `cloud node:` (title and the tooltip of the real tree cell), `cloud icon:` (whether that cell's icon matches the probe), `cloud marked:` (the marked tree row), `cloud capability:`, `cloud status text:` and `cloud refusals:`.
The `log` step gains `cloud roots:`, `cloud folder:` (layout, columns) and `cloud statuses:`. Command ids: `cloud.download`,
`cloud.freeUpSpace`, `cloud.openProvider`, `go.iCloudDrive`.

## Known gaps

- FE-231 covers what a place refuses, whether pressed as a button, a menu item, a key binding (F2) or a menu shortcut (⌘V, handled in `BrowserWindow.performKeyEquivalent` because a disabled menu item never sends its action). Selection-dependent limits (a drive selected in This Mac can't be copied) still grey out without a reason. New ▸ templates have no reason of their own; the New button carries it.
- Not checked against real OneDrive/Dropbox/Google Drive installs: see "What has and hasn't been seen". Proton Drive, Synology Drive, pCloud, Nextcloud, MEGA, Icedrive and SharePoint have no hand-off until a bundle identifier is confirmed.
- Whether eviction works can't be read as metadata; Free up space still tries and shows the provider's refusal per item.
- A root's sign-in need is only learned once the root or something in it has been opened; Arbor doesn't wake a provider the user isn't browsing. Signing out of a provider isn't noticed until then, nor while a healthy result is still within its five minutes.
- A listing failure below a root is shown as that failure; only the root's listing is recorded by the probe.
- Status refreshes on folder changes, on visible-row redraw after 15 s, and after Arbor's own actions; there is no live `NSMetadataQuery` subscription.
- Status column isn't sortable (no `SortKey` extension point).
- Search results and other virtual locations don't show the Status column.
- Thumbnails (icon views, another feature) may hydrate files depending on the provider's thumbnail support.
