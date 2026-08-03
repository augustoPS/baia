#!/usr/bin/env bash
# Drives the running app: activation, keys, text, clicks, window captures.
#
# Sourced, not run. Every function here needs baia already launched.
#
#   source "$(dirname "$0")/../lib/drive.sh"
#
# Callers set two variables first:
#   OUT   where `shot` writes its PNGs. Created if absent.
#   REPO  the repository root, so `click.swift` can be found and built.
#
# Extracted from capture.sh on 2026-07-30, unchanged, when path-picker needed the
# same clicking. Everything below was learned the hard way and each comment names
# the failure behind it; none of it is preference.

: "${OUT:?drive.sh needs OUT set to an output directory}"
: "${REPO:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
mkdir -p "$OUT"

# Every function below names the app, and naming it wrong is how a probe drives
# the build the owner is working in. Sourced here rather than left to the caller
# so that cannot be forgotten in a fifth driver: `app-identity.sh` refuses
# without APP, so a caller that has not said which bundle it launched stops here
# instead of defaulting to whichever one answers.
: "${APP:?drive.sh needs APP set to the .app bundle under test}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app-identity.sh"

# A driven run is minutes of no human input, which is long enough for the display
# to sleep. A slept display has no windows to ask about: `window 1` becomes an
# invalid index, `screencapture -R` refuses the rect, and the run dies halfway
# through looking like an app bug. Held awake for as long as the caller lives.
caffeinate -dimsu -w $$ &

# **Assistive access, checked once and loudly, because without it a driven run is
# a silent no-op that reports findings.** Every `osascript` below sends its errors
# to /dev/null so a transient AppleScript hiccup does not spray a run, and the
# cost of that showed on 2026-08-03: a caller with Automation permission but not
# Accessibility activated the app successfully and then had every `keystroke` and
# every window-geometry query fail without a word. Nothing was typed, nothing was
# clicked, `screencapture -R` refused an empty rect, and the probe reported two
# byte-level failures against a build that had done nothing wrong. That is the
# expensive kind of wrong: it sends the reader somewhere there is nothing to find.
#
# Only `-1719` counts. A machine that *has* the grant can still fail this query
# for ordinary reasons, Finder having no open window being the obvious one, and
# aborting on that would trade a silent no-op for a false refusal.
#
# The grant is per calling process, so it is the terminal or the agent host that
# needs it and not baia: System Settings > Privacy & Security > Accessibility.
assistive_error=$(osascript -e 'tell application "System Events" to get position of window 1 of process "Finder"' 2>&1 >/dev/null)
case "$assistive_error" in
    *-1719*|*"not allowed assistive access"*)
        echo "ABORT: this process has no Accessibility permission, so nothing can be" >&2
        echo "       typed or clicked and every check below would fail for that reason" >&2
        echo "       rather than for anything about the app." >&2
        echo "       osascript said: $assistive_error" >&2
        echo "       Grant it to the app hosting this shell in System Settings >" >&2
        echo "       Privacy & Security > Accessibility, then run again." >&2
        exit 1
        ;;
esac
unset assistive_error

# Activates the app under test and refuses to continue until it is genuinely
# frontmost.
#
# Without the check, a slow activation sends the next keystroke to whatever app
# is in front. During one run that typed `cd /Users/.../shop` into the terminal
# running Claude Code, which is harmless there but would not be if the leaked
# line were destructive.
#
# **By bundle id, since 2026-08-02.** This said `tell application "baia"` and
# compared the frontmost name against the literal `"baia"`, both written when one
# app had that name. With the Release build installed, AppleScript resolves the
# name to it, so a probe launching `baia-dev.app` activated the daily driver, the
# guard confirmed something called baia was in front, and the run typed into it.
# The guard was working; it was asking about the wrong app.
act() { activate_app || exit 1; }

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

# Types without committing, so the prompt line can be inspected before Return.
# `type_line` presses Return; this one does not.
type_raw() {
    act
    printf '%s' "$1" | pbcopy
    osascript -e 'tell application "System Events" to keystroke "v" using command down' >/dev/null 2>&1
    sleep 0.8
}

# Captures the window with a small margin, in points, which screencapture takes
# and renders at the display's real scale.
shot() {
    act; sleep 0.8
    local geom x y w h
    geom=$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get {position, size} of window 1" 2>/dev/null)
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
# keyboard and a check on it has to click. It cannot be clicked by AppleScript
# either: `System Events click at` resolves the accessibility element under the
# point and presses it, and a custom-drawn view answering `mouseDown` implements
# no press, so the call reports the element it found and nothing happens. That is
# what `click.swift` is for, and it posts a real event.
CLICK="$REPO/.build/click"
[ -x "$CLICK" ] || swiftc -O "$REPO/Diagnostics/lib/click.swift" -o "$CLICK"

click_pt() {
    act; sleep 0.4
    local geom x y
    geom=$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get position of window 1" 2>/dev/null)
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
