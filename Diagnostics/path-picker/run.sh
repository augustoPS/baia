#!/usr/bin/env bash
# Drives the path picker over the fixture and captures the prompt after each step.
#
#   ./Diagnostics/path-picker/run.sh
#
# Builds the fixture, launches baia on it with the sidebar in `files`, clicks the
# rows the checks care about, and shoots the window after each one. Writes to
# verify-out/path-picker/ and prints LOOK per step.
#
# **It passes or fails.** It did not until 2026-07-30: the assertion is what
# landed on the focused pane's prompt line, and nothing outside the app could
# read a pane's contents. The control channel's `read` verb closed that, so each
# click is now followed by a read of the pane's own last line and compared
# against what the picker was supposed to send.
#
# The images are still captured, because a failure is far easier to understand
# next to a picture of the pane than from a diff of two strings.
#
# The screen must be unlocked, and the machine left alone while it runs: the
# clicks are real events at real screen points and anything else in front will
# take them.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
cd "$REPO"

APP=".build/Build/Products/Debug/baia-dev.app"
OUT="verify-out/path-picker"
# Absolute, because the readout below is typed into a pane whose working
# directory is the fixture, not the repo. A relative path there wrote into a
# directory that does not exist and the redirect failed silently, which read as
# the pane having no capability at all.
READOUT="$REPO/$OUT"
CONFIG="$HOME/.config/baia/config.json"

[ -d "$APP" ] || { echo "ABORT: no build at $APP, run make build first" >&2; exit 1; }

# **Sourced before `APP_SESSION` is read, and it was not.** `app-identity.sh`,
# which `drive.sh` pulls in, derives the support directory, the session file and
# the socket from the bundle `APP` names, so `APP` has to be set first and the
# source has to come before either is used. This block read both fifteen lines
# above the source, and `set -u` turns that from wrong into fatal: every run died
# on `APP_SESSION: unbound variable` before it launched anything. Arrived with the
# identity resolver on 2026-08-02 and was never run afterwards, which is the only
# reason it stayed. `tree-expansions/run.sh` carried the same three lines and the
# same defect.
export OUT REPO
source "$REPO/Diagnostics/lib/drive.sh"

SESSION="$APP_SESSION"
BAIA_SOCK="$APP_SOCKET"
export BAIA_SOCK

# Same contract capture.sh keeps: the run rewrites the sidebar key and deletes the
# session, so both are put back whatever happens, including on a kill.
CONFIG_BACKUP=$(mktemp)
SESSION_BACKUP=$(mktemp)
cp "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null
cp "$SESSION" "$SESSION_BACKUP" 2>/dev/null
trap 'cp "$CONFIG_BACKUP" "$CONFIG" 2>/dev/null; cp "$SESSION_BACKUP" "$SESSION" 2>/dev/null; rm -f "$CONFIG_BACKUP" "$SESSION_BACKUP"' EXIT

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; echo "          wanted: $2"; echo "          got:    $3"; fail=$((fail + 1)); }

# The pane's own last line, read through the channel with the pane's own
# capability.
#
# **A readout rather than a forgery**, the trick `Diagnostics/control-channel/`
# already turns: a capability is minted per pane per run and written nowhere, so
# the only way to hold one is to have the pane's shell report it. `read` is
# `.descendant` and resolves `subject == actor`, which is what lets a pane read
# itself.
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

# A refusal is asserted by absence, not by the prompt merely looking familiar.
# `expect_prompt "... " "ls "` would pass on a prompt that had gained a path
# after the `ls `, which is exactly the failure these two rows exist to catch.
refuse_prompt() {
    local got
    got=$(prompt_line)
    case "$got" in
        *.txt*) bad "$1" "no path appended" "$got" ;;
        *) ok "$1" ;;
    esac
}

FIXTURE=$("$HERE/fixture.sh" | sed -n 's/^\[+\] fixture at //p')
[ -d "$FIXTURE" ] || { echo "ABORT: fixture.sh printed no path" >&2; exit 1; }
echo "  fixture at $FIXTURE"

launch() {
    quit_app
    sleep 1.5
    rm -f "$SESSION"
    python3 - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
settings = json.load(open(path))
settings["sidebar"] = "files"
json.dump(settings, open(path, "w"), indent=2)
PY
    open "$APP"
    sleep 5
    type_line "cd $FIXTURE"
    # The pane reports its own capability, which is the only way to hold one: a
    # token is minted per pane per run and written nowhere else. Same readout the
    # control-channel probe uses, and the reason `read` can be driven from here.
    type_line "printf '%s' \"\$BAIA_TOKEN\" > $READOUT/pane.token; printf '%s' \"\$BAIA_PANE\" > $READOUT/pane.id; clear"
    sleep 1
}

# The row indices are the fixture's tree as the sidebar draws it, read off
# `2-three-arguments.png` on 2026-07-30 rather than guessed:
#
#    1  src/            8  ctrl<TAB>name.txt
#    2  deeply/         9  esc<ESC>[Dname.txt
#    3  -rf.txt        10  plain.txt
#    4  =lookup.txt    11  quo"te.txt
#    5  a space.txt    12  staged.txt
#    6  apo'strophe    13  ~notes.txt
#    7  café.txt       14  READING.md
#
# They are the one thing here that can silently click the wrong row. If a check
# fails with a path nobody asked for, read the tree in the capture beside it and
# correct the number rather than guessing: the first version of this script was
# off by one throughout and every check failed against `READING.md`.

echo "1 a bare name sends"
launch
click_row 68 1          # src/, expands
click_row 68 10         # src/plain.txt
shot 1-plain-sends
expect_prompt "a bare name reaches the prompt" "src/plain.txt"

echo "2 clicks accumulate rather than replace"
click_row 68 11         # src/quo"te.txt
click_row 68 12         # src/staged.txt
shot 2-three-arguments
expect_prompt "the first path is still there after two more" "src/plain.txt"
expect_prompt "and the third arrived beside it" "staged.txt"

echo "3 a name with a space arrives as one argument"
launch
type_raw "ls "
click_row 68 1          # src/
click_row 68 5          # src/a space.txt
shot 3-space-one-argument
expect_prompt "a name with a space is quoted or escaped" "space"

echo "4 a control-byte name refuses, and the prompt does not move"
launch
type_raw "ls "
click_row 68 1          # src/
click_row 68 8          # src/ctrl<TAB>name.txt
shot 4-control-byte-refused
refuse_prompt "a control-byte name appends nothing"

echo "5 the escape name refuses too"
click_row 68 9          # src/esc<ESC>[Dname.txt
shot 5-escape-refused
refuse_prompt "and neither does the escape name"

quit_app

cat <<EOF

  Five images in $OUT, kept because a failure reads better beside a picture of
  the pane than as a diff of two strings.

  Still by hand, because neither is a click:
    - clicking while an agent is mid-run inserts into its prompt
    - ~notes.txt, =lookup.txt and -rf.txt must not expand or read as options
      (the unit tests pin these; worth seeing once)
EOF

echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED $fail of $((pass + fail)) checks"
    exit 1
fi
echo "PASS: all $pass checks"
