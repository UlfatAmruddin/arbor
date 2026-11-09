# Cloud status (iCloud Drive and File Provider folders)

Spec: spec §13.4, FE-189–FE-198, FE-162, FE-113, FE-244. Reference: windows11-reference.md §2.1, §5.1–5.2.
Code: `Sources/Arbor/Features/Cloud/`, `Sources/ArborCore/CloudStatus.swift`.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-189 | Navigation pane: "iCloud Drive" (`~/Library/Mobile Documents/com~apple~CloudDocs`) and one node per `~/Library/CloudStorage/*` folder, after Gallery (where Explorer puts OneDrive), named "Provider – account"; root tabs and breadcrumbs use that name and a cloud icon; Go ▸ iCloud Drive (⇧⌘I) | Implemented | Unit tests (detection, naming); headless run with a test root |
| FE-190 | Status column (Name · Status · Date modified · Type · Size) in cloud folders: Available on this device / Available when online / Syncing / Sync pending / Sync conflict / Sync error / Status unknown, from `ubiquitousItem*` resource keys; glyph-only with the wording as tooltip/accessibility label | Implemented | Unit tests (`CloudStatusTests`); light/dark snapshots with test statuses |
| FE-190 | Status badge on item icons ≥ 32 pt (icon views) via `ItemBadges` in `IconProvider.icon(for:size:)` | Implemented (no icon view in this branch) | `iconpng:` step rendered a 64 pt icon with the badge |
| FE-191 | "Download to this device" (`startDownloadingUbiquitousItem`) and "Free up space" (`evictUbiquitousItem`) in the item context menu and File menu, only for items the system reports as ubiquitous; request errors shown per item, completion polled and reported from the real status | Implemented | Headless: the request on a non-provider file showed the system's error, nothing claimed |
| FE-162 | Preview pane: online-only files show "“x” is available when online" + **Download to preview**; nothing downloads on selection; progress and errors shown | Implemented | Snapshots (light/dark) |
| FE-113 | Copy (or move out of the provider) of cloud folders or online-only files asks "Download from … to copy these items?" first; moves inside one provider folder never ask | Implemented | Headless: Cancel left the destination empty |
| FE-192 | Sync errors and conflicts shown in the Status column | Partial | Provider-specific handoff not possible (see FE-244) |
| FE-193 | Share links / permissions | Not done | iCloud-only API exists (below); core Share… uses the system share sheet |
| FE-194 | Version history | Not done | `NSFileVersion` covers local/conflict versions only |
| FE-195 | Multiple accounts | Partial | Each CloudStorage folder is its own node with its account label; no auth state is readable |
| FE-196 | Home cloud recommendations | Boundary | No provider API for recommendations |
| FE-197 | iCloud Drive native state, coordinated downloads, optimized storage respected (never hydrates on browse) | Implemented | Status reads are metadata only, bounded to visible rows |
| FE-198 | File Provider domains: enumeration, status, eviction per provider | Partial | Depends on what each provider reports through the same keys; unverified on real OneDrive/Dropbox/Google Drive in this run (headless runs never touch real cloud folders) |
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
| Account identity, sign-in state, quota | None (only the folder name under `~/Library/CloudStorage`) | No | No |
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

## Testing

```bash
ROOT=$(mktemp -d); CL="$ROOT/OneDrive-Personal"; mkdir -p "$CL"; for f in a.pdf b.txt; do echo x > "$CL/$f"; done
ARBOR_HEADLESS=1 ARBOR_APPEARANCE=dark ARBOR_TEST_CLOUD_ROOT="$CL" ARBOR_TEST_CLOUD_ACCOUNT=Personal \
ARBOR_TEST_CLOUD_STATUS="a.pdf=online,b.txt=available" \
ARBOR_SCRIPT="wait:1;location:$CL;wait:1.5;select:a.pdf;click:view.previewPane;wait:1;log:$ROOT/s.txt;snapshot:$ROOT/c.png;iconpng:a.pdf:$ROOT/i.png;quit" \
  build/Arbor.app/Contents/MacOS/Arbor "$CL"
```
Status words for `ARBOR_TEST_CLOUD_STATUS`: available, online, downloading/syncing, uploading, pending, conflict, error, unknown.
The `log` step gains `cloud roots:`, `cloud folder:` (layout, columns) and `cloud statuses:`. Command ids: `cloud.download`,
`cloud.freeUpSpace`, `go.iCloudDrive`.

## Known gaps

- FE-231 covers what a place refuses, whether pressed as a button, a menu item, a key binding (F2) or a menu shortcut (⌘V, handled in `BrowserWindow.performKeyEquivalent` because a disabled menu item never sends its action). Selection-dependent limits (a drive selected in This Mac can't be copied) still grey out without a reason. New ▸ templates have no reason of their own; the New button carries it.
- Not checked against real OneDrive/Dropbox/Google Drive installs (FE-198 needs a manual audit per provider).
- Status refreshes on folder changes, on visible-row redraw after 15 s, and after Arbor's own actions; there is no live `NSMetadataQuery` subscription.
- Status column isn't sortable (no `SortKey` extension point).
- Search results and other virtual locations don't show the Status column.
- Thumbnails (icon views, another feature) may hydrate files depending on the provider's thumbnail support.
