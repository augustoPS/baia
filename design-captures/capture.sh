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
#   - `~` is a dead key on this keyboard layout, so every path typed into a pane
#     must be absolute. `cd ~/Projects` silently becomes `cd a/Projects`.
#   - baia must be frontmost before any keystroke, or the key goes to whatever is.
#     That is what `act` is for, and why every helper calls it first.
set -uo pipefail

APP=".build/Build/Products/Debug/baia.app"
OUT="design-captures"
SESSION="$HOME/Library/Application Support/baia/session.json"

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
type_line() {
    act
    osascript -e "tell application \"System Events\" to keystroke \"$1\"" \
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
    screencapture -x -o -R"$((x-2)),$((y-2)),$((w+4)),$((h+4))" "$OUT/$1.png"
    echo "  wrote $OUT/$1.png"
}

restart() {
    pkill -f "baia.app/Contents/MacOS/baia" 2>/dev/null
    sleep 1.5
    rm -f "$SESSION"
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
type_line "cd /Users/pasqualotto/Projects/website/admin"
key 'key code 123 using {command down, option down}'
type_line "cd /Users/pasqualotto/Projects/vault"
key 'key code 123 using {command down, option down}'
type_line "cd /Users/pasqualotto/Projects/baia"
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
type_line "cd /Users/pasqualotto/Projects/baia"
key 'keystroke "t" using command down'; type_line "cd /Users/pasqualotto/Projects/vault"
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

pkill -f "baia.app/Contents/MacOS/baia" 2>/dev/null
echo "done"
