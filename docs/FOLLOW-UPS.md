# Follow-ups

Smaller review findings that didn't hold up a release. Only data loss, security holes and crashes block one; everything
else lands here and is worked through when convenient. Delete a line when it is done.

## Worth doing first

- Tags: on a non-English Mac the seven system tag names may not match what Finder writes
  (`Sources/Arbor/Features/FinderTags/FinderTagStore.swift`).
- Services: a path handed over by another app has no length limit before each component is looked up, so a very long
  one is slow (`Sources/ArborCore/ExternalOpen.swift`).
- Services: an outside open that passes the check but fails to load shows Home with no explanation
  (`Sources/Arbor/Window/BrowserWindowController+Navigation.swift`).
- Services: the rule that keeps Services off non-item menus is four separate, uncommented lines; it should be one helper.
- Column filters: the "Filtered" address bar item and the rewritten Tab order have no regression check.
- Workspaces: `WorkspacePrompts.inform` repeats `NSAlert.show` (`Sources/Arbor/Features/Workspaces/WorkspacePrompts.swift`).
- Tests that can't fail: two checks in `scripts/windows-shortcut-checks.sh` (the opened PDF and `.url` rows) and the
  "Return during composition doesn't rename" check in `scripts/behavior-checks.sh`.
- address-history: `Sources/Arbor/Views/IconProvider.swift`: Opening the address bar's recent list can still touch the disk or a share on the main thread, now for entries restored from a previous launch.
- long-names: `Sources/Arbor/Features/VisualParity/DetailsViewController+NameWrap.swift`: A Name column or window resize while scrolled down a long folder moves the list to different rows.

## Small tidy-ups

