# Arbor — product vision and behavioral specification

Version 0.3 · Research and review date: November 7, 2026

**Audience:** contributors to Arbor, an open-source macOS file manager modeled on Windows 11 File Explorer.

**Status:** product specification and behavioral research record. Implementation is underway; see `docs/FEATURE-STATUS.md` and `docs/features/`.

## Contents

0. Guidance for contributors
1. Product vision and decision authority
2. Evidence rules and reference environment
3. Product model and state ownership
4. Layout and readability
5. Navigation and tabs
6. Views, ordering, filtering, and persistence
7. Selection, keyboard, focus, and menus
8. Rename, clipboard, and drag/drop
9. File operations, conflicts, and recovery
10. Search
11. Preview, metadata, and properties
12. Home, Gallery, libraries, and Trash
13. Archives, volumes, network, devices, and cloud
14. Mac equivalents and system boundaries
15. Memory, responsiveness, and proposed architecture
16. Failure states and accessibility
17. Reference audit and acceptance plan
18. Review findings and open decisions
19. Source register
20. Complete inherited feature register
21. Additional research requirements
22. Final review record

## 0. Guidance for contributors

Treat this as the self-contained product specification. Read sections 0–2 before interpreting any requirement or technical recommendation.

1. Preserve the confirmed vision and scope (section 1 and `docs/DECISIONS.md`).
2. Before changing behavior, check the decisions still open and the unanswered behavior questions for the area you touch.
3. Keep confirmed user decisions, published reference facts, proposed Mac behavior, and unverified assumptions distinct. A requirement is not evidence that Windows behaves that way.
4. Do not treat an earlier mockup or proposed point measurement as a pixel-accurate Windows reference. The earlier interactive mockup is exploratory material and is not an approved design.
5. Preserve feature IDs. Append newly discovered requirements and link refinements to their parents. Never delete difficult features merely to make the completion percentage improve.
6. For an unknown reference behavior, write a reproducible observation task. Do not silently substitute what feels reasonable or what another file manager does.
7. Do not use behavior from the third-party Windows **Files** application, PowerToys, ExplorerPatcher, StartAllBack, or other extensions as evidence of stock Windows File Explorer.
8. A Microsoft SDK's capability is not proof that the current Explorer UI exposes it. An Insider announcement is not proof that every generally available Windows installation has it.
9. The user values UI design, useful features, missing capabilities, and reported user problems. Low RAM and responsiveness are constraints throughout. Advanced search must not absorb the entire product scope.
10. Swift with AppKit is the current recommendation, not a selected stack. Exact license, minimum OS, RAM budgets, architecture, release channels, and dates remain undecided.
11. Convert accepted requirements into behavior tests and capability experiments first. Do not mark native operations implemented because buttons or sample data exist.
12. Report what was verified and how. Never claim perfect Explorer equivalence without a pinned Windows reference, observed outputs, and an explicit comparison report.

### Interpretation of normative language

**MUST** describes a proposed product requirement or a confirmed scope constraint, as labeled. It does not assert an observed Windows fact. **SHOULD** is a recommendation. **OPEN** requires a decision or evidence. A feature described here is not necessarily approved for an initial release. Final release scope has not been chosen.

## 1. Product vision and decision authority

### 1.1 Confirmed direction

The vision is a public, open-source macOS file manager with the familiarity, organization, readability, and control of current Windows 11 File Explorer, including tabs. A Windows user should understand the layout and apply familiar file-management habits immediately.

The user's primary frustration with Finder is the organization and readability of files. The product should make hierarchy, filenames, metadata, sorting, selection, search scope, and operation outcomes understandable. UI quality and useful features lead planning. Low memory use, responsiveness, and restrained background activity remain requirements, not a later cosmetic optimization.

The current task is to research and document that vision. No commitment to build or launch has been made.

### 1.2 What is not yet decided

- Project name and artwork.
- Exact Windows reference build, revision, feature rollout, edition, and account configuration.
- Degree of visual imitation versus native Mac chrome.
- Default starting location, view, density, extensions, and folders-first behavior.
- Whether an optional improved presentation preset exists. The earlier “Explorer” and “Readable” two-preset proposal was never approved.
- Keyboard adaptation policy and whether to offer multiple presets.
- Initial release feature boundary and treatment of account-specific Windows services.
- Minimum macOS version, Intel support, language/frameworks, license, distribution, schedule, and numeric resource budgets.

### 1.3 Decision order

Use: current explicit user direction → confirmed vision → measured reference behavior → documented reference behavior → proposed design. A reference observation can resolve a behavioral question; it cannot override a user preference without acknowledging the resulting product difference. This specification supersedes older wording that accidentally promoted proposals into decisions.

### 1.4 Finder research interpretation

Earlier qualitative discussions identified requests for readable long filenames, predictable sort/view settings, an editable path bar and separate tree, familiar cut/paste and activation keys, clearer search coverage, useful transfer history, and dependable network identity. These are self-selected reports, sometimes from older OS versions. They are neither prevalence estimates nor proof of universal Finder defects.

