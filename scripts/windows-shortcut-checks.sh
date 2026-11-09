#!/usr/bin/env bash
# Headless checks for opening Windows .lnk and .url files (FE-215, docs/features/windows-shortcuts.md).
# Usage: scripts/build-app.sh debug && scripts/windows-shortcut-checks.sh
#   ARBOR_KEEP_FAILED=<dir>   move the logs and fixture into <dir> after a failure
#   Stale-bundle guard, one-suite-at-a-time lock, ARBOR_REBUILD: scripts/lib/app-bundle.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/app-bundle.sh
arbor_prepare_app windows-shortcut-checks.sh debug
FAILED=0

contains() {   # contains <name> <file> <fixed text>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then echo "pass  $1"; else
    echo "FAIL  $1: expected to contain “$3”"
    [ -f "$2" ] && grep -E "^(tabs|location|selected|sheet|system open|windows shortcuts)" "$2" | sed 's/^/        /'
    FAILED=1; fi
}

lacks() {   # lacks <name> <file> <fixed text>
  if [ -f "$2" ] && ! grep -qF -- "$3" "$2"; then echo "pass  $1"; else
    echo "FAIL  $1: did not expect “$3”"; FAILED=1; fi
}

R=$(arbor_mktemp_dir)
F="$R/F"
mkdir -p "$R/trash" "$F/sub" "$F/sub2" "$F/next.js"

# Writes a minimal MS-SHLLINK file: lnk <name> [relative=…] [local=…] [share=…] [args=…]
cat > "$R/make-lnk.pl" <<'PERL'
use strict; use warnings; use Encode;
my $out = shift;
my %f = map { split /=/, $_, 2 } @ARGV;
my $flags = 0x80; my $info = "";
if (defined $f{local}) {
  $flags |= 2;
  my $body = pack("V", 16) . ("\0" x 12) . $f{local} . "\0\0";
  my $base = 0x1C + 16; my $suffix = $base + length($f{local}) + 1;
  $info = pack("V7", 0x1C + length($body), 0x1C, 1, 0x1C, $base, 0, $suffix) . $body;
} elsif (defined $f{share}) {
  $flags |= 2;
  my $net = pack("V5", 0x14 + length($f{share}) + 1, 2, 0x14, 0, 0x20000) . $f{share} . "\0";
  my $body = $net . "\0";
  $info = pack("V7", 0x1C + length($body), 0x1C, 2, 0, 0, 0x1C, 0x1C + length($net)) . $body;
}
my $strings = "";
for my $pair (["relative", 8], ["args", 0x20]) {
  next unless defined $f{$pair->[0]};
  $flags |= $pair->[1];
  $strings .= pack("v", length($f{$pair->[0]})) . encode("UTF-16LE", $f{$pair->[0]});
}
my $header = pack("V", 0x4C) . pack("H*", "0114020000000000C000000000000046") . pack("V2", $flags, 0) . ("\0" x 28) . ("\0" x 20);
open(my $h, ">:raw", $out) or die; print $h $header . $info . $strings . pack("V", 0); close($h);
PERL
lnk() { perl "$R/make-lnk.pl" "$F/$@"; }

printf '[InternetShortcut]\r\nURL=https://example.com/\r\n' > "$F/site.url"
printf '[InternetShortcut]\r\nURL=file:///etc/hosts\r\n' > "$F/local.url"
printf 'not a shortcut' > "$F/fake.lnk"
echo pdf > "$F/report.pdf"
printf '#!/bin/sh\n' > "$F/run.command"
for n in 1 2 3 4 5 6 7 8 9 10; do cp "$F/site.url" "$F/many$n.url"; done
ln -s site.url "$F/symlink.url"
ln -s site.url "$F/Invoice.pdf"
ln -s "site.url - Shortcut" "$F/ViaAlias.pdf"
ln -s report.pdf "$F/pdf-named.url"
lnk dir.lnk 'relative=.\sub'
lnk dir2.lnk 'relative=.\sub2'
lnk doc.lnk 'relative=.\report.pdf'
lnk tool.lnk 'relative=.\run.command'
lnk drive.lnk 'local=C:\Users\me\notes.txt'
lnk unc.lnk 'share=\\server\share'
lnk args.lnk 'relative=.\report.pdf' 'args=--flag'
lnk exe.lnk 'relative=.\setup.exe'
lnk folder-js.lnk 'relative=.\next.js'
(cd "$F" && /usr/bin/zip -q "$R/kit.zip" site.url) && mv "$R/kit.zip" "$F/kit.zip"

