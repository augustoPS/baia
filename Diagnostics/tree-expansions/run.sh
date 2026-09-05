#!/usr/bin/env bash
# Drives a quit and a relaunch, and checks the file tree comes back open.
#
#   ./Diagnostics/tree-expansions/run.sh
#
# Four checks over one launch, one graceful quit, and one relaunch. Writes to
# verify-out/tree-expansions/ and passes or fails.
#
# **Nothing in `make test` can answer this.** The open set lives on a sidebar
# surface, the anchor it is keyed under is resolved by walking the filesystem for
# a repository root, and the round trip is a real quit and a real launch. Every
# part of that needs an `NSWindow`, a shell, and a session file, which is the
# definition of what belongs in a probe.
#
# The pane is put in a **subdirectory** of the fixture on purpose. That is the
# case the package tests cannot state: a shell in `<repo>/src` anchors its tree at
# `<repo>`, so the expansions are keyed under a path no pane records as its
# working directory. Pruned against the raw directory instead of the resolved
# anchor, the map is thrown away on every launch and check 4 fails while every
# unit test still passes.
#
# The screen must be unlocked, and the machine left alone while it runs: the
# clicks are real events at real screen points and anything else in front will
# take them.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ROOT="$REPO"
cd "$REPO"

ISOLATED_LABEL=tree-expansions
# shellcheck source=../lib/isolated-app.sh
source "$REPO/Diagnostics/lib/isolated-app.sh"
isolated_refuse_pane || exit 1
isolated_install_traps
isolated_prepare || exit 1

APP="$ISOLATED_APP"
OUT="verify-out/tree-expansions"
# Absolute, for the reason path-picker records: the readout line is typed into a
# pane whose working directory is the fixture, not the repo, so a relative
# redirect there writes into a directory that does not exist and fails silently.
READOUT="$REPO/$OUT"
CONFIG="$ISOLATED_CONFIG"
isolated_default_config files || exit 1

export OUT REPO
source "$REPO/Diagnostics/lib/drive.sh"

SESSION="$ISOLATED_SESSION"
BAIA_SOCK="$ISOLATED_SOCKET"
export BAIA_SOCK

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; echo "          wanted: $2"; echo "          got:    $3"; fail=$((fail + 1)); }

prompt_line() {
    python3 "$REPO/Diagnostics/lib/read-prompt.py" "$BAIA_SOCK" "$READOUT"
}

expect_prompt() {
    local got
    got=$(prompt_line)
    case "$got" in
        *"$2"*) ok "$1" ;;
        *) bad "$1" "a line containing $2" "$got" ;;
    esac
}

# Asserted by absence. A collapsed tree has no row there at all, so the click
# lands on empty column and the prompt must be exactly as it was left.
refuse_prompt() {
    local got
    got=$(prompt_line)
    case "$got" in
        *.txt*) bad "$1" "no path appended" "$got" ;;
        *) ok "$1" ;;
    esac
}

# path-picker's fixture rather than another one, because its row indices are the
# only ones on disk that were measured against a capture rather than guessed, and
# a probe about which row is open cannot afford to be off by one. What this run
# needs from it is only `src/` and one file under it.
FIXTURE=$("$REPO/Diagnostics/path-picker/fixture.sh" | sed -n 's/^\[+\] fixture at //p')
[ -d "$FIXTURE" ] || { echo "ABORT: fixture.sh printed no path" >&2; exit 1; }
FIXTURE=$(cd "$FIXTURE" && pwd -P)
# The last component only, and check 3 compares on that rather than on the whole
# path. Two spellings of one directory reach the session file and neither is the
# probe's business: `$TMPDIR` is a symlink into `/private`, and the app writes the
# anchor through `URL(directoryHint: .isDirectory)`, which appends a trailing
# slash. Asserting the literal path failed on a run where the feature worked
# perfectly, which is the wrong way round for a check.
FIXTURE_NAME=$(basename "$FIXTURE")
WORKDIR="$FIXTURE/src"
echo "  fixture at $FIXTURE"
echo "  pane opens at $WORKDIR, tree anchors at $FIXTURE"

# The readout the `read` verb needs. A capability is minted per pane per run and
# written nowhere else, so the only way to hold one is to have the pane's own
# shell report it.
readout_line() {
    type_line "printf '%s' \"\$BAIA_TOKEN\" > $READOUT/pane.token; printf '%s' \"\$BAIA_PANE\" > $READOUT/pane.id; clear"
    sleep 1
}

