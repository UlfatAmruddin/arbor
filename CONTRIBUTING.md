# Contributing to Arbor

Thanks for helping. A few ground rules keep the project trustworthy.

## Reporting bugs and ideas
- Use the issue templates: **Bug report** or **Feature request** ([new issue](../../issues/new/choose)). Include the Arbor version from Arbor ▸ About Arbor and your macOS version.
- Anything that could lose data or expose files is a security problem: report it privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Before you start
- Read `docs/SPEC.md` sections 0–3 and `docs/DECISIONS.md`.
- Link your change to requirement IDs (`FE-###`). Don't delete or renumber IDs. New requirements get new IDs appended to the end.
- Describe Windows behavior only from evidence (documentation or a recorded observation, spec §2.3), never from memory or from third-party tools such as the Files app or PowerToys.
- For anything bigger than a small fix, open an issue first so we can agree on the approach.

## Safety rules for file operations
- Never delete a source before its copy has succeeded.
- Never overwrite without an explicit user decision, and re-check the destination after the decision.
- "Move to Trash" must never silently become a permanent delete.
- Undo must refuse rather than overwrite changes made since.
- Tests use disposable fixture folders only (see `Fixture` in the tests), never real user files or the real Trash.

## Workflow
You need macOS 14 or later and the Command Line Tools (`xcode-select --install`); Xcode is optional.

```bash
scripts/test.sh               # must pass
scripts/build-app.sh debug    # must build without warnings
```
Logic belongs in `Sources/ArborCore` with unit tests. UI goes in `Sources/Arbor`. For UI behavior, add a scripted check with `ARBOR_SCRIPT` (see `TESTING.md` and `Sources/Arbor/DebugScript.swift`) and describe what you verified in the pull request.

## Code standards
Security is part of writing the code, not a pass at the end. Treat every file name, file content, archive field, metadata value and network reply as hostile.

- **Never trap on outside data.** No `!`, `try!`, or plain arithmetic and `Int(_:)` on values from disk or the network: use `Int(checked:)`, `saturatingAdd` and explicit bounds checks.
- **Act on what you checked.** For anything that deletes, moves, overwrites or changes permissions, hold a descriptor (`O_NOFOLLOW`, `fstatat`, `unlinkat`) instead of checking a path and using it again.
- **Bound what you read.** Cap the bytes, entries and depth taken from a file, a tool's output or a server, and fail with a clear message.
- **Run tools safely.** `Process` with an absolute path and an argument array, `--` before names, and never a shell. Typed text and file contents never execute.
- **Open through `SystemOpen`.** A URL or path that comes from a file needs the same checks and confirmation as any other outside input.
- **Keep secrets out.** Passwords live in the Keychain and never reach logs, history, preferences or exported settings.

To keep the code easy to change:

- A feature is one folder in `Sources/Arbor/Features` with an `ExplorerFeature` and one registration line. Use extension points; change shared files only to add a point.
- Logic without UI goes in `Sources/ArborCore`, as small pure types with tests. UI code stays thin.
- Search before adding a helper, and give each type one job.
- No disk or network work on the main thread; cancel work that has gone stale.
- User-visible strings go through `L10n` as whole sentences: `L10n.tr`, `L10n.format` with `%@` for the parts that vary, `L10n.plural(one:other:…)` for a sentence with a count, `L10n.plainFormat` for a generated file name. Never assemble a sentence from translated pieces or pick a word with `count == 1`; `StringCoverageTests` fails on a literal shown without `L10n`. Comments are one line and say why, not what.

## Adding a language
A language is one folder of data files. Copy `Resources/en.lproj/Localizable.strings` to `Resources/<language>.lproj/Localizable.strings` (for example `fr` or `pt-BR`) and translate the right-hand side of each line; keys are the English text and stay as they are. Nothing else changes: the build copies every `.lproj` and declares it, and a key you leave out shows in English.

Sentences with a count ("3 items were copied") are in `Resources/en.lproj/Localizable.stringsdict`. Copy it to the same folder and, for each entry, replace the `one` and `other` forms with the forms your language uses: any of `zero`, `one`, `two`, `few`, `many` and `other` (the [CLDR plural rules](https://www.unicode.org/cldr/charts/latest/supplemental/language_plural_rules.html) say which; `other` is required, so Japanese needs only that). Every form is a whole sentence and keeps the count, `%lld`, even where your language would leave it out.

- Keep the `%` parts: the same specifiers, of the same kind, as the English. `%1$@ … %2$@` numbers let you change the order. Write a percent sign as `%%`.
- `scripts/extract-strings.sh --check` (also run by `scripts/test.sh`) rejects unknown keys, empty values, wrong specifiers (in every plural form too) and malformed files, and reports how many strings aren't translated yet.
- Right-to-left languages mirror the app on their own. To check your layout, use the pseudo-languages in `TESTING.md`.
- Text that doesn't fit is a bug in Arbor rather than in the translation: report it.

## Pull requests
- Keep each pull request to one topic, with plain, descriptive commit messages.
- Fill in the pull request checklist. CI (`.github/workflows/ci.yml`) builds with no warnings, runs the tests and builds the disk image on every push and pull request; it must be green.
- Update `docs/features/<area>.md` (status, decisions, known gaps) when behavior changes.
- Art must be original (SF Symbols or drawn in code). Never add Microsoft icons, fonts or logos.

## Releases
Maintainers follow [docs/RELEASING.md](docs/RELEASING.md). The version lives in `VERSION`; don't change it in a feature pull request.

## Privacy
No telemetry, analytics or network calls. Never log file names or paths outside the user's own machine.

## License
By contributing, you agree that your contribution is licensed under the MIT License ([LICENSE](LICENSE)).