answer="wait:0.8"
S="wait:1"
S+=";select:site.url;click:file.open;event;$answer;log:$R/url-prompt.txt;button:Open;wait:0.5;log:$R/url-open.txt"
S+=";select:site.url;click:file.open;event;$answer;button:Cancel;wait:0.5;log:$R/url-cancel.txt"
S+=";select:site.url;click:file.open;event;$answer;sheetkey:return;log:$R/key-return.txt;sheetkey:escape;wait:0.5;log:$R/key-escape.txt"
S+=";select:local.url;click:file.open;event;$answer;log:$R/url-file.txt;button:OK;wait:0.3"
S+=";select:fake.lnk;click:file.open;event;$answer;log:$R/fake.txt;button:OK;wait:0.3"
S+=";select:symlink.url;click:file.open;event;$answer;log:$R/symlink.txt;button:OK;wait:0.3"
S+=";select:Invoice.pdf;click:file.open;event;$answer;log:$R/symlink-renamed.txt;button:OK;wait:0.3"
S+=";select:pdf-named.url;click:file.open;event;$answer;log:$R/symlink-pdf.txt"
S+=";select:drive.lnk;click:file.open;event;$answer;log:$R/drive.txt;button:OK;wait:0.3"
S+=";select:unc.lnk;click:file.open;event;$answer;log:$R/unc.txt;button:OK;wait:0.3"
S+=";select:args.lnk;click:file.open;event;$answer;log:$R/args.txt;button:OK;wait:0.3"
S+=";select:exe.lnk;click:file.open;event;$answer;log:$R/exe.txt;button:OK;wait:0.3"
S+=";select:doc.lnk;click:file.open;event;$answer;log:$R/doc-prompt.txt;button:Open;wait:0.8;log:$R/doc-open.txt"
S+=";select:tool.lnk;click:file.open;event;$answer;sheetkey:escape;wait:0.5;log:$R/reveal-escape.txt"
S+=";select:tool.lnk;click:file.open;event;$answer;log:$R/tool.txt;button:Show in Folder;wait:0.8;log:$R/tool-shown.txt"
S+=";select:folder-js.lnk;click:file.open;event;wait:1;log:$R/folder-js.txt;back;wait:1"
S+=";select:dir.lnk;click:file.open;event;wait:1;log:$R/dir.txt;back;wait:1"
S+=";select:dir.lnk|dir2.lnk;click:file.open;event;wait:1.2;log:$R/batch.txt;closetab;wait:0.3;closetab;wait:0.5"
S+=";select:kit.zip;click:file.open;event;wait:1.2;select:site.url;click:file.open;event;$answer;log:$R/member.txt;button:OK;wait:0.3;back;wait:1"
S+=";select:site.url;click:file.createShortcut;event;wait:1;select:site.url - Shortcut;click:file.open;event;$answer;log:$R/alias.txt;button:Cancel;wait:0.3"
S+=";refresh;wait:0.8;select:ViaAlias.pdf;click:file.open;event;$answer;log:$R/symlink-alias.txt;button:OK;wait:0.3"
S+=";propertiesof:$F/drive.lnk;wait:0.8;proptab:Shortcut;wait:0.3;proplog:$R/prop-lnk.txt"
S+=";propertiesof:$F/site.url;wait:0.8;proptab:Shortcut;wait:0.3;proplog:$R/prop-url.txt"
MANY="many1.url"; for n in 2 3 4 5 6 7 8 9 10; do MANY+="|many$n.url"; done
S+=";select:$MANY;click:file.open;event;$answer;log:$R/many.txt"
for n in 1 2 3 4 5 6 7 8; do S+=";button:Cancel;wait:0.4"; done
S+=";wait:0.5;log:$R/many-done.txt"
S+=";location:home;wait:1.5;log:$R/home.txt;quit"
env ARBOR_HEADLESS=1 ARBOR_TEST_TRASH="$R/trash" ARBOR_JOURNAL_DIR="$R/journal" ARBOR_HISTORY_FILE="$R/history.json" \
  ARBOR_SCRIPT="$S" perl -e 'alarm shift; exec @ARGV' 240 "$ARBOR_APP_BIN" "$F" >/dev/null 2>&1

