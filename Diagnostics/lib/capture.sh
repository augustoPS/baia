#!/usr/bin/env bash
# Regenerates the Claude Design handover captures.
#
# Drives the real app through AppleScript and captures the window rather than the
# screen, so the output is usable as a design reference rather than a desktop
# photo. Run from the repo root after `make build`.
#
#   ./Diagnostics/lib/capture.sh [output-directory]
#
# Writes into `design/handoffs/captures` by default, which is the Claude Design
# side of the repo and is gitignored. The script itself lives here because it
# drives the real app, which is what everything in Diagnostics does, and because
# design/ is ignored: anything worth keeping cannot live there.
#
# Two things that will bite anyone editing this:
#   - Text is pasted, never typed. `System Events keystroke` cannot produce `~` or
#     `^` under the U.S. International layout and silently substitutes `a`, so
#     `cd ~/Projects` arrives as `cd a/Projects`. See `type_line`.
#   - baia must be frontmost before any keystroke, or the key goes to whatever is.
#     That is what `act` is for, and why every helper calls it first.
set -uo pipefail

APP=".build/Build/Products/Debug/baia.app"
OUT="${1:-design/handoffs/captures}"
SESSION="$HOME/Library/Application Support/baia/session.json"
CONFIG="$HOME/.config/baia/config.json"
mkdir -p "$OUT"

# The captures set `sidebar` per scenario, so the owner's own file is put back
# whatever happens. Without this a killed run leaves their sidebar wherever the
# last capture wanted it.
#
# The session file needs the same treatment and did not have it until 2026-07-30.
# `restart` deletes it on every scenario, twelve times in a run, so a finished run
# left the app reopening in whatever throwaway fixture the last capture used and
# the real workspace gone. One run on 2026-07-29 lost it to
# /tmp/baia-design-demo/dirty that way.
CONFIG_BACKUP=$(mktemp)
SESSION_BACKUP=$(mktemp)
cp "$CONFIG" "$CONFIG_BACKUP" 2>/dev/null
cp "$SESSION" "$SESSION_BACKUP" 2>/dev/null
trap 'cp "$CONFIG_BACKUP" "$CONFIG" 2>/dev/null; cp "$SESSION_BACKUP" "$SESSION" 2>/dev/null; rm -f "$CONFIG_BACKUP" "$SESSION_BACKUP"' EXIT

# Activation, keys, text, clicks and window captures all live in drive.sh, which
# path-picker's runner shares. OUT is set above; REPO defaults to the repo root.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drive.sh"

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
