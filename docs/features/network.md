# Network (FE-014, FE-078, FE-176–FE-179, FE-187, FE-188)

Code: `Sources/Arbor/Features/Network/`, core logic in `Sources/ArborCore/NetworkAddress.swift`, `MappedDrives.swift`,
`NetworkDiscovery.swift`, `SlowWork.swift` (tests: `Tests/ArborCoreTests/NetworkTests.swift`).

## Status

| FE | Requirement | Status | How verified |
|---|---|---|---|
| FE-014 | `\\server\share` and `smb://` in the address bar | **Implemented.** Connects (mounts) asynchronously, then navigates into the mount; `\\server` alone opens the server's share list; editing the address of a network folder shows `\\server\share\folder`. ⌘K "Connect to Server…" now ends here too | Unit tests (PathResolver, NetworkAddress); headless `address:\\OFFICE-PC\Public` |
| FE-078 | Network page | **Implemented.** Bonjour (`NWBrowser`: `_smb._tcp`, `_afpovertcp._tcp`, `_airport._tcp`) grouped like Explorer: "Computer", "Network Infrastructure", plus "Network locations" (connected shares and mapped drives). Discovery runs only while the page is open. Local Network denied → Explorer-style banner "Network discovery is turned off." with Open Settings | Headless with fake network, light/dark snapshots; `ARBOR_FAKE_NETWORK_DENIED=1` banner |
| FE-176 | Discovery, sign-in, mounting are separate | **Implemented.** Discovered name → DNSServiceResolve → server page lists shares (`smbutil view -N`, Keychain only, never prompts) → opening a share mounts it with `NetFSMountURLAsync` (system sign-in prompt, cancellable, timeout) → tab shows the mount. AFP / sign-in-required servers offer **Connect…** (system share chooser) | Fake network headless; live paths compile but were not run against a real server |
| FE-177 | Map / Disconnect network drive | **Implemented.** "…" on This Mac / Network, nav-pane context menu on This Mac and Network, Go ▸ Map Network Drive…. Dialog: Drive row explains there are no drive letters; Folder (`\\server\share` or `smb://`, suggestions, Browse… lists computers then shares), Reconnect at sign-in, Connect using different credentials, Finish/Cancel (Cancel first stops a running attempt). Mapping record = server + share + account + volume UUID; drives listed in This Mac "Network locations" and the nav pane even when disconnected (red-cross icon, "Disconnected", open/Reconnect). Disconnect network drive: selected drive, or Explorer's "Disconnect Network Drives" list; busy volume → explanation + "Disconnect Anyway" (forced unmount). Disconnect removes the mapping, like Explorer. Reconnect at launch (silent, Keychain only) and once after a mapped drive vanishes without the user disconnecting it | Headless: map, validation, auth error → different credentials, busy → force, list dialog, drop → auto-reconnect |
| FE-178 | Credentials in Keychain only | **Implemented.** Arbor never sees passwords: the system NetFS prompt asks and offers to save to the Keychain; passwords in pasted URLs are discarded before anything is stored or logged | Unit test (`passwordsAreNeverKept`) |
| FE-179 | Offline / slow shares | **Implemented.** Network folders list off the main thread with a deadline (`ARBOR_NETWORK_TIMEOUT`, default 15 s): "isn't responding" page with Retry, other tabs stay usable, a late answer replaces the page by itself; retries join the hung read instead of piling up threads. Server share lists time out with Retry. A share that disappears puts every tab inside it on a "disconnected" page (Reconnect / Go to This Mac) that returns by itself once the share is back. Chevron menus on network folders read with a 1 s cap | `SlowWorkQueue` unit tests (artificially slow work); headless with `SLOW-NAS` (4 s listing) and `OFFLINE-PC` |
| FE-187 | Same share name on two servers | **Implemented.** Identity = scheme + host + port + share (+ account when both known), or volume UUID when both sides have one; never the volume/display name | Unit tests (two "Public" shares mounted as Public / Public-1) |
| FE-188 | File system capabilities | **Partial.** `FileSystemCapabilities` (APFS, HFS+, exFAT, FAT32 4 GB limit, NTFS read-only, SMB/AFP/NFS/WebDAV, notes) is unit-tested and available via `NetworkCenter.capabilities(of:)`; not yet shown in Properties (other feature) | Unit tests |

## Decisions

