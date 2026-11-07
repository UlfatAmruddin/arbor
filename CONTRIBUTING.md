# Contributing to Arbor

Thanks for helping. A few ground rules keep the project trustworthy.

## Before you start
- Read `docs/SPEC.md` sections 0–3 and `docs/DECISIONS.md`.
- Link your change to requirement IDs (`FE-###`). Don't delete or renumber IDs. New requirements get new IDs appended to the end.
- Describe Windows behavior only from evidence (documentation or a recorded observation, spec §2.3), never from memory or from third-party tools such as the Files app or PowerToys.

## Safety rules for file operations
- Never delete a source before its copy has succeeded.
- Never overwrite without an explicit user decision, and re-check the destination after the decision.
- "Move to Trash" must never silently become a permanent delete.
- Undo must refuse rather than overwrite changes made since.
- Tests use disposable fixture folders only (see `Fixture` in the tests), never real user files or the real Trash.

## Workflow
```bash
scripts/test.sh               # must pass
scripts/build-app.sh debug    # must build without warnings
```
Logic belongs in `Sources/ArborCore` with unit tests. UI goes in `Sources/Arbor`. For UI behavior, add a scripted check with `ARBOR_SCRIPT` (see `Sources/Arbor/DebugScript.swift`) and describe what you verified in the pull request.

## Privacy
No telemetry, analytics or network calls. Never log file names or paths outside the user's own machine.