# The rows of the fixture's tree as the sidebar draws it, with `src/` open, read
# off path-picker's captures on 2026-07-30:
#
#    1  src/            8  ctrl<TAB>name.txt
#    2  deeply/         9  esc<ESC>[Dname.txt
#    3  -rf.txt        10  plain.txt
#    4  =lookup.txt    11  quo"te.txt
#    5  a space.txt    12  staged.txt
#    6  apo'strophe    13  ~notes.txt
#    7  café.txt       14  READING.md
#
# With `src/` closed the whole list is two rows, `src/` and `READING.md`, which is
# what makes row 10 an oracle: it names a file when the tree is open and nothing
# at all when it is closed.
SRC_ROW=1
PLAIN_ROW=10

# `plain.txt`, not `src/plain.txt`, which is what path-picker's own check expects
# for the same row. The difference is this probe's whole subject: the picker sends
# the path relative to the *pane's* working directory, and this pane sits in
# `src/` while its tree is anchored a level above. Measured on the first run
# rather than assumed, and it is a second, free confirmation that the anchor and
# the working directory really are two different directories here.
SENDS="plain.txt"

echo "1 a closed tree has no row 10, which is what makes row 10 an oracle"
isolated_stop_owned_process || {
  if [ "${ISOLATED_PROCESS_RETAINED:-0}" = 1 ]; then
    echo "isolated tree-expansions app still alive; not relaunching" >&2
    exit 1
  fi
}
sleep 1.5
rm -f "$SESSION"
python3 - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
settings = json.load(open(path))
settings["sidebar"] = "files"
json.dump(settings, open(path, "w"), indent=2)
PY
isolated_launch || exit 1
sleep 5
type_line "cd $WORKDIR"
readout_line
type_raw "ls "
click_row 68 $PLAIN_ROW
shot 1-closed
refuse_prompt "row 10 sends nothing while the tree is closed"

echo "2 the same row sends once src/ is opened"
click_row 68 $SRC_ROW
click_row 68 $PLAIN_ROW
shot 2-opened
expect_prompt "row 10 sends $SENDS with the tree open" "$SENDS"

echo "3 the quit records the open set under the resolved anchor"
# Command-Q rather than a kill. The session is flushed as the app terminates, and
# a killed process writes nothing, which is the difference between measuring the
# feature and measuring nothing.
key 'keystroke "q" using command down'
sleep 3
if isolated_app_is_running; then
    bad "the app quit on command-Q" "no isolated process" "still running"
else
    ok "the app quit on command-Q"
fi
RECORDED=$(python3 - "$SESSION" "$FIXTURE_NAME" <<'PY'
import json, posixpath, sys

try:
    session = json.load(open(sys.argv[1]))
except OSError:
    print("(no session file)"); raise SystemExit
except ValueError as error:
    print("(unparseable: %s)" % error); raise SystemExit

expansions = session.get("fileTreeExpansions")
if expansions is None:
    print("(no fileTreeExpansions key)"); raise SystemExit

# Matched on the last component, for the reason the caller records: the path is
# spelled two ways on the way to this file and neither difference is a defect.
name = sys.argv[2]
anchored, raw = "(none)", "no"
for key, value in expansions.items():
    stripped = key.rstrip("/")
    if posixpath.basename(stripped) == name:
        anchored = ",".join(sorted(value)) or "(empty)"
    if stripped.endswith("/%s/src" % name):
        raw = "yes"
print("open=%s raw=%s keys=%s" % (
    anchored,
    raw,
    ";".join(sorted(posixpath.basename(key.rstrip("/")) for key in expansions)),
))
PY
)
case "$RECORDED" in
    *"open=(none)"*) bad "the map is keyed under the resolved anchor" "a key named $FIXTURE_NAME" "$RECORDED" ;;
    open=*) ok "the map is keyed under the resolved anchor" ;;
    *) bad "the map is keyed under the resolved anchor" "a key named $FIXTURE_NAME" "$RECORDED" ;;
esac
case "$RECORDED" in
    *"open=src "*) ok "the open directory is in the map" ;;
    *) bad "the open directory is in the map" "open=src" "$RECORDED" ;;
esac
# The defect this probe was written for prints exactly here: keyed under the raw
# working directory, the map survives the save and is pruned to nothing on the
# load below, so check 3 passes and check 4 fails.
case "$RECORDED" in
    *"raw=yes"*) bad "the raw working directory is not a key" "raw=no" "$RECORDED" ;;
    *) ok "the raw working directory is not a key" ;;
esac
echo "  session recorded $RECORDED"

echo "4 the relaunch brings the tree back open"
isolated_launch || exit 1
sleep 6
readout_line
type_raw "ls "
click_row 68 $PLAIN_ROW
shot 4-restored
expect_prompt "row 10 sends $SENDS after a relaunch" "$SENDS"

echo ""
echo "  $pass passed, $fail failed"
echo "  captures in $OUT"
[ "$fail" -eq 0 ] || exit 1
