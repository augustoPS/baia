#!/usr/bin/env bash
# Drives the path picker over the fixture and captures the prompt after each step.
#
#   ./Diagnostics/path-picker/run.sh
#
# Builds the fixture, launches baia on it with the sidebar in `files`, clicks the
# rows the checks care about, and shoots the window after each one. Writes to
# verify-out/path-picker/ and prints LOOK per step.
#
# **This does not pass or fail.** It cannot: the assertion is what landed on the
# focused pane's prompt line, and nothing outside the app can read a pane's
# contents today. That is the control channel's `read` verb, which is not built.
# Until it is, this posts the real clicks and leaves a human five images to
# compare instead of five multi-step interactions to perform.
#
# The screen must be unlocked, and the machine left alone while it runs: the
# clicks are real events at real screen points and anything else in front will
# take them.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
cd "$REPO"

APP=".build/Build/Products/Debug/baia.app"
OUT="verify-out/path-picker"
CONFIG="$HOME/.config/baia/config.json"
SESSION="$HOME/Library/Application Support/baia/session.json"

[ -d "$APP" ] || { echo "ABORT: no build at $APP, run make build first" >&2; exit 1; }

# Same contract capture.sh keeps: the run rewrites the sidebar key and deletes the
# session, so both are put back whatever happens, including on a kill.
CONFIG_BACKUP=$(mktemp)
SESSION_BACKUP=$(mktemp)
cp "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null
cp "$SESSION" "$SESSION_BACKUP" 2>/dev/null
trap 'cp "$CONFIG_BACKUP" "$CONFIG" 2>/dev/null; cp "$SESSION_BACKUP" "$SESSION" 2>/dev/null; rm -f "$CONFIG_BACKUP" "$SESSION_BACKUP"' EXIT

export OUT REPO
source "$REPO/Diagnostics/lib/drive.sh"

FIXTURE=$("$HERE/fixture.sh" | sed -n 's/^\[+\] fixture at //p')
[ -d "$FIXTURE" ] || { echo "ABORT: fixture.sh printed no path" >&2; exit 1; }
echo "  fixture at $FIXTURE"

launch() {
    pkill -f "baia.app/Contents/MacOS/baia" 2>/dev/null
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
}

# The row indices below are the tree in fixture order under a `files` sidebar:
# src/ is row 2, and its children follow once expanded. They are the one brittle
# part of this script. If a shot shows the wrong row clicked, re-read the tree in
# the capture and adjust rather than guessing.
echo "1 a bare name sends, and the trailing space lands"
launch
click_row 68 2          # src/
click_row 68 8          # src/plain.txt
shot 1-plain-sends

echo "2 three clicks accumulate into three arguments"
click_row 68 9
click_row 68 10
shot 2-three-arguments

echo "3 a name with a space arrives as one argument"
launch
type_raw "ls "
click_row 68 2          # src/
click_row 68 3          # src/a space.txt
shot 3-space-one-argument

echo "4 a control-byte name refuses, and the prompt does not move"
launch
type_raw "ls "
click_row 68 2          # src/
click_row 68 5          # src/ctrl<TAB>name.txt
shot 4-control-byte-refused

echo "5 the escape name refuses too"
click_row 68 6          # src/esc<ESC>[Dname.txt
shot 5-escape-refused

pkill -f "baia.app/Contents/MacOS/baia" 2>/dev/null

cat <<EOF

  LOOK  1-plain-sends            src/plain.txt on the prompt, one trailing space
  LOOK  2-three-arguments        three paths, space separated, none quoted away
  LOOK  3-space-one-argument     'a space.txt' quoted or escaped as ONE argument
  LOOK  4-control-byte-refused   prompt unchanged, row flashed its refusal
  LOOK  5-escape-refused         prompt unchanged, row flashed its refusal

  Five images in $OUT. Nothing here asserts; see the header for why.

  Still by hand, because neither is a click:
    - clicking while an agent is mid-run inserts into its prompt
    - ~notes.txt, =lookup.txt and -rf.txt must not expand or read as options
      (the unit tests pin these; worth seeing once)
EOF
