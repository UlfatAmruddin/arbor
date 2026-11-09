# Finder tags in the navigation pane

Code: `Sources/Arbor/Features/FinderTags/`; logic in `Sources/ArborCore/Search/TagCollectionQuery.swift`,
`Sources/ArborCore/Properties/TagCatalog.swift`, `TagHarvest.swift` and `FinderMetadata.swift` (`FinderTag`, the tag
attribute). Tests: `Tests/ArborCoreTests/FinderTagsTests.swift`, group `finder-tags` in `scripts/behavior-checks.sh`.

## Status

| FE | What | Status | How verified |
|---|---|---|---|
| FE-081 | A collapsed **Tags** row after Network, Trash and Libraries. Children are the seven system tags in Finder's sidebar order, then custom tags that Spotlight knows about, each with its colour. A row opens an ordinary `tag:"name"` search of the Spotlight index, so nothing is relocated and every search feature applies: columns, coverage text, Search options, Refresh, Save Search (`.arborsearch`). "Show tags" in Folder Options (default on); "Expand to open folder" opens the section | Implemented, except what is listed under Known gaps | Unit tests (attribute parsing and bounds, query round trip, predicates, catalog determinism and cap, read budget). Headless: row order, Show tags on and off, seeded rows, in-place updates keeping expansion and the current-location mark without navigating, tab title, breadcrumb, search box, columns, Paste unavailable, whole-tag match on tagged fixtures, tree menu, Expand to open folder, VoiceOver label, light, dark, contrast, right-to-left and pseudo-localized snapshots. Not automated: the live Spotlight run, see Manual test |

Explorer has no tag section, so this is a Mac adaptation (spec FE-081) and makes no parity claim. It follows the nearest
documented patterns: an optional pane section is controlled by a Navigation pane option (reference §2.1), virtual nodes
offer Open in new tab and new window (§2.2), and a tag is a search property (§12.1).

## How it works

- **Rows.** `NavigationPaneExtras` builder `finder-tags.section`. A rebuild only reads memory. The root is a collapsed
  `.folder` node with preset children and opens "everything tagged"; a tag row is a `.place` node.
- **System tags** come from `NSWorkspace.fileLabels` and `fileLabelColors`, read on the main thread at first use and again when macOS posts that the labels changed (a few ms, no disk). A colour-only change updates the rows too.
- **Custom tags.** Expanding the root starts one background run, at most once a minute and never two at once (`TagRefreshPolicy`):
  `FinderTagDiscovery` wraps `SpotlightSearch` (`kMDItemUserTags == "*"cd`, 20,000 hits, 20 s). Names come from the query
  itself. The per-file attribute is read only to find the colour of a custom tag, for at most 3 files per name and 600
  files per run (`TagHarvest`), so a Mac that uses only system tags reads nothing.
- **Updating the tree.** A changed catalog goes through `NavigationPaneExtras.updateChildren`, which reloads only that
  node under the pane's navigation guard and re-marks the current location. `refreshAll` would collapse the tree.
- **Opening a row.** `SearchProvider` runs `tag:"name"` with no scope. Each Spotlight hit is checked again against the
  file's current tags, so a stale index entry can't appear. New and Paste are disabled because a collection has no
  destination (FE-238).

## Decisions

- **DEC-tags-1** On by default and collapsed: one row, no work until it is expanded. Provisional; flip the default in the catalog and `Prefs.navShowTags`.
- **DEC-tags-2** A tag whose name can't be searched for exactly is not listed, rather than listed and broken: names containing quotation marks (the tokenizer has no escape), exactly `[]`, edge spaces, control characters, direction overrides (they would display as different text), or over 255 UTF-8 bytes.
- **DEC-tags-3** Custom colours are read from each file's attribute because there is no public catalog. Finder's `FavoriteTagNames` preference is undocumented and not used.
- **DEC-tags-4** `.search` is reused instead of a new `Location` case, so there is no parallel provider. `TagCollectionQuery` is the only code that knows the query shape.
- **DEC-tags-5** A collection covers what Spotlight indexes, like whole-Mac search today. There is no scope, so "Show hidden files" has no effect on it: tagged items inside hidden folders and packages appear. Arbor adds no filter for the Trash or Time Machine volumes; macOS isn't expected to index either, which the manual test confirms.
- **DEC-tags-6** The catalog depends only on the tags inserted, not their order, because Spotlight's order isn't stable and an equal catalog must not reload the tree. Spelling: lowest by localized standard order. Colour: highest number. Cap: the 200 lowest folded names.
- **DEC-tags-7** A run keeps the custom rows already listed unless Spotlight finished gathering and returned hits. An empty answer can also mean Spotlight is off or refused the query, and a run stopped at the 20,000-hit limit saw only part of the index, so tags removed everywhere leave their rows until the next launch.

## Limits and failure behaviour