| ID | Decision | Alternatives | Reason |
|---|---|---|---|
| DEC-network-1 | No drive letters; the Drive row of Map Network Drive explains where the drive appears; labels are `share (\\server)` | Fake letters | DEC-019; macOS mounts have no letters |
| DEC-network-2 | "Reconnect at sign-in" = reconnect when Arbor starts (silently, Keychain only); unticked = session-only mapping, dropped at next launch | Add a login item | Arbor shouldn't install login items on its own; Explorer's unticked mapping is also session-only |
| DEC-network-3 | Disconnect removes a mapped drive's mapping | Keep it as "disconnected" | Explorer behaviour; vanished (not user-disconnected) drives stay listed as Disconnected |
| DEC-network-4 | A `.server(share)` location is never committed to history: it connects, then the tab visits the mounted folder (tab-safe) | Show the share as its own location | Back must not re-run a connection; all folder features (search, details, rename) keep working on the real mount |
| DEC-network-5 | Share lists via `/usr/bin/smbutil view -N` (arguments array, no shell) | Private SMBClient framework | Public tool, never prompts; NetFS has no public share enumeration |
| DEC-network-6 | Editing the address of a network folder shows its UNC path | POSIX `/Volumes/…` path | Explorer parity; UNC round-trips through the address bar |
| DEC-network-7 | Map Network Drive errors show inline in the dialog; address-bar/tile failures use an alert with Retry (and Use Different Credentials… after a sign-in failure) | Always alerts | Keeps the dialog's typed folder; Explorer shows a failure dialog |
| DEC-network-8 | "Add a network location" (FTP/WebDAV wizard) and the dialog's "Connect to a Web site…" link are omitted | Placeholder buttons | DEC-019: not built; WebDAV mounts can still be typed as addresses later |

## Testing

`ARBOR_FAKE_NETWORK=1` (or a root path) replaces NetFS/Bonjour/smbutil with folders: `NAS-01` (Media, Backups, Public),
`OFFICE-PC` (Projects, Public), `SLOW-NAS` (4 s listings), `OFFLINE-PC` (never answers), `LOCKED-NAS` (needs different
credentials), `OLD-MAC` (AFP), `Base Station` (infrastructure). Behaviour per server: `<root>/<server>/.arbor-fake.json`.
`ARBOR_FAKE_NETWORK_DENIED=1` simulates Local Network permission denied. `ARBOR_NETWORK_TIMEOUT` /
`ARBOR_NETWORK_MOUNT_TIMEOUT` shorten deadlines.

Script steps: `netlog:/out`, `press:<button title>` (pages and sheets), `mapdrive:<folder>`, `mapfield:`, `mapoptions:reconnect=0,credentials=1`,
`mapfinish`, `mapcancel`, `mapbrowse`, `mapbrowsepick:<name>`, `disconnectcheck:<prefix>`, `nettile:[new:]<title>`,
`nettilemenu:<title>:/out`, `netdrop:<share>` (server drops the share), `netbusy:<server>/<share>`, `sheetlog:/out`,
`sheetsnapshot:/out.png` (dialogs are separate windows). `log:` adds a `network:` block.

## Hooks added to shared files (small, additive)

- `Location.server(NetworkAddress)` (+ key, name, parent; tests) and its case in `IconProvider.icon(for:)`.
- `PathResolver`: `\\server` alone is valid.
- `BrowserWindowController.networkAddressHandler` (address bar) and `volumeUnmountHandler` (tabs on an unmounted volume).
- `AddressBar.editTextProviders`; `IconProvider.itemIconOverrides` / `locationIconOverrides`.
- This Mac feature's `VolumeCatalog`: `adjustments`, `iconOverride`, `statusOverride` (used by `DriveTileView`).
- `Package.swift` links NetFS; `Info.plist` adds `NSLocalNetworkUsageDescription` and `NSBonjourServices`.

## Known gaps

- Not tested against a real SMB/AFP server or real Local Network permission prompt (no server available); live code paths (NetFS, NWBrowser, DNSServiceResolve, smbutil, getmntinfo) compile cleanly and mirror the fakes.
- FE-188 capabilities not surfaced in Properties yet.
- The context menu of a disconnected drive still lists other features' file commands (Copy, Pin, Show in Finder…) that don't apply to it.
- Two failures at once: the second error sheet waits until the first is answered, and the same failure twice is shown
  once (qa-places #12). Headless runs never show the system sign-in window (mounts use `NoUI`).
- `NetworkFolderProvider` is registered in the network slot; a later feature registering a provider for *all* folders would take network folders over (no timeout page).
