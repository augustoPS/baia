#!/usr/bin/env bash
# Regenerates the Claude Design handover captures.
#
# Drives the real app through AppleScript and captures the window rather than the
# screen, so the output is usable as a design reference rather than a desktop
# photo. Run from the repo root after `make build`.
#
#   ./design-captures/capture.sh
#
# Two things that will bite anyone editing this:
#   - Text is pasted, never typed. `System Events keystroke` cannot produce `~` or
#     `^` under the U.S. International layout and silently substitutes `a`, so
#     `cd ~/Projects` arrives as `cd a/Projects`. See `type_line`.
#   - baia must be frontmost before any keystroke, or the key goes to whatever is.
#     That is what `act` is for, and why every helper calls it first.
set -uo pipefail

APP=".build/Build/Products/Debug/baia.app"
OUT="design-captures"
SESSION="$HOME/Library/Application Support/baia/session.json"
CONFIG="$HOME/.config/baia/config.json"

# The captures set `sidebar` per scenario, so the owner's own file is put back
# whatever happens. Without this a killed run leaves their sidebar wherever the
# last capture wanted it.
CONFIG_BACKUP=$(mktemp)
cp "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null
trap 'cp "$CONFIG_BACKUP" "$CONFIG" 2>/dev/null; rm -f "$CONFIG_BACKUP"' EXIT

# The run is four minutes of no human input, which is long enough for the display
# to sleep. A slept display has no windows to ask about: `window 1` becomes an
# invalid index, `screencapture -R` refuses the rect, and the run dies halfway
# through looking like an app bug. Held awake for as long as this shell lives.
caffeinate -dimsu -w $$ &

# Activates baia and refuses to continue until it is genuinely frontmost.
#
# Without the check, a slow activation sends the next keystroke to whatever app
# is in front. During one run that typed `cd /Users/.../shop` into the terminal
# running Claude Code, which is harmless here but would not be if the leaked line
# were destructive.
act() {
    local front
    for _ in 1 2 3 4 5 6 7 8; do
        osascript -e 'tell application "baia" to activate' >/dev/null 2>&1
        sleep 0.5
        front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
        [ "$front" = "baia" ] && return 0
    done
    echo "  ABORT: baia never came to the front, refusing to type into $front" >&2
    exit 1
}
key() { act; osascript -e "tell application \"System Events\" to $1" >/dev/null 2>&1; sleep 1.3; }

# Pastes rather than types, because typing `~` through AppleScript on this layout
# fails in three different ways and the clipboard sidesteps all of them.
#
# The layout is U.S. International, where `~` and `^` are shifted dead keys.
# `keystroke "~"` cannot map the character and falls back to virtual keycode 0,
# which is the `a` key, so `cd ~/Projects` arrives as `cd a/Projects`. Driving the
# key by code works only with an explicit `key down shift` / `key up shift` around
# it; the `key code 50 using shift` form arms nothing and emits nothing. And a
# dead key committed with anything other than space yields U+02DC MODIFIER LETTER
# SMALL TILDE rather than ASCII `~`, which renders almost identically and fails as
# a path.
#
# Pasting is immune to all three, and is faster than per-character keystrokes.
type_line() {
    act
    printf '%s' "$1" | pbcopy
    osascript -e 'tell application "System Events" to keystroke "v" using command down' \
              -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
    sleep 1.4
}

# Captures the window with a small margin, in points, which screencapture takes
# and renders at the display's real scale.
shot() {
    act; sleep 0.8
    local geom pos size x y w h
    geom=$(osascript -e 'tell application "System Events" to tell process "baia" to get {position, size} of window 1' 2>/dev/null)
    x=$(echo "$geom" | cut -d, -f1 | tr -d ' ')
    y=$(echo "$geom" | cut -d, -f2 | tr -d ' ')
    w=$(echo "$geom" | cut -d, -f3 | tr -d ' ')
    h=$(echo "$geom" | cut -d, -f4 | tr -d ' ')
    # The AX position already includes the titlebar, so only a hairline margin is
    # wanted. A larger one drags in whatever sits above the window.
    screencapture -x -o -R"$x,$y,$w,$h" "$OUT/$1.png"
    echo "  wrote $OUT/$1.png"
}

# Clicks a point given in window coordinates, in points, with the origin at the
# top-left of the titlebar, which is what the AX position reports.
#
# The sidebar takes no first responder by design, so a row cannot be reached by
# keyboard and a capture of it has to click. It cannot be clicked by AppleScript
# either: `System Events click at` resolves the accessibility element under the
# point and presses it, and a custom-drawn view answering `mouseDown` implements
# no press, so the call reports the element it found and nothing happens. That is
# what `click.swift` is for, and it posts a real event.
CLICK=".build/click"
[ -x "$CLICK" ] || swiftc -O design-captures/click.swift -o "$CLICK"

click_pt() {
    act; sleep 0.4
    local geom x y
    geom=$(osascript -e 'tell application "System Events" to tell process "baia" to get position of window 1' 2>/dev/null)
    x=$(echo "$geom" | cut -d, -f1 | tr -d ' ')
    y=$(echo "$geom" | cut -d, -f2 | tr -d ' ')
    "$CLICK" $((x + $1)) $((y + $2))
    sleep 1.0
}