| Input or failure | Result |
|---|---|
| Spotlight off, query refused or timing out | The system rows and earlier custom rows stay; no alert. Opening a row shows the existing coverage text |
| 20,000 or more tagged files | The run stops at the limit and merges into the list instead of replacing it, so rows only get added. Tags whose files all fall past the limit may be missing until a run sees them |
| A read stuck on an unresponsive disk | The store abandons the run after 30 s, so later expansions can start a new one; work queued behind the stuck read is skipped |
| Protected folders | The Spotlight query needs no permission. A colour read of a custom-tagged file in Desktop, Documents, Downloads or on a removable volume can raise the macOS privacy prompt the first time. A denied read costs only that colour (FE-207) |
| Attribute over 64 KiB, unreadable or an unexpected shape | Treated as no colour |
| More than 64 tags on a file, more than 200 distinct custom tags | The extra ones are ignored |
| Symlink swapped in during a read | Not followed (`XATTR_NOFOLLOW`) |
| Short or empty `fileLabels` | Fewer rows; the root still opens all tagged items |

## Extension points

Uses `NavigationPaneExtras.builders`, `IconProvider.locationIconOverrides`, `NavigationPaneHooks.willReveal`,
`NavigationPaneHooks.decorateCell`, `NavigationPaneHooks.didExpand` (new), `DebugScript` steps and logger, and the
existing search registrations.

## Shared-file changes

`Features.swift` (slot), `Location.displayName` (one line, so tab, breadcrumb and provider title name the tag),
`FolderOptionsCatalog` (one option), `FinderMetadata` (tag attribute, `limit:` on `readAttribute`),
`SpotlightSearch.Hit.tags`, `SpotlightSearch.Outcome`, `SpotlightPredicate.escape` (`$`), `NavigationPaneController.replaceChildren`, `visibleNode` and the
`outlineViewItemDidExpand` signal, `NavigationHistory` and `NavRequest.back` (several steps, for Close search),
`SavedSearch.suggestedFileName(for: SearchRequest)`,
`NavigationPaneExtras.updateChildren`, `WindowHooks` and `ExtensionCatalog` (the new point).

## Script steps

`tagcatalog:Work=4|Home=0` replaces the whole list, so rows don't depend on this Mac's labels. `taglabels:Red=FF0000|Blue=`
replaces the system labels and colours. `treeexpand:<title>` expands a tree row. `log:` adds
`finder-tags: <expanded|collapsed|absent> rows=… discoveries=N marked=<row> refreshes=N changes=N`. Headless runs never start a
discovery, but `refreshes` still counts each request, so the expansion trigger is covered.

## Manual test

Temporary folders aren't indexed, so this needs a real Mac with Spotlight on:

1. In an indexed folder, tag files in Finder with a system tag and a custom coloured tag, and let Spotlight index them.
2. Expand Tags: the custom row appears with its colour (`mdls -name kMDItemUserTags <file>` shows what the index holds).
   If the index returns names without colours, the row should still get its colour from the file.
3. Open each row and press Refresh after removing a tag in Finder.
4. Exclude the folder in System Settings ▸ Spotlight and read the coverage text.
5. Tag a file in Documents on an account where Arbor has no access yet: check any prompt and that denying it costs only the colour.
6. Note whether a tagged item in the Trash or on a Time Machine volume appears, and update DEC-tags-5.

## Known gaps

- **Not automated:** the live run, the 30 s deadline and cancelling a run need a real index. `TagRefreshPolicy` and the request that reaches it are tested; the steps between are covered only by the manual test.
- **Not confirmed on a live index.** The shape of `kMDItemUserTags` on an indexed file could not be checked on the development Mac, whose index is read-only. The importer reports the attribute as `"Name\nN"` strings, and the code accepts that form as well as plain names, so either works; if the value were neither, no custom rows would appear.
- macOS has no public API for Finder's tag list, custom tag colours, favourites or order. A custom tag that no indexed file carries is not listed.
- Tags can't be renamed, recoloured or deleted system-wide through public API, so no such command exists (DEC-019).
- Collections cover only what Spotlight indexes: not unindexed volumes, most network shares, or folders excluded in System Settings.
- A collection isn't live. A file tagged or untagged after the search stays as it was until Refresh, and a new tag appears after a later expansion, once Spotlight has indexed it.
- Names with quotation marks or exactly `[]` aren't listed (DEC-tags-2). Allowing them needs a grammar change in `AQSParser`.
- When a flood of names passes the 200-tag cap (say, one extracted archive), the rest are dropped with no sign in the list, and they can crowd out real tags that sort after them.
- Rebuilding the pane (volumes, pins, options) collapses every expanded node except This Mac, including Tags and Libraries. This predates the feature.
- Dragging files onto a tag row, a tag picker in menus and colour badges on file rows are not part of this requirement. Editing tags stays in Properties and the Details pane.
