#!/usr/bin/env bash
# Regenerates the Claude Design handover captures.
#
# Drives the real app through AppleScript and captures the window rather than the
# screen, so the output is usable as a design reference rather than a desktop
# photo. Run from the repo root after a Debug build exists. It copies that
# build into an isolated instance and does not rewrite the owner's config or
# session.
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

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"

ISOLATED_LABEL=capture
# shellcheck source=isolated-app.sh
source "$HERE/isolated-app.sh"
isolated_refuse_pane || exit 1
isolated_install_traps
isolated_prepare || exit 1

APP="$ISOLATED_APP"
OUT="${1:-design/handoffs/captures}"
SESSION="$ISOLATED_SESSION"
CONFIG="$ISOLATED_CONFIG"
mkdir -p "$OUT"
isolated_default_config off || exit 1

# Activation, keys, text, clicks and window captures all live in drive.sh, which
# path-picker's runner shares. OUT is set above; REPO defaults to the repo root.
# APP is the isolated copy, so drive.sh's identity helpers cannot reach Debug or
# Release state.
source "$HERE/drive.sh"

# Relaunches with the sidebar in a named state: off, changes, files, both.
#
# Written into the config rather than cycled with `View → Switch Sidebar`,
# because the cycle starts from whatever the owner's own file says and a capture
# that counts keystrokes lands somewhere different on every machine. The first
# run of this set pressed ⌘⌥S once expecting `changes` and got `off`, since the
# config here already said `both`.
restart() {
    local content=${1:-off}
    isolated_stop_owned_process || {
      if [ "${ISOLATED_PROCESS_RETAINED:-0}" = 1 ]; then
        echo "isolated capture app still alive; not relaunching" >&2
        return 1
      fi
    }
    sleep 1.5
    rm -f "$SESSION"
    python3 - "$CONFIG" "$content" <<'PY'
import json, sys
path, content = sys.argv[1], sys.argv[2]
settings = json.load(open(path))
settings["sidebar"] = content
json.dump(settings, open(path, "w"), indent=2)
PY
    isolated_launch || exit 1
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
# Pin the focused pane to ~/Projects, which is not a repository, so the pane's
# chrome shows the pin marker, the working directory, and no git segments at
# once. The three-at-once state is the point of the shot, and a non-repository
# is the only place it occurs. The footer was what displayed it until that view
# was deleted on 2026-08-13; the capsule shows the same combination now, so the
# keystrokes below are unchanged and the capture still earns its place.
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

echo "done"