Finder already has view controls, path navigation, copy-then-move, and Quick Look. The product opportunity includes making actions easier to discover and more consistent. Preserve useful Mac capabilities rather than assuming every difference is a missing feature. [R27](#r27)

## 2. Evidence rules and reference environment

### 2.1 Confidence labels

| Label | Meaning | Permitted claim |
|---|---|---|
| USER | Explicit user decision | Agreed product direction |
| DOC | Current public primary documentation supports the stated fact | Documented, subject to stated conditions |
| SDK | API or protocol documentation | Platform capability; not verified Explorer UI |
| HIST | Historical or release-introduction documentation | Existed in that release; current behavior needs checking |
| ROLLOUT | Insider or staged-release description | Conditional behavior; verify on reference installation |
| REPORT | Attributed user report | Research signal, not confirmed defect |
| PROP | Our proposed behavior or technical recommendation | Candidate requirement; not reference evidence |
| AUDIT | Requires direct observation | Unverified |
| BOUNDARY | Depends on another service or OS surface | Needs an equivalent, integration, or explicit handoff |

No behavior in this specification is labeled directly observed on a Windows installation. Public-document research was performed; hands-on Windows comparison was not. The inherited register contains candidate requirements, including improvements, rather than 234 verified Windows facts.

### 2.2 Reference manifest to complete

Record exact Windows product/version/build/update revision and Explorer binary version; edition and architecture; installed KBs; Insider versus GA status; rollout flags if discoverable; locale; keyboard; timezone; display scale; resolution; text scaling; theme; contrast; mouse settings; single/double-click preference; account type; OneDrive version/account; indexed locations; installed shell extensions; folder options; filesystem types; network shares; and attached devices.

Start with stock configuration plus disposable fixtures. Keep extension-enabled and account-enabled observations as separate runs. Maintain at least one local account run, one personal cloud account run where authorized, and one work-account run only if enterprise behavior is part of the agreed scope. Do not claim these runs happened until evidence exists.

### 2.3 Observation record

```text
Observation ID / related feature IDs:
Windows manifest ID:
Surface and starting state:
Fixture names, metadata and provider:
Exact pointer/keyboard steps:
Visible result, focus, selection, scroll and history:
Dialog text, menu order, enabled states:
Evidence attachment and capture time:
Repeat result after restart / on second configuration:
Source context and confidence:
Proposed Mac equivalent or intentional difference:
Acceptance test / unresolved question:
```

Visual reference captures need the full window plus relevant detail crops. Measure logical coordinates separately from physical screenshot pixels. Capture default, hover, focused, selected, disabled, loading, error, long-name, overflow, and large-text states. Color samples alone are insufficient to reproduce behavior.

## 3. Product model and state ownership

### 3.1 Reference insight

Explorer browses a Shell namespace containing filesystem and virtual objects. A display name is not a sufficient identity, and not every object is a normal file with a path. [R04, R05: SDK/DOC]

### 3.2 Proposed conceptual model

Use these concepts when documenting behavior, without selecting an implementation framework:

- **Item:** stable identity scoped to a provider/volume, display name, underlying locator, type, attributes, version/freshness, metadata availability, and supported capabilities.
- **Location:** a directory, volume, archive boundary, collection, search result, Trash, device, or provider namespace. It exposes enumeration, applicable actions, default write destination if any, and connection/access state.
- **View:** presentation mode, ordered columns, width policy, sorting descriptors, grouping, filters, density, zoom, and scope of persistence.
- **Selection:** selected item IDs, focused item, range anchor, and selection mode. These are different states.
- **Navigation entry:** committed location, selection/focus identity, scroll anchor, and view/search state needed for restoration.
- **Operation:** immutable source identities and chosen destination, requested intent, resolved capabilities, per-item plan, progress, conflicts, partial results, and recovery state.

Never use row index as permanent identity. A single path can refer to a different object after replacement; an item's path can change after rename. A hard link means even “stable item ID” and “directory entry” require deliberate treatment. Do not globally deduplicate legitimate hard-linked entries or provider results by filename.

### 3.3 State ownership proposal

| Scope | Owns |
|---|---|
| App | Preferences, favorites, privacy controls, active operation service, bounded shared caches |
| Window | Frame/display, open tab order, panel presentation, last focused region |
| Tab | Location/history, query/scope, selection/focus/anchor, scroll restoration, applicable view state |
| Folder/template | Saved presentation override and explicit inheritance information |
| Provider | Capabilities, connection identity, supported metadata/action availability |
| Job | Progress and decisions independent of the browsing tab |

An update must be applied only if it still belongs to the current request/location/version. Late thumbnail, enumeration, and search responses must not overwrite a newer folder's state.

## 4. Layout and readability

### 4.1 Reference structure

Microsoft documents tabs at the top, navigation on the left, a central content area, optional item information, and toolbar/app-bar regions. This is a family-level structure, not a measurement of the target build. [R02: DOC]

### 4.2 Proposed spatial arrangement

```text
Native Mac window controls + Explorer-style folder tabs
Back | Forward | Up | Refresh | breadcrumb/editable path | Search
New | file actions | Sort | View | contextual actions | overflow
Navigation tree | folder/results surface | optional Preview or Details
Status: items / selection / partial totals / background operation access
```

Retain the separate tree-and-contents relationship. A disclosure arrow expands hierarchy; a location label navigates. The product should not silently replace this with Finder-style Miller columns or a dual-pane commander design.

Native Mac chrome is a proposed adaptation requiring agreement. Fonts, icon assets, title controls, command order, context-menu structure, density, and detail-pane presentation must be specified against actual reference screenshots before visual fidelity is claimed. Use original redistributable artwork and an independent product identity.

### 4.3 Candidate measurements, not measured Explorer values

For discussion only: 1280 × 800 content frame; 820 × 560 minimum; tab/title row 44 points; navigation 52; commands 48; status 28; tree initially 224 wide within 184–360; inspector initially 320 within 280–420; body text 14 points; rows 28/32/36 depending on density. These values come from the prior proposal. They remain unapproved and must not be silently shipped as “exact Windows.”

Contents, tree, and inspector should scroll independently with stable chrome. Resizing should preserve useful filename width and user choices. Propose command overflow before wrapping, search expansion when constrained, and an explicit inspector overlay when side-by-side space is insufficient. These are candidate adaptations; record each accepted difference.

### 4.4 Readability requirements proposal

1. Make complete filenames discoverable through pointer, keyboard and accessibility paths. Define truncation for names, extensions, paths and duplicates separately.
2. Reserve stable space for provider badges; late status updates must not paint over text.
3. Align comparable values. Distinguish logical size, allocated size, unknown size, and a zero-byte file.
4. Keep sort and group controls distinguishable. Never require changing unrelated grouping merely to put folders first.
5. Preserve focus, selection and the top visible anchor during background updates.
6. Provide density and text-size controls independently, subject to user agreement. Avoid shrinking essential text to fit more metadata.
7. Explain active per-folder overrides. User-requested consistency is not solved by silently guessing templates.
8. Keep search scope, current location, destination and operation result visible at the point of action.

Candidate defaults are Details, Name ascending, grouping off, visible extensions and folders first. The user has not approved those defaults or a separate preset; compare them with Explorer before deciding.

## 5. Navigation and tabs

### 5.1 Location navigation contract — PROP

Navigation is a state transition, not merely changing a path string. Define requested destination, resolution/access check, enumeration start, committed history entry, partial rows, ready state, and failure. On a failed request, retain the previous valid history and offer retry/back; preserve the attempted destination visibly.

Back and Forward are history transitions. Up is a parent transition. They are not interchangeable. The observed Windows handling of selection/scroll restoration must be recorded; proposed Mac behavior restores both where the item still exists. Branch navigation after Back trims forward history; refresh does not. Tab histories are independent.

Tree expansion and label activation require separate hit targets and keyboard states. A collapsed node should not force enumeration of every descendant. Loading/denied/offline child enumeration remains local to that node. Keep the actual current-location marker distinct from keyboard focus or a context-menu target. Audit whether tree focus navigation activates immediately or on Enter under each input mode; do not assume all controls follow the same rule.

### 5.2 Address and breadcrumb contract — PROP/AUDIT

Document every accepted input: native path, file URL, tilde, relative path policy, quoted path, UNC, SMB URL, shell alias and typed executable. Path completion, history, sibling dropdowns, ancestor overflow, copy address, drag from breadcrumbs and drops onto them require separate tests.

Proposed Mac behavior accepts truthful Mac paths and deliberately translates recognized network inputs. Unknown Windows drive letters are explained, not mapped arbitrarily. Path entry must not silently execute shell text. If command-launch behavior is desired for parity, require a separately reviewed, explicit command interaction.

Enter resolves; Escape restores the committed location. Invalid input remains editable with a specific reason. Canonical locator, user-entered representation and localized display label remain separate. Round-trip spaces, Unicode, percent escapes and network share names without double-encoding or double-decoding.

### 5.3 Tabs — documented core and unresolved details

Microsoft documents tab creation/cycling/closing and numbered tab access. [R03: DOC]

Audit close-other/right, duplicate, detach, merge, middle-click by surface, drag hover, overflow, maximum/minimum width, keyboard order, new-tab starting location, new-window location, reopen-closed-tab and session restoration. Browser conventions are not evidence these actions exist in Explorer.

Propose keeping query, location, selection and scroll per tab. Closing a tab should not cancel an independent transfer. Closing the last Mac window and quitting the Mac app are different actions; decide how running jobs survive each. Restored windows must remain reachable after monitor changes. Session restore must not silently reconnect every saved enterprise share.

## 6. Views, ordering, filtering, and persistence

### 6.1 View-mode audit

Inventory Extra large, Large, Medium and Small icons, List, Details, Tiles, and Content. Do not merge modes because their icons look similar. For each capture: row/cell geometry, metadata shown, label wrapping, selection/focus visuals, scroll axis, arrow-key movement, thumbnail policy, zoom, header behavior, drag selection, and context commands. Gallery is a separate collection surface.

### 6.2 Details columns — PROP

Record ordered column descriptors rather than only a list of visible strings. Each column needs a key, display label, value state, formatter, width/minimum, alignment, sortable/filterable capability, and asynchronous fetch policy. Distinguish absent metadata from unsupported metadata and still-loading metadata.

Propose Name leading and flexible; Modified, Type and Size as initial metadata; optional Status. Exact default columns and Name reordering restrictions must be observed. Test chooser, reset, drag reorder, manual sizing, fit one, fit all, horizontal scrolling, column-specific filters and numeric alignment. Type labels come from associations/content-type systems, not arbitrary title-cased extensions.

### 6.3 Sorting correctness

Microsoft's logical string comparator treats digit sequences numerically, is case-insensitive, and explicitly warns that ordering can change across releases. Its existence is not proof that every Explorer property uses it. [R07: SDK]

Create reference outputs for names with leading zeros, punctuation, spaces, mixed case, diacritics, composed/decomposed Unicode, non-Latin digits, emoji, hidden extensions, multiple dots and duplicate display names. Record results for each locale and relevant filesystem. Reusing macOS localized comparison or a generic natural-sort library does not establish exact parity.

The view API supports a sequence of sort columns. [R08: SDK] Audit actual multi-key UI behavior rather than assuming a Shift-click gesture or a particular tie-breaker. Document folder partition rules in both directions, unknown values, equal values, newly arriving metadata, grouped views and search results. Display order is not canonical item identity and must never determine destructive operation targets.

Proposal: compute inexpensive keys once, sort background snapshots, apply stable identity-based diffs, and keep focus/selection stable. Avoid querying disks inside comparison functions. Multi-key ordering and stable tie-breakers must be explicit.

### 6.4 Grouping/filtering distinctions

Grouping partitions visible results; sorting orders within a scope; filtering excludes items; a search chooses matches; a library projects multiple real folders. Define each separately. Test collapse persistence, group-header selection, context actions, counts, unknown group values and sort changes while groups are collapsed.

Folders-first independent of sort direction is a proposed improvement requiring reference comparison. Do not treat that proposal as an observed Windows universal.

### 6.5 Settings audit

Microsoft's settings catalog confirms controls covering activation mode, compact density, full title path, hidden items, empty drives, known extensions and selection checkboxes. It is not an exhaustive Folder Options specification. [R09: DOC]

Capture all controls on the actual General, View and Search pages, including radio dependencies, defaults, Apply/OK/Cancel behavior, reset, and apply-to-folders scope. Audit candidates include launch target; same/new window; click activation; privacy/history controls; icon versus thumbnail; preview handlers; folder tips; protected items; extension hiding; status; launch windows in a separate process; restore prior windows; navigation-tree options; non-indexed search; archive/system search; and indexing choices. Some may be absent or relocated on the pinned build.

Propose settings precedence with a visible source: app default → folder-type default → explicit folder override. Define whether a tab-only temporary override exists. Apply/reset must state the scope and preserve user files. Persisting presentation is distinct from changing filesystem attributes. Do not modify `.DS_Store` or Windows registry-like files just to imitate behavior.

## 7. Selection, keyboard, focus, and menus

### 7.1 Selection test contract — PROP/AUDIT

Observe plain click, background click, Shift range, Ctrl disjoint, Ctrl+Space, Ctrl+arrow focus-only, Shift+arrow, marquee, checkbox, hover selection in single-click mode, group headers and type-to-select. Track selected IDs, focused ID and range anchor separately. Test sort/reorder/deletion between selecting the anchor and extending a range.

Right-click on a selected item should preserve an intended batch; right-click on an unselected item must define its target selection. Tree context actions may target a different node from the displayed folder. A toolbar action must use a frozen target snapshot, not whatever selection exists when asynchronous work later completes.

Type-to-select requires timeout, repeated-character cycling, prefix matching, locale and IME rules. Do not substitute substring filtering unless chosen explicitly. List and grid movement require their own spatial reference tests.

### 7.2 Keyboard reference anchors

The following are compact reference anchors, not the complete shortcut list. Consult the full primary reference and test contextual behavior. [R03: DOC]

| Intent | Windows anchor |
|---|---|
| Address | Alt+D / Ctrl+L |
| Search | Ctrl+F / Ctrl+E |
| Parent/history | Alt+Up / Alt+Left / Alt+Right |
| Tab lifecycle | Ctrl+T / Ctrl+W |
| Tab switching | Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+digit |
| Rename/refresh | F2 / F5 |
| Properties/preview/details | Alt+Enter / Alt+P / Alt+Shift+P |
| New folder | Ctrl+Shift+N |
| Context menu | Shift+F10 |
| Permanent deletion | Shift+Delete |

Open-with-Enter and region navigation need accessible behavior tests. [R02](#r02) Remaining audit includes view-number shortcuts, numpad tree and fit commands, standard clipboard/undo, page navigation, selection modifiers, menu access keys and F11. Do not infer a ninth view from a generic documentation key range.

### 7.3 Mac mapping proposal

Keep native editing and IME behavior in text fields. Propose Enter-to-open and F2-to-rename in file lists; Command equivalents for common app/file commands; optional Windows Control bindings only in file/tree contexts. Mac Backspace and forward Delete are different physical/logical inputs. Do not bind ordinary Mac Backspace to permanent deletion. Fn requirements, VoiceOver shortcuts, system-reserved combinations and global launch commands need validation. Do not choose competing aliases globally before user review.

### 7.4 Menu audit and capability rules

Build a surface × selection × capability matrix. Surfaces: app bar, file, folder, background, tree node, volume, search result, collection result, archive, Trash, cloud, device, mixed selection, and operation history. Record text, icon, order, separators, submenu, key equivalent, enabled/disabled/hidden state and selection target.

Modern Windows context actions can be supplied through registered commands; default-application associations and arbitrary context extensions are distinct mechanisms. [R17: SDK] Use per-provider capability intersections for mixed selections; do not show an action that only half the batch supports unless the partial scope is explicit.

Core action families: open/open-with; new; clipboard; rename; deletion; shortcut/alias; pin/favorite; share/send; copy path; properties; type-specific print/rotate/background; compression/extraction; terminal; provider actions. Some entries are only legacy, account, type or installation dependent. Exact menu order, customization and Show more options require build-level capture. The 2026 redesign was announced as a rollout, not a universal invariant. [R18: ROLLOUT]

## 8. Rename, clipboard, and drag/drop

### 8.1 Naming and rename — PROP/AUDIT

Audit initial selection of basename/extension, dotfiles, compound suffixes, hidden extension, numbered batch names, duplicate naming, Tab/Shift-Tab sequencing, Enter commit, Escape cancel, extension warnings, case-only rename, forbidden characters and normalization collisions. Keep unsuccessful input editable. Do not discard typed text on background sync updates.

Windows naming constraints include reserved characters and device names, while shell conventions and underlying filesystem capabilities can differ. [R10: SDK] Do not globally reject a valid Mac filename just because Windows forbids it. Apply actual destination rules. Offer an optional Windows-compatibility warning only if agreed. Never normalize an existing name destructively to achieve visual sorting parity.

New-folder creation needs naming/collision behavior and a writable destination. A New menu template must be a valid file format; an empty `.docx` is not a real document. Virtual surfaces must resolve or request a real destination before creation. Advanced batch rename is a proposed enhancement; it is not synonymous with Explorer's basic multi-item numbering.

### 8.2 Clipboard contract

Windows Shell transfers can represent existing file locations, virtual content and preferred/performed transfer effects. Streamed content can avoid loading complete files into memory. [R11, R12: SDK] Therefore cut/paste cannot be faithfully modeled as a global Boolean plus copied path strings.

Propose a transfer-intent record: source/provider and item identities, ownership/version of clipboard content, preferred action, offered representations, allowable actions, and any completion handshake. Dimming is presentation, not deletion. Clear stale cut marks when clipboard ownership changes. Test partial moves, same-location paste, repeated copy, repeated cut-paste, cancelled paste, source rename/replacement, cross-app transfer, archive/device virtual files, and clipboard ownership after source-app exit.

Mac uses its own pasteboard/file-promise facilities. An internal move protocol does not imply Finder or other apps will honor it. Define a compatibility matrix and preserve plain Copy support independently.

Apple's promise-receiver documentation specifies asynchronous readiness/error callbacks, warns that a failed promise may leave partial/corrupt output, and notes that promised filenames can be unavailable before reception starts. [R38, R39: SDK, official excerpts] Therefore a nonempty URL is not proof of success, and a destination chooser or drag image must tolerate incomplete preflight metadata. Call acceptance APIs only once accepting the transfer is intended; receiving a promise can initiate real writes.

### 8.3 Drag/drop contract — PROP/AUDIT

Reference keyboard modifiers document copy/move/shortcut intent; actual default effects depend on source, target and available capabilities. [R03, R12] Observe same-volume versus cross-volume, same-folder, network, archive, cloud, volume root, alias, app and virtual-object targets.

Freeze source selection at drag start. Show count, destination and resolved intent. Distinguish target label from background and avoid treating an incidental selected folder as the destination. Hover-expansion, tab activation and autoscroll are cancellable. Previous 600/700 ms timings were proposals, not measured values. Right-drag menu and accessible alternatives need mapping to Mac input.

Reject invalid self/descendant operations and unsupported destination writes before beginning where possible; revalidate before committing because the filesystem can change. Keep promised/remote content streamed and bounded. Do not silently download a whole cloud tree to draw a drag image.

## 9. File operations, conflicts, and recovery

### 9.1 Reference architecture insight

The Windows operation API separates declaring an item action from performing operations. It also documents that execution can report success even if the user aborted; cancellation must be checked separately. [R13, R15: SDK] This does not prove the whole operation is transactional or that every file completed.

Undo/recycling/elevation/metadata flags demonstrate configurable operation policy. They do not justify claiming infinite undo, crash-safe rollback, or uniform metadata preservation in all Explorer/provider scenarios. [R14: SDK]

### 9.2 Proposed job record

An operation specifies immutable source/destination intent, conflict policy, traversal/link policy, requested metadata fidelity, cancellation token, per-item results and recovery journal. UI browsing state cannot change its target after submission. Long-running preparation and enumeration must themselves be cancellable and memory-bounded.

Distinguish known-total versus still-counting progress. Count bytes and items separately; do not show a fabricated ETA. Distinguish processed, skipped, successful, failed and uncertain items. A file copied but not safely removed from source is not a completed move. Optional verification is an additional state, not a synonym for transfer completion.

### 9.3 Proposed state transitions

```text
Queued → Preparing → Running → Completed
Preparing/Running → Waiting for decision → Running or Cancelled
Running → Pausing → Paused → Running      [only when supported]
Preparing/Running/Waiting → Cancelling → Cancelled
Preparing/Running → Failed or Partially completed
App/process interruption → Interrupted → Review → Safe retry or Dismiss
```

Pause controls need engine/provider support. Restarting the current partial file and resuming at a byte offset are different promises. Cancellation does not imply rollback of completed work. A transfer may continue independently of its browsing tab; app-quit behavior remains a design decision.

The progress-sink interface names timer callbacks that the documentation labels unsupported; the method names do not establish pause/resume capability. Its per-item callbacks provide actual operation results, and the resulting destination name can differ after collision handling. [R36, R37: SDK] Proposed Mac operation records must capture actual committed identity/name and result rather than assuming the requested destination was used unchanged.

### 9.4 Conflict decision matrix — PROP

| Source / destination condition | Required distinction |
|---|---|
| File versus existing file | Replace, skip, retain both; compare if supported |
| Folder versus existing folder | Merge contents versus replace whole destination subtree |
| File versus folder or folder versus file | Explicit type conflict; never silently coerce |
| Same item or same location | No-op or explained refusal; never erase source |
| Case/normalization-equivalent name | Actual destination rules, not only displayed spelling |
| Destination changed since prompt | Recheck; stale confirmation must not clobber newer work |
| Parent is read-only or missing | Different destination, authorized access, create parent if chosen, or stop |
| Cloud/device operation unsupported | Capability explanation and supported alternative |

Show source and destination names/paths, types, known sizes, timestamps and comparison limitations. “Same size” is not “identical.” Scope “apply to remaining” to this job and conflict category. Separate folder merge and replacement. Keep-both generation must avoid a second collision and respect extension/naming rules. Exact conflict dialog text, button order, default focus, close/Escape behavior and compare UI need direct Windows audit. Earlier safe-default proposals must not be mislabeled reference behavior.

### 9.5 Integrity and metadata requirements — PROP

- Across volumes, retain each source until its corresponding destination is successfully committed under the stated fidelity policy. Handle source changes during the copy deliberately.
- Protect against partial final-name files and overwriting unrelated replacements. Temporary staging/atomic replacement feasibility is destination-dependent and must be investigated.
- Define treatment of timestamps, permissions/ACLs, tags, extended attributes, resource forks, quarantine, symlinks, hard links, sparse files and clones. Capabilities differ between APFS, exFAT, SMB, NTFS readers and cloud providers.
- Never silently follow every symlink or preserve a hard link by accidentally coupling two independent destination files. Document traversal and identity rules.
- A crash journal must distinguish committed, uncommitted and uncertain work. Retrying by filename alone is unsafe. Do not replay an uncertain destructive step automatically.
- Undo must name its action and refuse to destroy subsequent external edits. Retaining replaced originals has storage and expiry costs that require agreement.
- Permanent deletion is not promised undoable; network/removable destinations may not support recycling. Trash intent must never silently become permanent delete.

### 9.6 Failure reporting — PROP

Expose failing item and parent path, source/destination identity, readable reason, operation stage, completed/skipped/failed counts, and valid actions. Test disk-full, read-only, vanished source, locked file, permissions, disconnected share, invalid destination name, lost cloud authentication, and source/destination replacement races. A single generic “failed” toast is insufficient for a partially completed batch.

## 10. Search

### 10.1 Distinct workloads

Treat current-folder filename matching, recursive filename search, whole-volume indexing, metadata/property queries, document-content extraction, and semantic search as distinct capabilities. Their memory, I/O, availability and correctness differ. A whole-disk indexer is not required just to display a folder.

Microsoft describes AQS as Windows Search query syntax. [R16: SDK] It also offers improved search with hardware/service conditions; do not make optional semantic search part of every baseline Windows observation. [R25: DOC/ROLLOUT]

### 10.2 AQS compatibility traps

The documented language has property restrictions, phrases, ranges and Boolean operations. It specifies uppercase Boolean operators and a left-to-right treatment when AND/OR are mixed; canonical property names avoid dependence on localized friendly labels. This differs from assuming conventional Boolean precedence. [R16: SDK]

Build an explicit operator compatibility table rather than accepting arbitrary strings and silently ignoring unsupported syntax. Audit property aliases, filename versus all-property defaults, exact phrase, prefix, wildcard behavior, date locale/timezone, units, null values, negation, parentheses, and scope. Never assume glob, regex, Everything syntax and AQS are interchangeable.

### 10.3 Proposed search state and result contract

Retain query, scope, name/content intent, filters, provider, coverage status, progress, selected IDs and origin navigation entry per tab. Display whether the current folder includes descendants. Results show actual containing location and match reason. Open containing folder selects the item where possible. Clearing search returns to the documented origin without dropping useful state.

No-results must distinguish completed search from still-loading, denied locations, unindexed regions, disconnected providers, unsupported content, and timed-out scans. Index state is not direct proof every accessible file is covered. Apple documents indexing and unexpected results; a direct filename scan can be an explicit fallback, with cost and incompleteness reported. [R26: DOC; fallback is PROP]

Proposed filename-first ranking, visible coverage diagnostics, and independent name/content controls are user-focused improvements. Do not describe those as verified Explorer defaults. Saved searches persist query plus stable scope identity and semantics/version; a `.search-ms` filename alone does not make a compatible parser.

### 10.4 Search resource rules — PROP

Cancel obsolete queries; suppress stale responses; stream or page results; cap in-flight extraction; avoid hydrating remote content without policy; keep index scope configurable; separate local metadata from extracted text; handle changes incrementally; and avoid rebuilding the world when one folder changes. Test memory growth across repeated queries, not only time-to-first-result.

## 11. Preview, metadata, and properties

### 11.1 Three different surfaces

An icon/thumbnail is a listing representation. A Preview pane renders read-only content. A Details/Properties surface exposes metadata and supported edits. Do not implement one large image and call all three done. Windows has an extensible property system; not every property is available or writable on every item. [R06: SDK]

Windows preview architecture uses handlers, and thumbnail generation uses caching with lifecycle rules. Historical documented cache sizes are not fixed modern UI dimensions. [R19, R20: SDK/HIST]

### 11.2 Proposed lifecycle

Request only needed thumbnail sizes; cancel obsolete previews; validate identity/version before applying results; release heavy decoded resources when the pane closes or selection changes. A missing preview keeps filename and metadata usable. Large image decoding, PDF paging, video/audio playback and cloud downloads need bounds. Never launch the associated editor just to render a preview unless the user explicitly selects Open.

Mac Quick Look and thumbnail facilities are candidate integrations, not a guarantee every Windows preview handler exists on Mac. Show unsupported type/provider states plainly. Full Windows COM plugins cannot be loaded as Mac plugins.

### 11.3 Properties audit matrix

Capture actual tabs per type: ordinary file, folder, link, application/executable, image, music, video, archive, volume, network item, cloud placeholder and mixed selection. General, Details, Security, Sharing, Customize, Previous Versions, Digital Signatures and Compatibility are candidates whose visibility depends on type, system and extensions.

Define editable versus calculated versus unsupported fields; single versus mixed values; embedded portable tags versus Finder tags/comments; user identity/ACLs versus effective access; logical versus allocated size; progress of recursive size calculation; cancel/apply behavior; external edits during a dialog; and metadata removal without corrupting content. A read-only attribute on a Windows folder is not a sufficient model for effective Mac directory write permission. Do not implement permission behavior by interpreting a checkbox without capability testing.

## 12. Home, Gallery, libraries, and Trash

### 12.1 Home and Quick access

Microsoft documents pinned locations and changing Home/This PC organization, including account-dependent search. [R01: DOC] Capture the exact reference page for local/personal/work accounts; recommended, recent, shared and favorite sections may vary by rollout/account.

Proposal: distinguish pin/unpin from move/delete; removing a recent item changes history only. Define empty sections, collapse persistence, startup preference, privacy clearing and duplicate account labels. A favorites surface is a projection, not another physical copy of the file.

### 12.2 Gallery

Gallery's introduction describes a photo collection with selectable source folders and chronological content. [R21: HIST] Verify current grouping/date rail, collection management, supported formats, thumbnail sizing, context actions and keyboard movement. Do not treat the separate Photos app's current Gallery UI as Explorer evidence.

Propose retaining original file identity and location for operations. Removing a source from the collection must not delete its files. Missing/offline sources yield partial coverage. Capture what creation/paste means in this virtual surface before offering it.

### 12.3 Libraries

Libraries aggregate real folders and can have a default save destination. Some functions depend on indexing and storage availability. [R22, R23: DOC/SDK/HIST]

Define add/remove source, include subfolders, duplicate/overlapping sources, inaccessible sources, sort/group, source identification, default save destination, removing that destination and no-writable-source failure. Removing membership and deleting an actual item are distinct actions. Mac equivalents should be explicit collections with truthful destination resolution; Windows `.library-ms` import/export compatibility is a separate parser decision.

### 12.4 Trash / Recycle Bin

The Windows Recycle Bin is a special namespace with operation policies. [R04, R14] Audit per-drive settings, deleted-date/original-location fields, restore, restore-all, empty, permanent delete, missing original parent, conflicts and items that cannot be recycled. Do not infer server-side recycling from a local network deletion.

Mac Trash restoration and metadata availability require public-API feasibility work. Until proven, do not promise global Put Back for arbitrary pre-existing Trash contents or parse undocumented trash databases as if stable. App-managed undo records and system Trash are separate mechanisms with explicit scope.

## 13. Archives, volumes, network, devices, and cloud

### 13.1 Archives

Microsoft documents ZIP operations and additional format support with encrypted-archive limits. [R24: DOC] Format support is a matrix, not a checkbox:

| Capability | Record separately for each format/variant |
|---|---|
| Enumeration | Browse archive names and paths without extracting everything |
| Read/extract | Extract one or all; choose destination; preserve supported metadata |
| Create | Supported output format, method, level and naming |
| Modify | Add, delete, rename or update; rewrite requirements; atomicity |
| Credentials | Encryption/header encryption support and password lifecycle |
| Error/recovery | Corrupt archive, cancellation, split volumes, disk-full, nested archives |

RAR extraction does not imply RAR creation. ZIP mutation does not imply mutation of every readable format. Audit archive-entry activation: temporary extraction, application launch, modified-file update prompt and cleanup. Define path traversal, absolute entries, link targets, expansion limits, duplicate entries and destination conflicts. Avoid materializing the entire archive into RAM. ISO/DMG mount/burn/eject uses a different capability family.

### 13.2 Volumes and network

Windows mapped-drive setup includes persistent reconnection intent; network discovery, sharing and direct path access are distinct operations. [R28: DOC]

Propose This Mac with real volume IDs, mount points, filesystem, free/used capacity, removable/locked/read-only state and network identity. Different servers can export the same share name. Connection records must include server/share/account identity; display name alone is not a reconnect target.

Document connect/disconnect/eject, busy errors, lost credentials, VPN changes, slow enumeration, no server discovery, sleeping servers, partial permissions and case rules. Keep unrelated local tabs responsive. Mounting an existing share and exposing a local folder to other users are different security operations; initial sharing may be a system-settings handoff if approved.

Formatting, checking, optimizing, encrypted-drive management and optical actions remain inventoried but may map to Mac system utilities. Do not silently perform them or fake success from a native file-browser button. NTFS write access depends on actual installed capability. Drive letters are not native Mac volume identity.

### 13.3 Devices and other namespaces

Phone/camera/MTP/PTP, WSL/Linux, network printers, Control Panel, developer-storage nodes and extension namespaces are conditional Windows surfaces. For each record detection, browse/enumeration, import/export, operations, metadata, authentication and disconnection. A device appearing under This PC does not establish that it behaves like a mounted disk on Mac. Preserve each feature as a boundary/equivalence question rather than pretending it is ordinary folder support.

### 13.4 Cloud capability matrix

Files On-Demand distinguishes online-only, locally available and retained-offline states; placeholder visibility is different from local content availability. [R29: DOC]

For each installed Mac provider/account, investigate enumeration, actual status, thumbnails, download/hydration, pin, eviction, cancellation, share-link creation, permissions, version history, conflicts, offline edits, rename/move and batch atomicity. A public API allowing a provider to implement a feature is not automatically available for a third-party browser to control another provider's domain.

Show Unknown when state cannot be established. Download on open, preview and copy must be deliberate and visible. Multiple accounts use distinct identities. Keep local indexing from accidentally downloading all cloud files. Do not build a new sync engine merely to imitate provider badges.

## 14. Mac equivalents and system boundaries

| Windows concept | Candidate Mac treatment | Unresolved evidence |
|---|---|---|
| This PC / drives | This Mac / real volumes | Exact visual layout and capacity formatting |
| Recycle Bin | System Trash plus scoped app history | Public restore API and original-location metadata |
| Shell link | Alias; optional explicit symlink action | LNK/URL import and unsupported targets |
| Windows property/security model | Actual Mac metadata, POSIX/ACLs | Effective permissions and writable format fields |
| Shell handlers | Native Mac facilities and separate provider/action contract | Public third-party availability and isolation |
| OneDrive/enterprise panes | Installed provider/account integrations | Status/actions not necessarily exposed to browser apps |
| Previous Versions | Time Machine/provider handoff if feasible | No invented backup history or snapshot access |
| Mapped drive | Saved authenticated mount identity | Reconnect and user permission behavior |
| Nearby Sharing | Mac share services/AirDrop where supported | Protocol compatibility is not implied |
| Terminal launch | Chosen Mac terminal, explicit folder context | Safe path passing and app support |
| Windows window controls / shortcuts | Proposed native Mac adaptation | User acceptance and collision testing |
| Desktop/taskbar/Start host | Explicit OS-shell boundary | Outside a standalone browser's replacement capability |
| Other apps' Open/Save dialogs | Separate system surface | This app cannot automatically replace every dialog |

Windows File History backs the Previous Versions workflow; it is service-dependent. [R30: DOC] An equivalent UI without backup capability would be misleading. Mac native integration must respect permissions and actual OS facilities, including protections that Full Disk Access does not eliminate. [R31: contextual/partial retrieval]

## 15. Memory, responsiveness, and proposed architecture

### 15.1 Confirmed product constraint

Low RAM and responsive browsing are explicit user requirements. Exact numbers have not been approved. No performance result exists because no application has been built or benchmarked.

### 15.2 Candidate architecture, not a decision

Swift + AppKit is recommended for native desktop integration and precise table/tree/input behavior. SwiftUI is a candidate for simpler secondary surfaces. A separate Rust/C++ core is justified only by measured needs or a deliberate portability goal. SQLite or another persistent store is a candidate for settings/journals/indexes; choosing one is not equivalent to implementing fast search.

Keep enumeration, metadata, search, previews, operation execution, provider adapters and presentation logically separable. Background concurrency is bounded and cancellable; async syntax alone does not guarantee disk I/O or CPU work is off the UI path. Any low-level blocking API needs an appropriate execution strategy and limits. Apple recommends coordinated asynchronous file access and avoiding unnecessary I/O; the exact chosen APIs still need validation on the deployment target. [R32: contextual/partial retrieval]

### 15.3 Resource design requirements — PROP

- Allocate visuals for visible rows plus a small measured buffer. Retaining a lightweight listing model for sorting is different from allocating one UI object/thumbnail per file.
- Bound caches globally across windows/tabs, not independently per tab. Specify byte cost, entry count where relevant, eviction priority, staleness, persistence and memory-pressure behavior.
- Bound decoded images, PDF render pages, media buffers, metadata batches and provider requests. Compressed file size is not decoded bitmap memory cost.
- Keep inactive tabs' location/history/selection compact. Evict reconstructible metadata/previews while retaining useful navigation state.
- Cache correctness needs provider/volume identity, item/version and requested representation. Same basename is not a safe cache key.
- Cancel obsolete enumeration/search/preview tasks and release their captures. Debounce/coalesce event bursts without losing updates; reconcile after event loss or stale snapshots.
- Do not recursively pre-scan the whole tree for disclosure arrows or folder sizes. Compute expensive recursive metadata only when requested or under a clearly bounded policy.
- Make independent whole-disk indexing an explicit, configurable capability. Define scope, idle/sleep behavior, battery/thermal limits and active-job resource cost.
- Separate resident memory, process footprint, virtual address space, shared system resources, compressed memory and disk caches. Use one repeatable metric for gates and report helpers separately; do not sum shared memory naïvely. Memory pressure supplies system context. [R33: DOC]
- Avoid background CPU polling for unchanged folders when suitable change notifications exist; retain a reconciliation strategy for providers/events that are incomplete.

### 15.4 Benchmark design to agree before implementation

| Workload | Fixture | Measurements to record |
|---|---|---|
| Idle launch | One local folder, previews closed | Baseline footprint, time to useful UI, idle CPU/I/O |
| Ordinary browsing | Repeated navigation through 1,000-entry mixed folders | Peak/settled footprint, latency distribution, retained growth |
| Many tabs | 20 tabs including repeated and different locations | Incremental memory/tab, shared versus duplicate work |
| Large folder | 100,000 controlled entries | First rows, full listing, sort time, scroll stalls, peak memory |
| Images/PDFs | Controlled large dimensions/pages; thumbnail sizes | Decode peak, cache bounds, release after closing pane |
| Search churn | 100 changing/cancelled queries | First result, completion, stale-result correctness, retained growth |
| Remote storage | Latency/disconnect fixture | UI blocking, cancellation time, request count and memory |
| File operations | Many small files, large file, partial failures | Buffer bounds, responsiveness, journal growth, recovery correctness |
| Optional index | Known volume/content corpus | Index RAM/disk, initial cost, incremental cost, idle CPU/energy |

Record target Mac/OS, release configuration, fixture generator/version, cold versus warm cache, active services, sampling interval and repeat count. Compare baseline and changed versions on the same setup. Opening many tabs and then closing them should reach a bounded settled plateau; not every cached byte must immediately return to the launch baseline. “Green memory pressure” alone does not excuse unlimited growth. Prior draft latency numbers are discussion targets, not requirements or measured results.

## 16. Failure states and accessibility

### 16.1 Required states — PROP

| State | Preserve | Explain/action |
|---|---|---|
| Empty | Real location, controls | Empty versus zero results; creation if writable |
| Loading | Shell and navigation | Work in progress; progressive rows; cancel/back |
| No matches | Query, scope, filters | Coverage complete/partial and clear/change-scope action |
| Denied | Attempted path and valid history | Actual reason; authorized access path if available |
| Missing | Identity and attempted location | Parent/back/choose; never fake empty |
| Disconnected | Server/volume/account identity | Reconnect/retry; no blind destructive replay |
| Partial enumeration | Valid rows and selection | Unsearched/unreadable subtrees and retry scope |
| Read-only | Browsing | Why writing is unavailable; choose destination |
| Metadata unknown | Item identity | Unknown/loading/unsupported separately |
| Preview failed | Name and metadata | Explicit open action; no automatic editor launch |
| Conflict | Frozen sources/destination | Scoped decision; defer/cancel semantics recorded |
| Interrupted job | Per-item results | Completed/pending/uncertain; safe review and retry |

### 16.2 Accessibility requirements — PROP

Every command has a usable name and keyboard path; focus is distinct from selection; disabled actions have explanations; pane splitters have keyboard resizing alternatives. Announce location, sort/group, selection count, job completion and actionable errors. Throttle progress announcements; do not announce every thumbnail update.

Support VoiceOver, larger text, increased contrast, reduced motion/transparency, keyboard-only operation, localized strings, RTL layout, IME composition and multiple monitor configurations. A missing pointer hover cannot hide essential paths or full names. Test each interaction through accessible roles/states and actual keyboard focus, not only screenshot appearance. Native table/outline semantics should remain inspectable even if styling closely follows Windows.

## 17. Reference audit and acceptance plan

### 17.1 Four independent dimensions of completion

1. **Vision completeness:** agreed direction, proposals and non-goals are explicit.
2. **Reference completeness:** all applicable surfaces/behaviors recorded against the manifest.
3. **Specification completeness:** each requirement has Mac behavior, state/error rules and acceptance tests.
4. **Implementation verification:** only after authorized development and executed tests.

This document advances the first and third and provides documentation-based evidence for the second. It does not complete the direct reference audit or the fourth.

### 17.2 Reference fixture catalog

Use disposable controlled fixtures when observation is authorized. Record expected names/metadata rather than changing real user files.

- Name corpus: ordinary, long, no-extension, multiple suffix, hidden, leading/trailing whitespace where legal, punctuation, case variants, natural numbers/leading zeros, NFC/NFD, accents, emoji and non-Latin names.
- Type corpus: folders, empty files, text, Markdown, PDF, office documents, image, audio, video, archive, link/alias, executable/app package, special provider item.
- Metadata corpus: equal dates/sizes, unknown/unsupported fields, timezone/DST boundaries, large byte sizes, sparse file, nontrivial permissions and xattrs.
- Locations: writable/read-only local, sensitive/insensitive filesystem, external FAT/exFAT, SMB with two same-named shares, cloud online/offline, archive and virtual collection.
- Failure fixtures: deny access, disconnect, destination changed mid-prompt, disk quota/full volume, vanished source, busy item, partial cancellation and crash interruption.

The Mac fixture cannot represent all Windows naming combinations and vice versa. Keep paired fixture manifests and document intentional incompatibilities.

### 17.3 Procedure matrix

For every relevant surface cross: no selection/single/multiple/mixed; pointer/keyboard/accessibility; known/unknown/provider metadata; complete/partial/offline; normal/large text; theme; resize/overflow. Not every Cartesian combination is necessary, but every omitted combination needs a risk-based rationale. Capture observation before inventing a desired result.

### 17.4 Acceptance record schema

```text
Test ID and requirement IDs:
Evidence label and Windows observation ID:
Accepted Mac adaptation / approved difference:
Fixture and initial state:
Action sequence:
Expected visible output:
Expected focus / selected IDs / anchor / history / scroll:
Expected filesystem or provider effect:
Expected cancellation / partial result / error:
Expected memory/CPU/I/O bounds for this workload:
Actual result and evidence:
Status: specified / observed / implemented / passed / failed / not applicable
```

### 17.5 Essential task scenarios

| Test | User task | Pass condition proposal |
|---|---|---|
| T01 | Expand and browse hierarchy | Expansion, focus and activation remain distinct |
| T02 | Back/Forward/Up across tabs | Correct independent history and restored context |
| T03 | Enter invalid/quoted/network path | Valid resolution or editable specific error; no unintended execution |
| T04 | Switch tabs with search/selection | State remains correctly scoped |
| T05 | Read similar long filenames | Full name and extension reachable without repeated resizing |
| T06 | Change sort/group/columns | Explicit ordering; stable selection; no disk I/O per comparison |
| T07 | Revisit folder with override | Correct rule and persistence explained |
| T08 | Range/disjoint selection after updates | Stable IDs and correct anchor semantics |
| T09 | Right-click a selected batch | Menu targets intended items without losing batch |
| T10 | Rename dotfile/case-only/conflict | Input retained; destination rules respected; no overwrite surprise |
| T11 | Cut, change clipboard, cancel | Source preserved; stale marks cleared |
| T12 | Copy promised/virtual content | Bounded streaming and correct target results |
| T13 | Cross-volume move and cancellation | No premature source deletion; partial outcomes recorded |
| T14 | Merge or replace folders | Distinct decisions; no unrequested subtree loss |
| T15 | Change destination while prompt open | Stale confirmation cannot clobber new data |
| T16 | Recover interrupted operation | Uncertain work reviewed before retry |
| T17 | Undo after an external edit | External edit preserved or explicit conflict |
| T18 | Search with missing coverage | Partial status and scope visible |
| T19 | Mixed AQS query/localized properties | Explicit documented semantics or unsupported-query explanation |
| T20 | Preview a cloud-only large file | Download policy and memory lifecycle respected |
| T21 | Paste into library | Actual destination follows explicit default or requests choice |
| T22 | Remove a collection source/recent entry | Membership/history changes; file retained |
| T23 | Delete on nonrecycling provider | Permanent consequence explicitly chosen |
| T24 | Same-name network shares | Correct server/account identity used |
| T25 | Extract/create/modify each archive | Format-specific capability and no unsafe extraction |
| T26 | Offline device/cloud disconnect | No UI hang or fictional complete result |
| T27 | Keyboard and VoiceOver task sequence | Locate, inspect, move and recover without pointer |
| T28 | Large directory and event churn | Useful progress, stable interaction and bounded resources |
| T29 | Repeated previews/search/tab closure | Memory settles to documented bounds; no monotonic retained growth |
| T30 | Quit/close during active work | User-visible, consistent job lifetime and outcomes |

These are unexecuted acceptance requirements. They do not imply a built app or successful test runs.

## 18. Review findings and open decisions

### 18.1 Corrections to earlier planning

| Earlier ambiguity | Correct interpretation |
|---|---|
| Two presentation presets described as specified | Unapproved proposal; Explorer reference remains primary |
| Exact point sizes and delays | Candidate design values, not reverse-engineered measurements |
| Generic natural sorting assumed equivalent | Need pinned-build output corpus and property-specific ordering |
| Selected folder may be confused with paste destination | Destination is an explicit resolved location with documented context rules |
| Copy success might imply all work completed | Need per-item outcomes, cancellation and partial-result handling |
| Cut represented as a Boolean | Need source/target intent and cross-app protocol behavior |
| Every virtual surface can be treated like a folder | Collections, libraries, Trash, devices and providers need capabilities/destinations |
| Every readable archive can also be created/modified | Each operation/format/variant needs a separate entry |
| A progress/timer API implies transfer pause/resume | Actual engine/provider support must be demonstrated |
| A promised-file URL means completed content | Callback error and partial-output state must be checked |
| All provider actions are available through File Provider | Public access by unrelated browser apps must be established |
| Low RAM means one arbitrary universal MB number | Use workload/metric/hardware-specific agreed budgets and growth tests |
| 234 items meant complete Windows knowledge | Initial inherited requirements; documentation and observation coverage remain distinct |

### 18.2 Blocking questions for a perfect-fidelity claim

Exact Windows manifest; current menu/pane/default dimensions; selected/focus/anchor edge semantics; persisted view precedence; sorting outputs; all Folder Options; archive mutation; provider/device/account surfaces; app-quit job behavior; Trash restore feasibility; Mac cloud-control APIs; exact keyboard policy; agreed deviations; and measured resource budgets.

None of these prevent useful planning. They prevent an honest claim that Explorer has already been perfectly reverse engineered. Further web browsing cannot substitute for missing direct observations of undocumented behavior.

### 18.3 Decision log for future review

Use `DEC-ID | date | user decision/proposal | alternatives | reason | affected requirements | evidence | accepted by`. Current accepted decisions are only those in section 1. Defer stack and release estimates until enough reference and capability evidence exists. Do not treat this specification as an automatic implementation queue.

### 18.4 Next documentation-only work

Complete the reference manifest and observation records if a Windows reference becomes available. Atomize menus/options and service-dependent commands into observed requirements. Review the first concrete design decisions with the user. Continue source checking where evidence can resolve uncertainty; record when uncertainty requires a real platform experiment. Preserve this file as the portable master specification.

## 19. Source register

Links are primary sources except clearly labeled user reports. A source supports its stated finding, not every proposed behavior in the surrounding section. Retrieval limitations are recorded. API pages can be historical even when available today. All links were consulted in this research pass, including previously consulted context rechecked on November 7 where indicated. No Windows UI observation evidence exists yet.

<a id="r01"></a>
**R01. [File Explorer overview](https://support.microsoft.com/en-us/windows/experience/fileexplorer/file-explorer-in-windows)** — DOC; retrieved/search context. Pins, Home/This PC organization and account conditions; not exhaustive UI.

<a id="r02"></a>
**R02. [Accessible File Explorer navigation](https://support.microsoft.com/en-us/accessibility/windows/use-a-screen-reader-to-explore-and-navigate-file-explorer-in-windows)** — DOC; full relevant sections read. Regions, activation and keyboard navigation. Keep Windows 11/10 sections separate.

<a id="r03"></a>
**R03. [Windows keyboard shortcuts](https://support.microsoft.com/en-us/accessibility/windows/keyboard-shortcuts-in-windows)** — DOC; current Explorer section read. Reference key anchors; exact contextual behavior still needs testing.

<a id="r04"></a>
**R04. [Shell namespace](https://learn.microsoft.com/en-us/windows/win32/shell/namespace-intro)** — SDK/DOC; retrieved. Filesystem and virtual objects share a namespace; special objects need distinct treatment.

<a id="r05"></a>
**R05. [Folder enumeration and identity](https://learn.microsoft.com/en-us/windows/win32/shell/folder-info)** — SDK; retrieved. Shell item identities, display names, enumeration and attributes; not a Mac implementation guide.

<a id="r06"></a>
**R06. [Windows Property System](https://learn.microsoft.com/en-us/windows/win32/properties/windows-properties-system)** — SDK; retrieved. Extensible metadata model; no promise every property is available or writable.

<a id="r07"></a>
**R07. [Logical string comparison](https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/nf-shlwapi-strcmplogicalw)** — SDK; retrieved. Numeric digit handling and release-dependent ordering; not proof of every Explorer comparator.

<a id="r08"></a>
**R08. [Multiple sort columns](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifolderview2-setsortcolumns)** — SDK; retrieved. API supports sort-descriptor sequences; UI gesture requires observation.

<a id="r09"></a>
**R09. [Windows settings catalog](https://learn.microsoft.com/en-us/windows/configuration/windows-backup/catalog)** — DOC; Explorer section read. Documented settings subset; backup catalog is not the full Folder Options inventory.

<a id="r10"></a>
**R10. [Windows names and paths](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file)** — SDK; relevant sections read. Destination/filesystem-sensitive naming; shell conventions and reserved names.

<a id="r11"></a>
**R11. [Shell clipboard formats](https://learn.microsoft.com/en-us/windows/win32/shell/clipboard)** — SDK; relevant sections read. Representations and preferred/performed effects; Mac pasteboard is a separate protocol.

<a id="r12"></a>
**R12. [Shell transfer scenarios](https://learn.microsoft.com/en-us/windows/win32/shell/datascenarios)** — SDK; relevant sections read. Existing versus virtual/streamed files, optimized moves and asynchronous transfer.

<a id="r13"></a>
**R13. [IFileOperation CopyItem](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperation-copyitem)** — SDK; retrieved. Declares an operation; execution is separate.

<a id="r14"></a>
**R14. [IFileOperation flags](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperation-setoperationflags)** — SDK; retrieved. Undo/recycle/collision/elevation/metadata policy flags; not uniform observed UI behavior.

<a id="r15"></a>
**R15. [IFileOperation execution](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperation-performoperations)** — SDK; retrieved. Success code can coexist with cancellation; distinguish aborted and complete results.

<a id="r16"></a>
**R16. [Advanced Query Syntax](https://learn.microsoft.com/en-us/windows/win32/search/-search-3x-advancedquerysyntax)** — SDK; grammar/locale sections read. Property queries, Boolean semantics, canonical names and localized labels; version-aware reference.

<a id="r17"></a>
**R17. [Explorer context-menu extensions](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)** — SDK; retrieved. Modern commands and associations differ; heavy work should not block menu creation.

<a id="r18"></a>
**R18. [2026 Explorer context-menu rollout](https://blogs.windows.com/windows-insider/2026/08/17/improving-file-explorer-context-menu-faster-simpler-and-more-customizable/)** — ROLLOUT; retrieved. Conditional redesign, middle-click and presentation changes; verify GA target separately.

<a id="r19"></a>
**R19. [Preview handlers](https://learn.microsoft.com/en-us/windows/win32/shell/preview-handlers)** — SDK/HIST; retrieved. Read-only content preview, process separation and unloading; not a Mac plugin ABI.

<a id="r20"></a>
**R20. [Thumbnail handlers](https://learn.microsoft.com/en-us/windows/win32/shell/thumbnail-providers)** — SDK/HIST; retrieved. Caching, freshness and sizing architecture; historical dimensions are not immutable.

<a id="r21"></a>
**R21. [Gallery introduction](https://support.microsoft.com/en-gb/servicing/os/configuration-updates/2023/08/september-26-2023-windows-configuration-update)** — HIST; relevant excerpt read. Collection sources and chronological Gallery introduction; current UI needs audit.

<a id="r22"></a>
**R22. [About Libraries](https://learn.microsoft.com/en-us/windows/win32/shell/library-leverage-to-manage-folders)** — SDK/HIST; retrieved. Aggregated real folders and indexing-related limitations; historical behavior context.

<a id="r23"></a>
**R23. [Windows Libraries management](https://learn.microsoft.com/en-us/windows/client-management/client-tools/windows-libraries)** — DOC; relevant excerpt read. Default save location and failure when no writable destination remains.

<a id="r24"></a>
**R24. [Archive operations](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/zip-and-unzip-files)** — DOC; rechecked; relevant content read in prior pass. ZIP and format/encryption limits; not proof of every archive mutation capability.

<a id="r25"></a>
**R25. [Improved Windows search](https://www.microsoft.com/en-us/windows/learning-center/find-files-fast-with-improved-search)** — DOC; retrieved. Copilot+ and supported-format/language conditions; not universal baseline search behavior.

<a id="r26"></a>
**R26. [Spotlight indexing](https://support.apple.com/en-us/102321)** — DOC; retrieved. Index coverage/process and unexpected-result diagnosis; proposed fallback is our design.

<a id="r27"></a>
**R27. [Mac keyboard shortcuts](https://support.apple.com/en-us/102650)** — DOC; rechecked; relevant content read in prior pass. Native Finder operations, keyboard differences and Quick Look context.

<a id="r28"></a>
**R28. [Network sharing and mapping](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/file-sharing-over-a-network-in-windows)** — DOC; rechecked; relevant content read in prior pass. Discovery, sharing, mapped destinations and reconnect configuration.

<a id="r29"></a>
**R29. [OneDrive Files On-Demand](https://support.microsoft.com/en-gb/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows)** — DOC; retrieved/search context. Placeholder versus downloaded/offline availability; provider/version-specific.

<a id="r30"></a>
**R30. [File History and previous versions](https://support.microsoft.com/en-gb/windows/experience/backup-recovery/backup-and-restore-with-file-history)** — DOC; rechecked; relevant content read in prior pass. Backup-service dependency; not a restore capability created by the browser alone.

<a id="r31"></a>
**R31. [Mac sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)** — PARTIAL; current JS shell, Markdown retrieval failed; prior official excerpt retained. API feasibility reference; independently verify deployment-target access behavior.

<a id="r32"></a>
**R32. [Mac filesystem performance](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system)** — PARTIAL; current JS shell, Markdown retrieval failed; prior official excerpt retained. Context for asynchronous/coordinated access and avoiding I/O; not benchmark evidence.

<a id="r33"></a>
**R33. [Activity Monitor memory interpretation](https://support.apple.com/en-mide/guide/activity-monitor/actmntr1004/mac)** — PARTIAL; primary search excerpt; full page rate-limited. Memory pressure is system context; proposed process metrics and budgets need measurement.

<a id="r34"></a>
**R34. [File Provider](https://developer.apple.com/documentation/fileprovider)** — PARTIAL; JS shell; Markdown retrieval unsupported. Research target only; does not establish third-party control over another provider.

<a id="r35"></a>
**R35. [Quick Look Thumbnailing](https://developer.apple.com/documentation/quicklookthumbnailing)** — PARTIAL; JS shell; Markdown retrieval unsupported. Research target only; exact lifecycle and supported types require API/deployment validation.

<a id="r36"></a>
**R36. [Per-item copy completion](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperationprogresssink-postcopyitem)** — SDK; official detailed search excerpt read. Actual result differs from queued-call result; collision handling can change the destination name.

<a id="r37"></a>
**R37. [File operation progress sink](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ifileoperationprogresssink)** — SDK; official detailed search excerpt read. Per-item notification and unsupported timer methods; API presence is not pause/resume support.

<a id="r38"></a>
**R38. [Receive promised Mac files](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver/receivepromisedfiles(atdestination:options:operationqueue:reader:))** — SDK; official detailed search excerpt read. Asynchronous readiness/error callback; failed promises can leave partial or corrupt files.

<a id="r39"></a>
**R39. [Promised filenames](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver/filenames)** — SDK; official detailed search excerpt read. Filename list may be empty until reception is initiated; preflight UI must tolerate it.

Current Apple Markdown retrieval failed in the web tool due to unsupported content type; a direct HTTPS read also failed DNS resolution in the execution environment. Those pages are marked partial, not fully reviewed. No approval escalation or access workaround was used.


### Finder research context retained from the earlier pass

These linked discussions were consulted earlier and retained as attributed qualitative research; they were not re-audited for every comment in this pass:

- [View-default persistence discussion](https://www.reddit.com/r/MacOS/comments/107w7fq/how_do_i_once_and_for_all_set_all_of_finders/).
- [File organization/grouping discussion](https://www.reddit.com/r/MacOS/comments/1dxi0e6).
- [Windows-switcher requests](https://www.reddit.com/r/MacOS/comments/1t8abq8/macos_finder_my_biggest_issues_for_usability_i/).
- [Transfer and navigation frustrations](https://www.reddit.com/r/MacOS/comments/1lgvcf7/what_do_people_dislike_about_finder/).
- [Filename/column readability discussion](https://talk.tidbits.com/t/adjusting-column-width-in-tahoes-finder/32791).
- [Provider badges and truncated names](https://community.dropbox.com/en/discussion/861120/dropbox-sync-icons-cause-filename-truncation-in-finder-column-view-auto-sizing-on-macos).

## 20. Complete inherited feature register

All 234 original IDs and intended outcomes are embedded below, so this document stands on its own. These are our inherited candidate requirements, including deliberate improvements and platform adaptations. They are not verbatim Microsoft specifications, direct reference evidence, implementation commitments, or a declaration of current completion.

For every row: **implementation = not started; exact Windows observation = pending where applicable**. Earlier source-family pointers are superseded for evidence claims by section 19 and future observation records. Requirements that describe desired safety/resource behavior remain proposals even when strongly recommended.


### Navigation and location

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-001 | Explorer parity candidate | Back and forward | Keep independent history per tab and restore selection and scroll position. |
| FE-002 | Explorer parity candidate | Up to parent | Parent navigation selects the folder just left. |
| FE-003 | Explorer parity candidate | Breadcrumb path | Each ancestor is clickable; long paths collapse without losing access. |
| FE-004 | Explorer parity candidate | Breadcrumb sibling menus | Audit dropdown contents and navigation behavior on the reference build. |
| FE-005 | Explorer parity candidate | Editable address bar | Click or keyboard-focus to paste and edit a complete path. |
| FE-006 | Explorer parity candidate | Path completion and history | Completion is cancellable and does not overwrite typed input unexpectedly. |
| FE-007 | Explorer parity candidate | Folder tree | Tree remains separate from the contents list; expansion does not navigate by itself. |
| FE-008 | Explorer parity candidate | Expand tree to current folder | Preference controls automatic expansion and scrolling to the active folder. |
| FE-009 | Explorer parity candidate | Navigation pane visibility | Hide or resize sidebar without losing its state. |
| FE-010 | Explorer parity candidate | Show all folders and libraries | Audit tree visibility options and hidden nodes. |
| FE-011 | Explorer parity candidate | Refresh | Explicit refresh reconciles changes while preserving valid selection. |
| FE-012 | Explorer parity candidate | Keyboard and mouse navigation | Audit Alt arrows; Backspace; mouse back/forward; and focus traversal. |
| FE-013 | macOS adaptation | Mac path resolution | Accept POSIX paths; file URLs; tilde paths; and mounted volumes without inventing drive letters. |
| FE-014 | macOS adaptation | Network path entry | Recognize SMB URLs and offer a clear translation for pasted UNC paths. |
| FE-015 | Explorer parity candidate | Unavailable locations | Show permission; missing; disconnected; and loading states distinctly. |
| FE-016 | Proposed improvement | Navigation gestures | Provide configurable trackpad gestures without conflicting with horizontal scrolling. |

### Tabs windows and session

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-017 | Explorer parity candidate | Create close and switch tabs | Audit shortcuts; close buttons; tab overflow; and keyboard order. |
| FE-018 | Explorer parity candidate | Reorder tabs | Dragging a tab preserves its complete navigation state. |
| FE-019 | Explorer parity candidate | Tab context menu | Audit duplicate; close others; close right; and supported reference commands individually. |
| FE-020 | Explorer parity candidate | Detach and merge tabs | Record whether and how the pinned Windows build supports each action before promising parity. |
| FE-021 | Explorer parity candidate | Multiple windows | Each window has independent tabs; layout; focus; and history. |
| FE-022 | Explorer parity candidate | Open folder in new tab or window | Context menus and modifier clicks have explicit predictable destinations. |
| FE-023 | Explorer parity candidate | Middle-click behavior | Audit on folders; breadcrumbs; Home items; and tab close targets. |
| FE-024 | Explorer parity candidate | Session restoration | Audit reference restore settings; implement opt-in restore of tabs and locations. |
| FE-025 | macOS adaptation | Mac window lifecycle | Define last-window close; app quit; Dock reopen; fullscreen; and native tiling behavior. |
| FE-026 | Proposed improvement | Monitor placement | Restore window bounds to an available display and recover after display removal. |
| FE-027 | Proposed improvement | Saved workspaces | Optional named tab sets; clearly identified as beyond baseline Explorer. |

### Views density and readability

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-028 | Explorer parity candidate | Details view | Name; date; type; and size align in resizable sortable columns. |
| FE-029 | Explorer parity candidate | List view | Audit horizontal flow; keyboard movement; and scrolling behavior. |
| FE-030 | Explorer parity candidate | Small medium large extra-large icons | Audit each distinct size and responsive grid behavior. |
| FE-031 | Explorer parity candidate | Tiles and content views | Audit metadata; line count; spacing; and selection for both views. |
| FE-032 | Explorer parity candidate | Compact view | Persist density independently from thumbnail and text sizes. |
| FE-033 | Explorer parity candidate | Thumbnail sizing | Resize thumbnails without blocking navigation or losing selection. |
| FE-034 | Explorer parity candidate | Status bar | Show total items; selected count; and available selected-size information. |
| FE-035 | Explorer parity candidate | Column chooser | Add remove reorder resize and auto-fit columns; keep Name readable. |
| FE-036 | Explorer parity candidate | Metadata-specific columns | Audit image; audio; video; document; and cloud-status column sets. |
| FE-037 | Explorer parity candidate | Ascending and descending sorting | Audit natural numeric ordering; tie-breaking; locale; and folders placement. |
| FE-038 | Explorer parity candidate | Grouping | Explicit group choice; collapsible groups; clear distinction from sorting. |
| FE-039 | Explorer parity candidate | Column header filters | Audit which headers support filters and how combined filters are represented. |
| FE-040 | Explorer parity candidate | Folder view templates | Audit General; Documents; Pictures; Music; Videos; and apply-to-folders behavior. |
| FE-041 | Explorer parity candidate | Per-folder settings | Remember view; sort; grouping; density; columns; and widths using stable location identity. |
| FE-042 | Explorer parity candidate | Folder Options | Inventory General; View; Search; defaults; reset; and apply actions. |
| FE-043 | Explorer parity candidate | Advanced Folder Options audit | Enumerate every actual checkbox and radio control on the pinned build; include title paths; hidden drives; process isolation; restore windows; preview handlers; and selection options if present. |
| FE-044 | Explorer parity candidate | Hidden items and extensions | Explicit toggles; coherent icon and filename presentation. |
| FE-045 | Explorer parity candidate | Protected system items | Audit Windows distinction; provide a truthful Mac-specific setting and explanation. |
| FE-046 | Explorer parity candidate | Single-click or double-click activation | Expose a preference and test selection separately from activation. |
| FE-047 | Explorer parity candidate | Item checkboxes | Optional checkbox selection works with keyboard and pointer. |
| FE-048 | Explorer parity candidate | Light and dark appearance | Preserve hierarchy; contrast; separators; and disabled states. |
| FE-049 | Proposed improvement | Name-first width policy | Reserve space for names; allow auto-fit and full-name reveal without shifting rows. |
| FE-050 | Proposed improvement | Text size and row height | Independent controls; no clipped glyphs at supported sizes. |
| FE-051 | Proposed improvement | Readable numeric metadata | Right-align sizes; distinguish logical versus allocated size and unknown versus zero. |
| FE-052 | Proposed improvement | Stable global view defaults | Explicit hierarchy: app default; folder-type default; per-folder override. |
| FE-053 | Proposed improvement | Folders first with every sort | Keep folder placement independent of the active sort column. |
| FE-054 | Proposed improvement | Predictable icon arrangement | Auto-arrange by default; avoid overlapping or offscreen dropped items. |
| FE-055 | Proposed improvement | Long-name alternatives | Full-name tooltip plus optional wrapping; extension remains identifiable. |

### Selection focus and input

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-056 | Explorer parity candidate | Single range and disjoint selection | Audit Ctrl and Shift anchors; preserve expected ranges after sorting. |
| FE-057 | Explorer parity candidate | Select all none and invert | Commands operate on current visible results with clear counts. |
| FE-058 | Explorer parity candidate | Marquee selection | Audit starting on whitespace; autoscroll; and modifier behavior. |
| FE-059 | Explorer parity candidate | Type-to-select | Incremental filename selection does not unexpectedly start a global search. |
| FE-060 | Explorer parity candidate | Arrow Home End Page navigation | Audit focus versus selection; Shift extension; and offscreen movement. |
| FE-061 | Explorer parity candidate | Tree keyboard expansion | Audit Left Right plus minus and recursive expansion shortcuts. |
| FE-062 | Explorer parity candidate | Focus traversal | Tab and Shift-Tab traverse address; search; tree; list; panes; and toolbar coherently. |
| FE-063 | Explorer parity candidate | Rename editing | F2 selects base name; Escape cancels; Enter commits; extension changes are explicit. |
| FE-064 | Explorer parity candidate | Sequential rename | Audit Tab and Shift-Tab renaming adjacent items. |
| FE-065 | Explorer parity candidate | Drag initiation | Dragging an unselected item versus selection follows documented consistent rules. |
| FE-066 | macOS adaptation | Keyboard presets | Windows-style file-list controls plus Mac-style preset; editable text keeps normal editing shortcuts. |
| FE-067 | macOS adaptation | Mac delete-key distinction | Distinguish Backspace navigation from forward Delete and Cmd-Delete; label bindings clearly. |
| FE-068 | macOS adaptation | IME and international keyboards | Composition text is not consumed by shortcuts or type-to-select. |

### Home special locations and collections

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-069 | Explorer parity candidate | Home page | Audit sections; layout; account dependence; filters; and context actions. |
| FE-070 | Explorer parity candidate | Quick access folders | Pin unpin reorder and navigate without duplicating real files. |
| FE-071 | Explorer parity candidate | Favorite files | Distinguish file favorites from pinned folders and recent activity. |
| FE-072 | Explorer parity candidate | Recent files and frequent folders | Audit scope; provider coverage; removal; clearing; and privacy controls. |
| FE-073 | Explorer parity candidate | Recommended and shared content | Audit account-dependent Windows features; define provider-backed Mac equivalent. |
| FE-074 | Explorer parity candidate | This PC | Mac equivalent lists real internal/external volumes and mounted shares with storage figures. |
| FE-075 | Explorer parity candidate | Gallery | Audit chronological collection; source folders; date navigation; and actions separately from icon view. |
| FE-076 | Explorer parity candidate | Libraries | Audit aggregated folders; default save location; optimization; and library management. |
| FE-077 | Explorer parity candidate | Recycle Bin | Mac Trash equivalent with source location; deletion date where available; restore; and empty. |
| FE-078 | Explorer parity candidate | Network root | Browse available servers; distinguish discovery from mounted shares. |
| FE-079 | Explorer parity candidate | Special shell locations | Inventory Control Panel; printers; device nodes; and shell-address destinations; map or hand off. |
| FE-080 | macOS adaptation | Mac known folders | Home; Desktop; Documents; Downloads; Applications; Pictures; Music; and Movies use native URLs. |
| FE-081 | macOS adaptation | Finder tags and smart collections | Preserve tag access and offer saved collections without relocating files. |
| FE-082 | Proposed improvement | Control Home clutter | Allow choosing startup location and hiding optional feed-like sections. |

### File actions clipboard and menus

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-083 | Explorer parity candidate | Open and Open With | Use installed application associations and support multi-item selection. |
| FE-084 | Explorer parity candidate | Copy cut and paste | Cut marks intent only; source remains until successful move commit. |
| FE-085 | Explorer parity candidate | Copy path | Specify plain path versus URL and quoted-path variants; no accidental command execution. |
| FE-086 | Explorer parity candidate | Rename | Handle conflicts; forbidden names; extension changes; and case-only rename. |
| FE-087 | Explorer parity candidate | New folder | Immediate inline naming; collision handling; and cancellation. |
| FE-088 | Explorer parity candidate | New file templates | Audit Windows New menu and provide useful Mac templates without false empty Office documents. |
| FE-089 | Explorer parity candidate | Multi-file rename | Audit baseline sequential numbering; optional advanced rename is a separate enhancement. |
| FE-090 | Explorer parity candidate | Delete and permanent delete | Trash by default; accurately warn when Trash is unavailable. |
| FE-091 | Explorer parity candidate | Undo and redo | Audit supported actions; clearly expose what will be undone and when it is unsafe. |
| FE-092 | Explorer parity candidate | Create shortcut and paste shortcut | Use Mac aliases; explicitly distinguish aliases from symbolic links. |
| FE-093 | Explorer parity candidate | File folder background tree menus | Inventory each surface; multi-selection; mixed types; and unavailable commands. |
| FE-094 | Explorer parity candidate | Command bar | Audit New; file actions; Sort; View; overflow; and contextual commands. |
| FE-095 | Explorer parity candidate | Modern and legacy menu variants | Audit Show more options; Shift context menu; and customization on exact reference build. |
| FE-096 | Explorer parity candidate | Send to and Share | Translate supported destinations to Mac services and share targets. |
| FE-097 | Explorer parity candidate | Print rotate set wallpaper | Offer only valid type-specific operations and preserve metadata where possible. |
| FE-098 | Explorer parity candidate | Open terminal here | Open the chosen terminal at a folder without constructing unsafe shell command strings. |
| FE-099 | Explorer parity candidate | Properties | Show a coherent native inspector plus an explicit Reveal/Get Info handoff. |
| FE-100 | Explorer parity candidate | Pin to Start or taskbar | Record Windows action; map to appropriate app favorites or Dock handoff where supported. |
| FE-101 | macOS adaptation | External app clipboard interoperability | Copy files to/from Finder and common Mac apps; validate move intent separately. |
| FE-102 | macOS adaptation | File promises and dropped attachments | Handle promised files with progress; cancellation; and unavailable-provider errors. |
| FE-103 | Proposed improvement | Advanced batch rename | Preview transformations; conflicts; numbering; and undo before applying. |

### Drag and drop

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-104 | Explorer parity candidate | Same-volume versus cross-volume defaults | Audit Explorer defaults; show Copy or Move feedback before dropping. |
| FE-105 | Explorer parity candidate | Modifier overrides | Support explicit copy move and alias intents with visible cursor feedback. |
| FE-106 | Explorer parity candidate | Right-button drag menu | Audit Windows choices and provide accessible Mac pointer equivalent. |
| FE-107 | Explorer parity candidate | Tree and breadcrumb drop targets | Destination highlights unambiguously; dropped files go to the highlighted location. |
| FE-108 | Explorer parity candidate | Hover expansion and autoscroll | Expand folders and switch tabs after a cancellable delay. |
| FE-109 | Explorer parity candidate | Drop into background | Uses current folder; never a stale selected folder. |
| FE-110 | Explorer parity candidate | Cross-window and cross-app drag | Preserve valid file URLs and negotiate supported operations. |
| FE-111 | Explorer parity candidate | Multi-item drag | Overlapping source selections do not duplicate or recursively copy the same content. |
| FE-112 | Explorer parity candidate | Invalid drop prevention | Reject self-descendant moves; unavailable targets; and incompatible intents. |
| FE-113 | macOS adaptation | Packages and cloud drops | Do not silently expand app bundles or hydrate entire cloud trees. |

### Operations progress conflicts and recovery

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-114 | Explorer parity candidate | Copy and move progress | Audit counts; bytes; speed; time estimate; and detailed graph presentation. |
| FE-115 | Explorer parity candidate | Pause resume cancel | Define per-file and job granularity; expose unsupported resume cases honestly. |
| FE-116 | Explorer parity candidate | Concurrent operations | Audit grouping and controls; UI stays responsive while jobs run. |
| FE-117 | Explorer parity candidate | Replace skip compare keep both | Conflict choices show both paths; sizes; dates; and affected-item scope. |
| FE-118 | Explorer parity candidate | Folder merge | Define recursive merge separately from replacing the destination folder. |
| FE-119 | Explorer parity candidate | Apply to remaining conflicts | Scope applies only to this operation and the chosen conflict category. |
| FE-120 | Explorer parity candidate | Permission and locked-file failures | Name the failing item; explain action; allow retry or skip where valid. |
| FE-121 | Explorer parity candidate | Out of space and destination loss | Stop safely; report partial work; retain recoverable source data. |
| FE-122 | Explorer parity candidate | Cross-volume move | Delete source only after the corresponding destination copy has succeeded. |
| FE-123 | macOS adaptation | Metadata preservation | Specify permissions; timestamps; tags; xattrs; resource forks; and unsupported destination behavior. |
| FE-124 | macOS adaptation | Symlinks hard links and sparse files | Define preservation and traversal per operation and filesystem capability. |
| FE-125 | Proposed improvement | Persistent job journal | After crash show completed; pending; failed; and uncertain items without automatically replaying unsafe writes. |
| FE-126 | Proposed improvement | Operation history | Every job exposes source; destination; item results; and human-readable error details. |
| FE-127 | Proposed improvement | Explicit queue controls | Order; defer; and limit concurrency separately from claimed Explorer parity. |
| FE-128 | Proposed improvement | Safe retry | Retry unfinished items; verify destinations; never assume same name means same content. |
| FE-129 | Proposed improvement | Undo protection | Do not overwrite intervening edits or delete another app's replacements during undo. |
| FE-130 | Proposed improvement | Optional copy verification | Offer content verification for critical jobs; distinguish completion from verified integrity. |

### Search and filtering

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-131 | Explorer parity candidate | Current folder search | Scope is visible and recursive behavior is explicit. |
| FE-132 | Explorer parity candidate | Whole-computer search | Clearly identify included and excluded locations and permissions. |
| FE-133 | Explorer parity candidate | Name and content modes | Separate exact filename intent from content and metadata matches. |
| FE-134 | Explorer parity candidate | AQS property queries | Audit name; extension; kind; dates; size; author; tags; Boolean; quoting; and ranges individually. |
| FE-135 | Explorer parity candidate | Search suggestions and history | Audit reference suggestions; allow clearing history. |
| FE-136 | Explorer parity candidate | Search options and refinement | Visible filters reflect active query and can be removed individually. |
| FE-137 | Explorer parity candidate | Search result details | Show containing folder; match reason; metadata; and open-location action. |
| FE-138 | Explorer parity candidate | Saved searches | Audit saved query persistence and choose a Mac format with stable scope identifiers. |
| FE-139 | Explorer parity candidate | Search settings edge cases | Audit non-indexed content; system folders; archive search; natural-language options; and localized query syntax before committing support. |
| FE-140 | Explorer parity candidate | Indexing integration | Report available coverage and avoid claiming all content is indexed. |
| FE-141 | Explorer parity candidate | Unindexed search | Direct scan fallback is cancellable and reports inaccessible subtrees. |
| FE-142 | Explorer parity candidate | Semantic and cloud search | Audit hardware; account; locale; and rollout dependencies; distinguish optional feature from baseline. |
| FE-143 | macOS adaptation | Spotlight metadata adapter | Use supported Mac search APIs with measured coverage and fallback behavior. |
| FE-144 | Proposed improvement | Why a result is absent | Expose permission; exclusion; offline; indexing; and unsupported content explanations when known. |
| FE-145 | Proposed improvement | Name-first ranking | Exact filename then prefix then substring; content results labeled separately. |
| FE-146 | Proposed improvement | Search freshness | Live changes reconcile without claiming completeness while enumeration is still running. |

### Preview metadata and properties

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-147 | Explorer parity candidate | Preview pane | Resize hide and preview supported file types without launching their editors. |
| FE-148 | Explorer parity candidate | Details pane | Multi-select summaries; metadata; and editable properties distinguish mixed values. |
| FE-149 | Explorer parity candidate | Thumbnail providers | Load lazily; cancel stale requests; cache without blocking folder enumeration. |
| FE-150 | Explorer parity candidate | General properties | Name; type; location; dates; logical size; allocated size; and item counts. |
| FE-151 | Explorer parity candidate | Detailed metadata | Audit EXIF; media duration; dimensions; authors; tags; ratings; and unsupported fields. |
| FE-152 | Explorer parity candidate | Metadata editing and removal | Audit writable properties per type; changes must preserve original content. |
| FE-153 | Explorer parity candidate | Security and ownership | Map Windows ACL concepts to actual Mac POSIX permissions and ACLs. |
| FE-154 | Explorer parity candidate | Sharing and customization properties | Audit sharing; folder icon; optimization; and tab-specific settings. |
| FE-155 | Explorer parity candidate | Previous Versions | Record Windows backup integration; investigate Time Machine handoff rather than claiming native parity. |
| FE-156 | Explorer parity candidate | Read-only hidden compression encryption attributes | Separate UI concepts from actual per-filesystem capabilities. |
| FE-157 | Explorer parity candidate | Version digital signature and compatibility tabs | Audit applicability; Mac signature display and app handoffs need separate designs. |
| FE-158 | Explorer parity candidate | Downloaded-file unblock and provenance | Audit Windows Properties Unblock; preserve Mac quarantine and Gatekeeper behavior rather than copying a security bypass control. |
| FE-159 | macOS adaptation | Quick Look | Space opens native preview; browsing selection updates preview predictably. |
| FE-160 | macOS adaptation | App bundles and packages | Open normally; Show Package Contents is explicit; avoid generic-folder damage. |
| FE-161 | macOS adaptation | Finder metadata | Read/write supported tags and comments; do not confuse them with portable embedded document metadata. |
| FE-162 | Proposed improvement | Cloud preview hydration control | Tell users when previewing requires a download and respect cancellation/provider state. |

### Archives and disk images

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-163 | Explorer parity candidate | ZIP browsing and extraction | Audit navigation; extract-all; individual extraction; destination choice; and collisions. |
| FE-164 | Explorer parity candidate | ZIP creation | Define selections; relative paths; naming; cancellation; and preservation limits. |
| FE-165 | Explorer parity candidate | Modify existing archives | Audit adding; deleting; renaming; editing; and drag/drop into archives separately for each format; do not assume all formats behave like ZIP. |
| FE-166 | Explorer parity candidate | 7z TAR and compressed TAR | Audit extraction versus creation formats against the reference build; do not infer symmetry. |
| FE-167 | Explorer parity candidate | RAR extraction | Record supported variants; do not promise RAR creation. |
| FE-168 | Explorer parity candidate | Archive compression options | Audit method; level; symbolic link handling; and creation wizard where present. |
| FE-169 | Explorer parity candidate | Encrypted archive behavior | Record Windows limits; optional password support is separate from baseline parity. |
| FE-170 | Explorer parity candidate | Archive safety | Reject traversal paths; unsafe link targets; excessive expansion; and unintended overwrites. |
| FE-171 | Explorer parity candidate | Mount and eject ISO | Audit Windows behavior; use supported macOS disk-image services for ISO/DMG. |
| FE-172 | Explorer parity candidate | Optical burn and disc tools | Inventory Explorer commands; capability gate by attached hardware and Mac support. |
| FE-173 | macOS adaptation | Archive metadata portability | Explain when Finder tags; resource forks; or permissions cannot be represented. |

### Drives devices network and sharing

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-174 | Explorer parity candidate | Internal external and removable volumes | Live connect/disconnect; filesystem; capacity; free space; and read-only state. |
| FE-175 | Explorer parity candidate | Safely eject | Show busy errors and update all affected tabs when a volume disappears. |
| FE-176 | Explorer parity candidate | Network discovery and connect | Separate server discovery; authentication; and share mounting. |
| FE-177 | Explorer parity candidate | Map and disconnect network locations | Persist server/share identity and reconnect intent; Mac mount points remain truthful. |
| FE-178 | Explorer parity candidate | Network credentials | Use Keychain; never store secrets in preferences or job logs. |
| FE-179 | Explorer parity candidate | Offline and slow shares | Timeout/cancel does not hang unrelated local browsing. |
| FE-180 | Explorer parity candidate | Local folder sharing controls | Mac System Settings handoff initially; no false Windows ACL compatibility. |
| FE-181 | Explorer parity candidate | Share sheet and nearby sharing | Use native Mac sharing and AirDrop where supported; Windows Nearby Sharing is a distinct protocol. |
| FE-182 | Explorer parity candidate | Phone camera and portable devices | Audit MTP/PTP nodes; Mac support may require a dedicated provider. |
| FE-183 | Explorer parity candidate | Format rename and disk tools | Inventory format; cleanup; optimization; error checking; and map to supported Mac system tools. |
| FE-184 | Explorer parity candidate | Encrypted and locked drives | Inventory BitLocker-related shell actions; Mac unlock flows require separate providers. |
| FE-185 | Explorer parity candidate | Offline Files and enterprise storage | Record Windows Sync Center/DFS/provider dependencies and whether Mac equivalent is feasible. |
| FE-186 | Explorer parity candidate | Administrative file-operation prompts | Audit UAC retry flows; design bounded Mac authorization only for supported actions without running the whole browser as root. |
| FE-187 | macOS adaptation | Multiple identically named shares | Identify by server plus share plus stable volume identity; never resolve by display name alone. |
| FE-188 | macOS adaptation | Filesystem capabilities | Detect APFS; HFS+; exFAT; FAT; SMB; and read-only NTFS limitations rather than promising writes. |

### Cloud and account integrations

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-189 | Explorer parity candidate | Cloud locations in navigation | Show installed providers and account identity without inventing a new sync engine. |
| FE-190 | Explorer parity candidate | Online-only available and pinned states | Expose provider-backed state and distinguish unknown state. |
| FE-191 | Explorer parity candidate | Download and free-space actions | Only offer provider-supported commands with truthful completion state. |
| FE-192 | Explorer parity candidate | Sync errors and conflicts | Display known provider failures and offer provider-specific handoff. |
| FE-193 | Explorer parity candidate | Share links and permissions | Use provider APIs where available; do not equate a local path with a share link. |
| FE-194 | Explorer parity candidate | Cloud version history | Provider-specific capability; audit Windows entry points and Mac API availability. |
| FE-195 | Explorer parity candidate | Multiple accounts and business content | Distinguish personal/work accounts and unavailable authentication. |
| FE-196 | Explorer parity candidate | Home cloud recommendations | Optional provider-backed surface; do not claim parity from local recent files. |
| FE-197 | macOS adaptation | iCloud Drive | Read actual native state; coordinate downloads; respect optimized storage. |
| FE-198 | macOS adaptation | File Provider integration | Validate availability of status; context actions; eviction; and enumeration per installed provider. |

### Accessibility localization and preferences

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-199 | Explorer parity candidate | Keyboard-only operation | Every browsing and core file action works without a pointing device. |
| FE-200 | macOS adaptation | VoiceOver | Names; roles; selected states; sort directions; progress; and errors are announced. |
| FE-201 | macOS adaptation | Contrast reduce motion transparency | Respect Mac accessibility settings and preserve focus visibility. |
| FE-202 | Explorer parity candidate | Text scaling and zoom | No essential controls disappear at larger supported sizes. |
| FE-203 | Explorer parity candidate | Focus after refresh and navigation | Focus stays coherent when items change; dialogs close; and panes toggle. |
| FE-204 | Explorer parity candidate | Localization and RTL | Layouts; truncation; shortcuts; numbers; dates; and paths work in RTL and non-Latin locales. |
| FE-205 | Explorer parity candidate | Preferences persistence | Settings apply at the documented app/window/tab/folder scope. |
| FE-206 | Explorer parity candidate | Recent activity privacy | Clear and disable recording without deleting actual files. |
| FE-207 | macOS adaptation | Permission guidance | Explain denied access accurately; request only needed access; Full Disk Access does not bypass all protections. |
| FE-208 | Proposed improvement | Export and import preferences | Portable configuration excludes credentials and machine-specific sensitive paths by default. |

### System integration and expansion boundary

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-209 | Explorer parity candidate | Third-party context actions | Windows COM extensions cannot run directly; design a separate Mac action/provider contract. |
| FE-210 | Explorer parity candidate | Third-party columns and property pages | Inventory extensibility; isolate slow or failing plugins. |
| FE-211 | Explorer parity candidate | Namespace providers | Local files; virtual collections; archives; network; and devices share a capability interface. |
| FE-212 | Explorer parity candidate | Preview and icon handlers | Use Mac equivalents; record unsupported Windows-only formats explicitly. |
| FE-213 | Explorer parity candidate | Explorer address commands and shell names | Inventory commands; expose safe Mac aliases/handoffs; never execute typed text implicitly. |
| FE-214 | Explorer parity candidate | WSL Linux and developer storage nodes | Record installed-feature-dependent Linux namespaces and Dev Drive actions; map only to actual configured Mac providers or a documented system boundary. |
| FE-215 | Explorer parity candidate | Windows shortcut file compatibility | Audit LNK and URL shortcut behavior; distinguish parsing/import from Mac alias creation and never assume executables are portable. |
| FE-216 | Explorer parity candidate | Windows desktop taskbar and Start host | Track as OS-shell boundary; not a standalone Mac file-browser capability. |
| FE-217 | Explorer parity candidate | System Open and Save dialogs | Track as separate system integration boundary; this app cannot automatically replace every other app's dialogs. |
| FE-218 | macOS adaptation | Reveal in Finder and Services | Interoperate with Mac apps without claiming global Finder replacement. |
| FE-219 | macOS adaptation | Launch URLs and CLI entry | Open a supplied location safely with clear permission errors. |
| FE-220 | macOS adaptation | Signed notarized universal releases | Plan Intel/Apple silicon packaging subject to minimum-OS decision. |
| FE-221 | Proposed improvement | Public open-source governance | Choose license; publish build instructions; contribution guide; roadmap; and issue templates. |
| FE-222 | Proposed improvement | Privacy by default | No filename/content telemetry; crash reports redact paths and require deliberate user submission. |

### Reliability and acceptance coverage

| ID | Classification | Candidate capability | Intended outcome / reference question |
|---|---|---|---|
| FE-223 | macOS adaptation | Unicode and normalization | Test NFC/NFD; emoji; combining marks; RTL names; and localized display names. |
| FE-224 | macOS adaptation | Case sensitivity and case-only rename | Test both case-sensitive and insensitive volumes with no accidental overwrite. |
| FE-225 | macOS adaptation | Long and unusual paths | Test deep paths; leading dots; spaces; punctuation; and filesystem-specific limits. |
| FE-226 | macOS adaptation | Filesystem races | Handle deletion; replacement; rename; and mount loss between enumeration and operation. |
| FE-227 | macOS adaptation | Symbolic link loops and packages | Enumeration has explicit traversal policy and cannot recurse indefinitely. |
| FE-228 | Proposed improvement | Large directory responsiveness | Proposed target: 100k local entries remain navigable with asynchronous metadata and measurable UI latency. |
| FE-229 | Proposed improvement | Stable live updates | New files appear without jumping the viewport or clearing unrelated selections. |
| FE-230 | Proposed improvement | Failure-injection suite | Test disk-full; denied access; crash; network loss; cancellation; and locked destinations on disposable fixtures. |
| FE-231 | Proposed improvement | Provider capability tests | Unsupported actions are explained rather than silently emulated or hidden after failure. |
| FE-232 | Proposed improvement | Reference parity audit | Each E item gains exact Windows build; recording; expected behavior; result; and acknowledged deviation. |
| FE-233 | Proposed improvement | User task validation | Windows users can locate; compare; move; restore; and recover files without coaching. |
| FE-234 | Proposed improvement | Release completeness report | No row disappears; each is implemented; deferred; handed off; unsupported; or rejected with reason. |


## 21. Additional research requirements

These append to, and refine, existing IDs rather than silently changing their meaning. Confidence is SDK/DOC for the cited platform fact and PROP/AUDIT for the requested Mac behavior. None has been implemented.

| ID | Refines | Requirement | Evidence context | Required result / audit |
|---|---|---|---|---|
| FE-235 | FE-037 | Multi-key view sorting | R08 | Record reference ordered sort descriptors and actual UI gesture; preserve stable selections without assuming Shift-click. |
| FE-236 | FE-134 | Mixed AQS Boolean precedence | R16 | Test mixed AND/OR and parentheses against documented left-to-right semantics and actual reference results. |
| FE-237 | FE-134; FE-204 | Localized versus canonical query properties | R16 | Keep internal property identity independent of UI language; test localized labels and reject unsupported syntax explicitly. |
| FE-238 | FE-076; FE-088 | Virtual collection write destination | R22; R23 | Resolve an explicit default real destination or request one before paste/new; handle no writable source. |
| FE-239 | FE-069–FE-076 | Projection removal versus physical deletion | R01; R21–R23 | Pin/history/source-membership removal must remain distinct from deleting the underlying file. |
| FE-240 | FE-101; FE-102 | Streamed and promised transfer negotiation | R11; R12 | Represent source/target effects and virtual content without buffering every file in RAM; validate Mac interoperability separately. |
| FE-241 | FE-114; FE-125 | Execution success versus aborted/partial result | R13–R15 | Track per-item completion, abort and uncertainty; never derive batch completion solely from a top-level success return. |
| FE-242 | FE-149; FE-212 | Handler lifecycle and stale completion | R19; R20 | Discard obsolete preview/thumbnail work and release resources when no longer needed; provider failures cannot freeze browsing. |
| FE-243 | FE-149; FE-228 | Decoded-image memory cost | R20; R35 (API research only) | Budget decoded bytes and requested dimensions, not compressed file size; test oversized media and release behavior. |
| FE-244 | FE-189–FE-198 | Browser access to provider capabilities | R29; R34 (API research only) | Establish which public APIs an unrelated browser can actually use for each provider/account; unsupported is explicit. |
| FE-245 | FE-153; FE-156 | Attributes versus effective write permission | R06; R10 (context only) | Test actual Mac directory access; do not map a Windows folder read-only checkbox directly to effective permissions. |
| FE-246 | FE-223–FE-226 | Display ordering versus persistent identity | R05; R07; R10 | Separate display labels/collation from exact item/entry identity across rename, hard links, normalization and replacement. |
| FE-247 | FE-232 | Pinned reference environment manifest | R18; R25 | Record build/update/rollout/locale/account/providers/extensions and attach manifest IDs to every observation. |
| FE-248 | FE-041–FE-043 | Preference apply/reset scope | R09 (subset only) | Document scope and actual inherited source before applying/resetting; changes never modify user-file contents. |
| FE-249 | FE-097; FE-093 | Type-specific menu behavior | R06; R17 | Capture print/rotate/background/open-with behavior by type and mixed selection; do not infer universality. |
| FE-250 | FE-117; FE-129 | Revalidation after a delayed conflict decision | PROP | If destination or source changes while a decision is pending, detect it and prevent stale overwrite/undo. |
| FE-251 | FE-024; FE-149; FE-228 | Global cache and inactive-tab budgets | PROP | Caches share app-wide byte bounds; inactive tabs retain compact navigation state without duplicate heavy data. |
| FE-252 | FE-228; FE-234 | Cold/warm and retained-growth benchmark protocol | R33 (metric context only) | Record hardware/configuration/fixture/metric/repeats; test many cycles and helpers; agree targets before enforcing numbers. |
| FE-253 | FE-232; FE-233 | Documentation-first reference procedure | USER; PROP | Continue planning by default; use only authorized disposable observations; receiving the specification does not authorize building. |
| FE-254 | FE-079; FE-182; FE-214 | Conditional namespace applicability | R04; R05 | Keep device/Linux/enterprise/extension capabilities tied to actual environment and Mac equivalent; avoid universal-folder assumptions. |
| FE-255 | FE-117; FE-125 | Actual committed destination identity | R36 | Record the destination object/name returned after collision handling; never assume the requested name was committed unchanged. |
| FE-256 | FE-102; FE-120 | Promise completion versus partial output | R38 | Check readiness/error and partial-file state; an existing destination URL cannot by itself mark a promise successful. |
| FE-257 | FE-115 | Progress callbacks versus pause capability | R37 | Do not infer pause/resume support from timer method names; specify and prove engine/provider support. |
| FE-258 | FE-102; FE-113 | Incomplete file-promise preflight metadata | R39 | Allow unknown promised names/types before acceptance; do not start reception merely to populate a hover preview. |


## 22. Final review record

### Review passes actually completed

| Pass | Work performed | Outcome |
|---|---|---|
| 1 — Published reference coverage | Read/rechecked primary Windows UI, keyboard, settings, namespace, archive, cloud and backup material | Expanded overlooked collection, settings and conditional-feature questions |
| 2 — Behavioral correctness | Reviewed operation API, clipboard/virtual transfer, collation, sort descriptors, property system and AQS semantics | Added explicit cancellation, identity, query and destination rules; separated API ability from UI evidence |
| 3 — Vision and Mac/resource fit | Reconciled this research with explicit user scope, open-source direction, UI priorities and low-RAM constraint | Kept planning-only authority; left stack/presets/budgets provisional; specified resource workloads and Mac capability gaps |
| 4 — Document consistency and coverage | Checked contradictions, evidence labels, portable structure, source references and all inherited IDs; incorporated targeted follow-up source findings | Preserved 234 original entries and added 24 refinements; no implementation or hands-on Windows tests claimed |

### Structural verification

The delivered file was checked for exactly one definition of each FE-001–FE-258 requirement, the presence of the full vision and scope constraints, source-label definitions, no unresolved assembly placeholders, and a complete section order. These are document integrity checks, not functional or visual application tests.

### Completion boundary

Documentation research and a consolidated, reviewed specification have been produced. Perfect reverse engineering has not been established. The exact Windows reference environment and direct observations remain outstanding, and platform-specific integration questions are explicit. Further research should be guided by those gaps rather than repeatedly rereading the same sources and claiming increased certainty without new evidence.