# Clicks the n-th row of a sidebar section, 1-based, given the section's first
# row centre. Rows are 18 pt and the click lands mid-row.
#
# Measured against a capture rather than read off the geometry constants: the
# first row centre sits 68 pt below the window top under a 28 pt heading, and the
# spacing that reproduces is 17.5 pt.
click_row() { click_pt 60 "$(python3 -c "print(int($1 + ($2 - 1) * 17.5))")"; }

# Relaunches with the sidebar in a named state: off, changes, files, both.
#
# Written into the config rather than cycled with `View → Switch Sidebar`,
# because the cycle starts from whatever the owner's own file says and a capture
# that counts keystrokes lands somewhere different on every machine. The first
# run of this set pressed ⌘⌥S once expecting `changes` and got `off`, since the
# config here already said `both`.
restart() {
    local content=${1:-off}
    pkill -f "baia.app/Contents/MacOS/baia" 2>/dev/null
    sleep 1.5
    rm -f "$SESSION"
    python3 - "$CONFIG" "$content" <<'PY'
import json, sys
path, content = sys.argv[1], sys.argv[2]
settings = json.load(open(path))
settings["sidebar"] = content
json.dump(settings, open(path, "w"), indent=2)
PY
    open "$APP"
    sleep 5
}

echo "01 four-pane window"
restart
key 'keystroke "d" using command down'
key 'keystroke "d" using {command down, shift down}'
key 'key code 123 using {command down, option down}'
key 'keystroke "d" using {command down, shift down}'
shot 01-four-pane-window

echo "02 three repositories, three git states"
restart
key 'keystroke "d" using command down'
key 'keystroke "d" using command down'
type_line "cd ~/Projects/website/admin"
key 'key code 123 using {command down, option down}'
type_line "cd ~/Projects/vault"
key 'key code 123 using {command down, option down}'
type_line "cd ~/Projects/baia"
shot 02-three-repos-git-states

echo "03 pinned pane"
# Pin the focused pane to ~/Projects, which is not a repository, so the footer
# shows the pin marker, the working directory, and no git segments at once.
act
osascript -e 'tell application "System Events" to keystroke "p" using {command down, shift down}' >/dev/null 2>&1
sleep 2
osascript -e 'tell application "System Events" to keystroke "g" using {command down, shift down}' >/dev/null 2>&1
sleep 1.5
osascript -e 'tell application "System Events" to keystroke "/Users/pasqualotto/Projects"' >/dev/null 2>&1
sleep 1
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 1.5
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2.5
shot 03-pinned-pane

echo "04 attention marker"
# Ring the bell in a pane, then move focus away so the request is still standing
# when the shot is taken. Focusing the pane is what clears it.
type_line "sleep 6; tput bel"
key 'key code 124 using {command down, option down}'
sleep 8
shot 04-attention-marker

echo "05 four tabs"
restart
type_line "cd ~/Projects/baia"
key 'keystroke "t" using command down'; type_line "cd ~/Projects/vault"
key 'keystroke "t" using command down'; type_line "cd /Users/pasqualotto/Projects/website/shop"
key 'keystroke "t" using command down'; type_line "cd /Users/pasqualotto/Projects/scripts"
shot 05-four-tab-bar

echo "06 running agent and a build"
restart
key 'keystroke "d" using command down'
type_line "npm run watch"
key 'key code 123 using {command down, option down}'
type_line "sleep 400"
shot 06-activity-labels

# --- the sidebar ------------------------------------------------------------
# Everything below needs git states no repository on this machine holds at once,
# so they are manufactured. `demo-repo.sh` prints the dirty one then the clean one.
DEMO=$("$(dirname "$0")/demo-repo.sh")
DIRTY=$(echo "$DEMO" | sed -n 1p)
CLEAN=$(echo "$DEMO" | sed -n 2p)

echo "07 changes surface, every marker state"
restart changes
type_line "cd $DIRTY"
shot 07-changes-surface

echo "08 file tree, expanded"
restart files
type_line "cd ~/Projects/baia"
click_row 68 6    # Packages
click_row 68 7    # BaiaSettings, its first child
shot 08-files-tree

echo "09 both sections stacked"
restart both
type_line "cd $DIRTY"
shot 09-both-sections

echo "10 the path picker"
# A click sends the clicked file's path to the focused pane's prompt. Three
# clicks: expand Sources, expand Workspace, then send a file two levels down.
restart files
type_line "cd $DIRTY"
click_row 68 2    # Sources
click_row 68 3    # Workspace
click_row 68 6    # Sources/Workspace/Pane.swift
shot 10-path-picker

echo "11 no changes"
restart both
type_line "cd $CLEAN"
shot 11-no-changes

echo "12 not a repository"
restart both
type_line "cd ~/Projects"
shot 12-not-a-repository

echo "13 sidebar beside three panes"
restart both
type_line "cd $DIRTY"
key 'keystroke "d" using command down'
type_line "cd ~/Projects/vault"
key 'keystroke "d" using {command down, shift down}'
type_line "cd ~/Projects/website/admin"
key 'key code 123 using {command down, option down}'
key 'key code 123 using {command down, option down}'
shot 13-sidebar-and-panes

pkill -f "baia.app/Contents/MacOS/baia" 2>/dev/null
echo "done"
