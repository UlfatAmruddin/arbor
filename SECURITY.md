# Security policy

Arbor is a file manager: it copies, moves, renames and deletes files, mounts network shares and
opens archives. Bugs that lose data or reach files the user didn't choose are treated as security
issues.

## Reporting a vulnerability

Please report privately, not in a public issue:

1. Go to the repository's [Security ▸ Advisories ▸ New draft advisory](../../security/advisories/new) page
   (the repository's **Security** tab ▸ **Report a vulnerability**).
2. Describe what happens, the macOS version, the Arbor version (Arbor ▸ About Arbor), and the
   steps to reproduce it. Use made-up file names and paths in your report; don't send private files.

You'll get an answer within a week. We'll work with you on a fix, credit you in the release notes
if you want, and publish an advisory once a fixed release is out.

## What counts

Examples of things to report privately:
- Data loss or overwriting without the user's decision (for example a conflict, undo or Trash path
  that deletes or replaces data it shouldn't).
- Following a symbolic link, archive entry or crafted name to read or write outside the folder the
  user chose (path traversal when extracting archives, for example).
- Running a command or program from file names, typed addresses, archive contents or network
  shares.
- Leaking file names, paths or contents off the Mac (Arbor has no telemetry and makes no network
  connections of its own, except to servers the user connects to).
- Problems with the signed release itself (signature, notarization, the update or download path).
- An imported settings file changing anything outside the list in docs/features/settings-transfer.md.

Distribution builds (the downloadable releases) ignore the `ARBOR_*` test variables described in
TESTING.md. A way to make a distribution build read them is worth reporting; problems that need them
set affect only local development builds.

Ordinary bugs and crashes that don't put data at risk can go in a normal issue.

## Supported versions

Only the latest release gets security fixes.

## Verifying downloads

Each release lists the SHA-256 checksum of its disk image. Signed releases can be checked with
`spctl --assess --type open --context context:primary-signature -v Arbor-<version>.dmg`.
