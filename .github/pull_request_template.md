## What this changes

<!-- One or two sentences. Link issues with "Fixes #123". -->

Requirement IDs: <!-- FE-###, or "none" -->

## How I checked it

- [ ] `scripts/test.sh` passes
- [ ] `scripts/build-app.sh debug` builds with no warnings
- [ ] Scripted UI check (`ARBOR_HEADLESS=1 ARBOR_SCRIPT=…`) for UI behavior, in light and dark; describe it below
- [ ] New logic in `Sources/ArborCore` has unit tests

<!-- What you ran and what you saw. Screenshots for visual changes (light and dark). -->

## File safety (if this touches copying, moving, renaming, deleting or undo)

- [ ] No source is removed before its copy has succeeded
- [ ] Nothing is overwritten without an explicit decision
- [ ] Move to Trash never silently becomes a permanent delete
- [ ] Undo refuses rather than overwrites later changes
- [ ] Tests use disposable fixture folders only

## Notes for reviewers

<!-- Anything Windows does that this deliberately does differently, and why. Docs updated (docs/features/…, DECISIONS)? -->
