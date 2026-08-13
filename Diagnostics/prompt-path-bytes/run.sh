#!/usr/bin/env bash
# Proves a filename the shell cannot hold is refused, and that the footer says why.
#
#   ./Diagnostics/prompt-path-bytes/run.sh
#
# **Never from inside a baia pane.** It launches and drives `baia-dev.app` with
# real events and brings it to the front, so a pane running an agent loses the
# keystrokes. `theme-catalog` and `app-icon` are the two probes safe there; this
# is not one of them.
#
# **The first run on a machine needs a person.** macOS raises an Automation
# consent dialog the first time a process drives System Events and blocks until
# somebody answers it. `drive.sh` refuses up front when Accessibility is missing,
# which is the other half of the same permission and the one that used to make a
# run a silent no-op that reported findings.
#
# What changed on 2026-08-03, and why this probe no longer grades bytes: the
# question it was built for got an answer. `cat`, reading the pty with no line
# editor in front of it, received `'src/caf<E9>.txt' ` byte for byte, so the
# emulator delivers exactly what `sendBytes` writes. The same click onto a
# command line left `printf '%s' 'src/caf` and an open quote, because zsh's line
# editor decodes its input as characters and drops everything from the first byte
# that is not valid UTF-8. Sending is the worse of the two failures: a half-line
# reads as the app having lost the click and has to be cleared by hand. So
# `PromptPath` refuses such a path, and what is graded here is the refusal.
#
# The screen must be unlocked and the machine left alone: the clicks are real
# events at real screen points and anything in front takes them.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
cd "$REPO"

APP=".build/Build/Products/Debug/baia-dev.app"
OUT="verify-out/prompt-path-bytes"
# Absolute, for the reason path-picker records: the readout line is typed into a
# pane whose working directory is the fixture, not the repo, so a relative path
# there writes into a directory that does not exist and fails silently.
READOUT="$REPO/$OUT"
CONFIG="$HOME/.config/baia/config.json"

[ -d "$APP" ] || { echo "ABORT: no build at $APP, run make build first" >&2; exit 1; }

# Sourced before `APP_SESSION` is read. `app-identity.sh` derives the support
# directory, the session and the socket from the bundle `APP` names, so `APP` has
# to be set first and this has to come before either is used. Both older driven
# probes had these three lines above the source and `set -u` killed every run.
export OUT REPO
source "$REPO/Diagnostics/lib/drive.sh"

SESSION="$APP_SESSION"
BAIA_SOCK="$APP_SOCKET"
export BAIA_SOCK

mkdir -p "$READOUT"

# The same contract every driven probe keeps: the run rewrites the sidebar key and
# deletes the session, so both are put back whatever happens, including on a kill.
CONFIG_BACKUP=$(mktemp)
SESSION_BACKUP=$(mktemp)
cp "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null
cp "$SESSION" "$SESSION_BACKUP" 2>/dev/null
trap 'cp "$CONFIG_BACKUP" "$CONFIG" 2>/dev/null; cp "$SESSION_BACKUP" "$SESSION" 2>/dev/null; rm -f "$CONFIG_BACKUP" "$SESSION_BACKUP"' EXIT

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; echo "          wanted: $2"; echo "          got:    $3"; fail=$((fail + 1)); }

FIXTURE=$("$HERE/fixture.sh" | sed -n 's/^\[+\] fixture at //p')
[ -d "$FIXTURE" ] || { echo "ABORT: fixture.sh printed no path" >&2; exit 1; }
echo "  fixture at $FIXTURE"

# The pane's own last line, read through the channel with the pane's own
# capability. Same readout `path-picker` uses and for the same reason: a token is
# minted per pane per run and written nowhere else, so the only way to hold one is
# to have the pane's shell report it.
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

# A refusal is asserted by absence. `expect_prompt "... " "ls "` would pass on a
# prompt that had gained a path after the `ls `, which is the whole thing this
# check exists to catch.
refuse_prompt() {
    local got
    got=$(prompt_line)
    case "$got" in
        *.txt*) bad "$1" "no path appended" "$got" ;;
        *) ok "$1" ;;
    esac
}

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
    # The pane reports its own capability, which is the only way to hold one.
    type_line "printf '%s' \"\$BAIA_TOKEN\" > $READOUT/pane.token; printf '%s' \"\$BAIA_PANE\" > $READOUT/pane.id; clear"
    sleep 1
}

# The fixture's tree as the sidebar draws it, confirmed against the 2026-08-03
# captures:
#
#    1  src/
#    2    caf<E9>.txt
#    3    plain.txt
#    4  README.md
#
# The two byte-expectation dotfiles that used to sit at rows 4 and 5 are gone with
# the byte checks, which moves `README.md` up and nothing that is clicked.

echo "1 an ordinary name still lands, so a refusal below means the refusal"
launch
type_raw "ls "
click_row 68 1          # src/, expands
click_row 68 3          # src/plain.txt
shot 1-ordinary-lands
expect_prompt "a name the shell can hold reaches the prompt" "plain.txt"

# **The positive control is not decoration.** Without it, "nothing was appended"
# is equally consistent with the refusal working, the row index being wrong, the
# click missing the window and the picker being broken outright. This is the same
# picker, the same run and the neighbouring row.

echo "2 the name the shell cannot hold appends nothing"
launch
type_raw "ls "
click_row 68 1          # src/, expands
click_row 68 2          # src/caf<E9>.txt
shot 2-refused
refuse_prompt "a name that is not UTF-8 appends nothing"

quit_app

cat <<EOF

  Two images in $OUT.

  LOOK  2-refused   the footer reads "name is not valid UTF-8, so the shell
                    cannot hold it: rename the file", alone on the bar and in
                    the alert colour, and the row flashed its refusal.

  That one is by eye on purpose. The footer is chrome rather than terminal text,
  so the control channel's \`read\` cannot reach it: it returns what the pty
  holds, and the bar is drawn by the app. \`PaneClusterSegmentsTests\` grades the
  rule that a notice takes the bar alone, and \`PromptPathTests\` grades which
  refusal this row produces; what no test can see is the sentence actually
  arriving on screen, which is what the capture is for.
EOF

echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED $fail of $((pass + fail)) checks"
    exit 1
fi
echo "PASS: all $pass checks"
