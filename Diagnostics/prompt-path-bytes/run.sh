#!/usr/bin/env bash
# Proves a filename that is not UTF-8 reaches the prompt byte for byte.
#
#   ./Diagnostics/prompt-path-bytes/run.sh
#
# **Never from inside a baia pane.** It launches and drives `baia-dev.app` with
# real events and brings it to the front, so a pane running an agent loses the
# keystrokes. `theme-catalog` and `app-icon` are the two probes that are safe
# there; this is not one of them.
#
# **The assertion cannot be a screen read, which is why this is not a check
# inside `path-picker`.** That probe reads the pane's last line over the control
# channel and compares text. A terminal's screen buffer holds *decoded* text: the
# emulator turns the incoming bytes into cells, and a byte that is not valid UTF-8
# becomes U+FFFD on the way in. So a screen read cannot tell a correct send from
# the exact bug this exists to catch, because both read back as U+FFFD.
#
# The shell is asked instead. The command line is assembled as
# `printf '%s' <clicked path> > sent.bin`, so zsh receives the bytes as an
# argument and writes them out untouched, never through the screen. `cmp` then
# grades the file against the bytes the fixture recorded. What is being tested is
# the whole route: git's index, `GitStatusParser`, `RepositoryPath`, the surface's
# `onSelect`, `PromptPath`, `TerminalPaneController.send`, `sendBytes` and
# `ghostty_surface_text`.
#
# The screen must be unlocked and the machine left alone: the clicks are real
# events at real screen points and anything in front takes them.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
cd "$REPO"

APP=".build/Build/Products/Debug/baia-dev.app"
OUT="verify-out/prompt-path-bytes"
# Absolute, for the reason path-picker records: the redirect below is typed into
# a pane whose working directory is the fixture, not the repo, so a relative path
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
bad() { echo "  FAIL  $1"; echo "          $2"; fail=$((fail + 1)); }

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
    type_line "clear"
    sleep 1
}

# The fixture's tree as the sidebar draws it, directories first and root files
# last, which is the order `path-picker` recorded off its own capture:
#
#    1  src/
#    2    caf<E9>.txt
#    3    plain.txt
#    4  README.md
#
# **Confirm these against `1-clicked.png` on the first run and correct them here
# rather than guessing.** They are derived, not observed: this probe was written
# from inside a baia pane, where it could not be run. path-picker's first version
# was off by one throughout and every check failed against the wrong row.
rm -f "$READOUT/sent.bin"

echo "1 a non-UTF-8 name reaches the shell unchanged"
launch
click_row 68 1                      # src/, expands
type_raw "printf '%s' "
click_row 68 2                      # src/caf<E9>.txt
shot 1-clicked
type_line "> $READOUT/sent.bin"
sleep 1

if [ ! -f "$READOUT/sent.bin" ]; then
    bad "the shell wrote nothing" "no $READOUT/sent.bin: the click may have refused, or the row index is wrong. Read 1-clicked.png."
else
    if cmp -s "$READOUT/sent.bin" "$FIXTURE/.expected-bytes"; then
        ok "the clicked path arrived byte for byte"
    else
        bad "the bytes differ from what the fixture holds" \
            "wanted: $(od -c "$FIXTURE/.expected-bytes" | head -2)
          got:    $(od -c "$READOUT/sent.bin" | head -2)"
    fi

    # The negative control, and the whole point of the change: this is what the
    # same click produced while the path went through a Swift `String`. A run that
    # matches this has regressed to the defect rather than merely failed.
    if cmp -s "$READOUT/sent.bin" "$FIXTURE/.lossy-bytes"; then
        bad "the path was replaced by U+FFFD" \
            "this is the pre-fix behaviour exactly: the bytes went through a String somewhere."
    else
        ok "and it is not the U+FFFD spelling the String path produced"
    fi
fi

quit_app

cat <<EOF

  One image in $OUT, kept because a wrong row index reads far better as a picture
  of the tree than as a byte diff.
EOF

echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED $fail of $((pass + fail)) checks"
    exit 1
fi
echo "PASS: all $pass checks"