- workspaces: `Sources/ArborCore/Workspaces/Workspace.swift`: WorkspaceName.clean accepts a name made only of invisible format scalars.
- workspaces: `docs/DECISIONS.md`: The new area-table row says DEC-workspaces runs 1–9, but docs/features/workspaces.md defines DEC-workspaces-1 through DEC-workspaces-10.
- workspaces: `Sources/ArborCore/Workspaces/WorkspaceOpenPlan.swift`: The job key includes `workspace.tabs.hashValue`, and this is the only reason `SessionTab` gained `Hashable`.
- workspaces: `Sources/Arbor/Features/Workspaces/WorkspaceOpener.swift`: `replacing:
- workspaces: `Sources/ArborCore/Workspaces/Workspace.swift`: WorkspaceName.clean accepts a name made only of invisible format characters.
- windows-shortcuts: `Sources/Arbor/Features/WindowsShortcuts/WindowsShortcutOpener.swift`: Opening any symbolic link now calls Shortcuts.resolve(end) on the main thread, and resolve runs an uncapped Data(contentsOf:) when the link's end has a .webloc extension.
- windows-shortcuts: `Sources/Arbor/Features/Properties/VersionCopies.swift`: Previous Versions is a route for opening a .url that skips the FE-215 checks.
- windows-shortcuts: `Sources/ArborCore/WindowsShortcuts/WindowsShortcutPolicy.swift`: DEC-winlink-10 says macro-enabled Office files are refused, but only the OOXML macro types (docm, xlsm, xlsb, pptm) are.
- windows-shortcuts: `scripts/windows-shortcut-checks.sh`: This is a new top-level suite for one feature.
- windows-shortcuts: `Sources/Arbor/Features/WindowsShortcuts/WindowsShortcutOpener.swift`: `refuseIfLinkToShortcut` wants only an alias's target but calls `Shortcuts.resolve`, which also handles .webloc by reading the whole file with `Data(contentsOf:)` before any alias check.
- windows-shortcuts: `Sources/ArborCore/Search/SearchEvaluator.swift`: This re-implements the precedence that `ExplorerTypeName.name` owns and leaves out the alias case.
- windows-shortcuts: `docs/features/windows-shortcuts.md`: DEC-winlink-10 says `WindowsShortcutPolicy.documentFamilies` holds the refused formats.
- windows-shortcuts: `Sources/ArborCore/WindowsShortcuts/ShellLink.swift`: LinkInfoFlags are bare `0x1` and `0x2` (lines 178 and 184), and the header and LinkInfo field offsets are bare numbers (20, 44, 52, then 4, 8, 16, 20, 24, 28, 32).
- tags-pane: `Sources/Arbor/Features/Search/SpotlightSearch.swift`: Every Spotlight hit of every search now fetches kMDItemUserTags and caps it, but only FinderTagDiscovery reads Hit.tags.
- tags-pane: `Sources/Arbor/Features/FinderTags/FinderTagStore.swift`: The rule behind DEC-tags-7, that a failed or partial run must not shrink the list, is decided in app code with no test:
- tags-pane: `Sources/ArborCore/Search/TagCollectionQuery.swift`: Two conditions in tagName(in:) cannot change the result.
- tags-pane: `Sources/Arbor/Features/FinderTags/FinderTagsDebug.swift`: The documented example `taglabels:Red=FF0000|Blue=` does not do what it says, here and under Script steps in docs/features/finder-tags.md.
- tags-pane: `docs/features/finder-tags.md`: The file map at the top of the area document leaves out Sources/ArborCore/Properties/TagRefreshPolicy.swift and Tests/ArborTests/FinderTagsFeatureTests.swift, so it does not list everything that be...
- services: `Sources/Arbor/Features/Services/ServicesSelection.swift`: Two of the rules documented for what may be sent have no check.
- services: `docs/features/qa-core.md`: The rerun note says behavior-checks has 79 checks, but scripts/behavior-checks.sh now has 87.
- services: `Tests/ArborCoreTests/ItemActionsTests.swift`: The new private scratchFolder() helper duplicates Fixture, which is in the same test target and already used by this file (for example line 48).
- services: `Sources/Arbor/Views/DetailsViewController.swift`: While an inline rename is open, right-clicking a different item or empty space now shows no menu at all, because menu(for:) returns nil here and at ItemGridView.swift:499.
- services: `docs/features/qa-core.md`: The rerun note says behavior-checks has 79 checks, but a full run of scripts/behavior-checks.sh on this branch printed 87 pass lines.
- column-filters: `docs/features/grouping.md`: The area document's Code and Tests lines were not updated.
- column-filters: `Sources/Arbor/Features/DetailsDepth/DateRangeFilterView.swift`: The message "Choose a range of up to 100 years." hard-codes the limit defined by `DayRange.maxDayCount`, so changing the constant makes the UI text wrong without any compile error or test failure.
- column-filters: `Sources/Arbor/Features/DetailsDepth/DetailsHeaderViews.swift`: `dateRangeProvider` is a settable closure with a `{ nil }` default for a value its own comment says is read once.
- details-marquee: `Sources/Arbor/Features/DetailsDepth/DetailsMarquee.swift`: In Details, the path that treats every candidate as a hit above MarqueeDrag.preciseHitLimit has no automated check.
- details-marquee: `Sources/Arbor/Views/DetailsViewController.swift`: This change widens shownName so hit-testing can use it, but the same extension-hiding logic also exists as ItemGridView.displayName (ItemGridView.swift:270) and a private shownName in HomeFileList....
- details-marquee: `Sources/Arbor/Features/IconViews/ItemGridDrawing.swift`: Replacing drawMarquee() introduced Optional.map purely for a side effect, discarding a Void? result, on lines 117 and 126.
- keyboard-preset: `Sources/Arbor/Features/Accessibility/FileListKeys.swift`: ItemSurface(c)?.prepareToOpen() is an indirect and misnamed way to cancel the grid's slow-click rename.
- keyboard-preset: `Sources/Arbor/Features/FolderOptions/FolderOptionsPrefs.swift`: The new choices check looks the item up again with FolderOptionsCatalog.item(key), which rebuilds and scans the whole catalog.
- keyboard-preset: `Sources/Arbor/Features/Accessibility/AccessibilityDebug.swift`: keyEvent's new isRepeat:
- address-history: `Sources/ArborCore/PathCompletionHistory.swift`: History rows filter hidden items by a leading dot only, while the listing treats `isHidden` as true for flagged items too (`.isHiddenKey`, for example `~/Library`).
- long-names: `scripts/behavior-checks.sh`: The check "every row keeps the full-name tooltip" can never fail.
- long-names: `Sources/Arbor/Views/DetailsViewController.swift`: topVisibleName probes `rowsViewport.minY + table.rowHeight / 2`, which assumes one-line rows.