contains ".url asks first"                 "$R/url-prompt.txt" "Open this web address?"
contains ".url shows the real address"     "$R/url-prompt.txt" "https://example.com/"
lacks    ".url opens nothing before Open"  "$R/url-prompt.txt" "open https://example.com/"
contains ".url opens after Open"           "$R/url-open.txt"   "system open: open https://example.com/"
contains "only one open after Cancel"      "$R/url-cancel.txt" "system open: open https://example.com/"
lacks    "Cancel opens nothing more"       "$R/url-cancel.txt" "open https://example.com/ | open https://example.com/"
contains "file: address is refused"        "$R/url-file.txt"   "“file:” address"
contains "a fake .lnk is left alone"       "$R/fake.txt"       "isn't a Windows shortcut"
contains "symbolic link is not followed"   "$R/symlink.txt"    "symbolic link to a Windows shortcut"
contains "a renamed link is judged by its target" "$R/symlink-renamed.txt" "symbolic link to a Windows shortcut"
lacks    "a renamed link opens nothing"    "$R/symlink-renamed.txt" "open $(cd "$F" && pwd -P)/Invoice.pdf"
contains "a link through an alias is refused" "$R/symlink-alias.txt" "symbolic link to a Windows shortcut"
contains "a link named .url to a PDF opens" "$R/symlink-pdf.txt" "pdf-named.url"
contains "Return leaves the prompt open"   "$R/key-return.txt" "sheet: true"
contains "Esc closes the prompt"           "$R/key-escape.txt" "sheet: false"
contains "Esc closes Show in Folder"       "$R/reveal-escape.txt" "sheet: false"
contains "a folder named next.js navigates" "$R/folder-js.txt" "tabs: next.js  active: 1"
contains "a large selection is capped"     "$R/many.txt" "Too many shortcuts"
contains "eight answers clear the prompts" "$R/many-done.txt" "sheet: false"
contains "an opened .url reaches Recent"   "$R/home.txt" "site.url"
contains "drive letter is explained"       "$R/drive.txt"      "Windows drive path"
contains "network target is explained"     "$R/unc.txt"        "doesn't connect to servers"
contains "arguments are refused"           "$R/args.txt"       "arguments"
contains "Windows program is refused"      "$R/exe.txt"        "Windows program"
lacks    "refused targets open nothing"    "$R/exe.txt"        "/report.pdf"
contains "document asks first"             "$R/doc-prompt.txt" "Open this file?"
lacks    "document waits for the answer"   "$R/doc-prompt.txt" "open $(cd "$F" && pwd -P)/report.pdf"
contains "document opens after Open"       "$R/doc-open.txt"   "/report.pdf"
contains "a script is only offered"        "$R/tool.txt"       "only shows them in their folder"
lacks    "a script is never opened"        "$R/tool-shown.txt" "open $(cd "$F" && pwd -P)/run.command"
contains "Show in Folder selects it"       "$R/tool-shown.txt" "selected: run.command"
contains "a folder target navigates"       "$R/dir.txt"        "tabs: sub  active: 1"
contains "two folder targets open two tabs" "$R/batch.txt"     "active: 3"
contains "archive member is explained"     "$R/member.txt"     "inside an archive"
contains "an alias to a .url still asks"   "$R/alias.txt"      "windows shortcuts: Open this web address?"
contains ".lnk tab shows the target"       "$R/prop-lnk.txt"   'Target: C:\Users\me\notes.txt'
contains ".lnk tab says why not"           "$R/prop-lnk.txt"   "On this Mac:"
contains ".url tab shows the address"      "$R/prop-url.txt"   "Address: https://example.com/"
contains "Shortcut tab follows General"    "$R/prop-url.txt"   "tabs: General | Shortcut"

if [ "$FAILED" = 1 ] && [ -n "${ARBOR_KEEP_FAILED:-}" ]; then
  mkdir -p "$ARBOR_KEEP_FAILED"; mv "$R" "$ARBOR_KEEP_FAILED/windows-shortcuts"; echo "kept  windows-shortcuts → $ARBOR_KEEP_FAILED/windows-shortcuts"
else
  rm -rf "$R"
fi
[ "$FAILED" = 0 ] && echo "all windows shortcut checks passed"
exit "$FAILED"
