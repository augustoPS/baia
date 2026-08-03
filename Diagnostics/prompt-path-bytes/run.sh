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

# The fixture's tree as the sidebar draws it, confirmed against the 2026-08-03
# capture rather than derived:
#
#    1  src/
#    2    caf<E9>.txt
#    3    plain.txt
#    4  .expected-bytes
#    5  .lossy-bytes
#    6  README.md
#
# The two dotfiles the fixture writes are untracked, so `ls-files --others` lists
# them and they take rows of their own. They sit below `src/`'s children and move
# nothing clicked here.

# **Two checks, and the pair is the instrument.** One of them alone answers
# nothing.
#
# The 2026-08-03 run assembled a command line and ended with `printf '%s'
# 'src/caf` on the prompt: the opening quote and the ASCII prefix arrived, the
# 0xE9 and everything after it did not, the quote never closed, nothing ran. That
# is one observation with two causes and no screenshot can separate them. Either
# zsh's line editor cannot hold the bytes, since ZLE decodes its input as
# characters and 0xE9 announces a three-byte sequence `.txt` does not complete,
# or `ghostty_surface_text` validates UTF-8 and the tail never reached the pty.
#
# `cat` settles it. It reads the pty in canonical mode with no line editor in
# front, so what lands in its file is what the emulator delivered. The 0xE9
# present means ghostty passes bytes and ZLE is the blocker; a file truncated at
# `caf` means ghostty is the filter and `sendBytes` writes into one.
rm -f "$READOUT/sent.bin" "$READOUT/typed.bin"

classify() {
    python3 "$HERE/classify.py" "$1" "$2" "$FIXTURE/.expected-bytes" "$FIXTURE/.lossy-bytes"
}

echo "1 does the emulator deliver the bytes to a process at all"
launch
click_row 68 1                      # src/, expands
# `cat` before the click, so the bytes land in a reader with no line editor in
# front of them. Canonical mode still buffers to a newline, which the Return
# below supplies and `classify.py` strips.
type_line "cat > $READOUT/sent.bin"
click_row 68 2                      # src/caf<E9>.txt
shot 1-cat-clicked
key 'key code 36'
key 'keystroke "d" using control down'
sleep 1
if classify "the bytes reached a reading process" "$READOUT/sent.bin"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi

echo "2 can the line editor hold them on a command line"
# **Ctrl-C first, and the 2026-08-03 run is why.** `clear` empties the screen and
# not the input line, and check 1 left `'src/caf` on it: the line became
# `'src/cafprintf '%s' 'src/caf > typed.bin`, which zsh parses as one
# command word and a redirect, so it created an empty `typed.bin` and reported
# command-not-found. The truncation that check exists to show was still visible
# on the prompt, but the file it graded had the wrong cause behind it.
key 'keystroke "c" using control down'
type_line "clear"
type_raw "printf '%s' "
click_row 68 2                      # src/caf<E9>.txt
shot 2-prompt-clicked
type_line "> $READOUT/typed.bin"
sleep 1
if classify "the bytes survived the line editor" "$READOUT/typed.bin"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi

echo
echo "  1 passing and 2 failing: the emulator is honest and zsh's line editor is"
echo "  where a non-UTF-8 path cannot go. Both failing: ghostty filters the bytes"
echo "  and sendBytes is writing into that filter."
echo

quit_app

cat <<EOF

  Two images in $OUT: 1-cat-clicked.png with the path landing in \`cat\`, and
  2-prompt-clicked.png with it landing on a command line. A picture of the prompt
  is what showed the quote never closing on 2026-08-03, which no byte diff said.
EOF

echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED $fail of $((pass + fail)) checks"
    exit 1
fi
echo "PASS: all $pass checks"
