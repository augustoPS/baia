#!/usr/bin/env bash
# Who the app under test is, derived from the bundle rather than spelled.
#
# Sourced, not run. The caller sets APP to the bundle it launches, then:
#
#   APP=".build/Build/Products/Debug/baia-dev.app"
#   source "$(dirname "$0")/../lib/app-identity.sh"
#
# Exports APP_BUNDLE (absolute), APP_NAME (the process and AppleScript name),
# APP_ID (the bundle identifier), APP_SUPPORT (its Application Support directory)
# and APP_SESSION / APP_SOCKET inside it, and provides `quit_app`,
# `app_is_running` and `activate_app`.
#
# ## Why this file exists
#
# Two builds have existed since 2026-08-02: `baia.app` / `pasqualotto.baia` in
# `/Applications`, used daily, and `baia-dev.app` / `pasqualotto.baia.dev` under
# `.build`, which is what every probe here launches. The split updated `APP` in
# all four drivers and updated neither of the two places that *name* the app, so
# the harness spent the interval launching one build and talking to the other.
#
# **`pkill -f "baia.app/Contents/MacOS/baia"`**, in six places. `baia-dev.app`
# does not contain the substring `baia.app`, so this never matched the build the
# probe launched. It matched `/Applications/baia.app/Contents/MacOS/baia` exactly,
# so each of those six lines left the dev build running and killed the daily
# driver instead. `capture.sh` did it twice per run, once inside `restart()`.
#
# **`tell application "baia"`**, in eight places. AppleScript resolves that name
# to the Release bundle whenever it is installed, so a probe would activate,
# type into, and screenshot the daily driver while the build it launched sat
# behind. `drive.sh`'s frontmost check compares against `"baia"` too, so it
# confirmed the wrong app was in front and continued.
#
# **`Application Support/baia/`**, in eight places across five probes. The Debug
# build owns `baia-dev/`, so every probe that seeded a `session.json`, deleted
# one, or reached for a `control.sock` was operating on the daily driver's state
# while testing a build that could not see it. A probe asserting that a session
# restored would seed the Release file, launch the Debug build, and read back
# whatever the Debug build had saved on its own.
#
# **`pgrep -f "baia.app/…"`**, in three places, with the same miss as `pkill`,
# and **`BIN="$APP/Contents/MacOS/baia"`** in `config-wiring`, which after the
# rename names a file that does not exist.
#
# That combination is worse than any one part. `act()` exists because a slow
# activation once typed a `cd` into a pane running Claude Code; with the Release
# build answering to the name, the guard passes and the typing lands in whatever
# that app is doing.
#
# Nothing here spells either name. `CFBundleExecutable` and `CFBundleIdentifier`
# come out of the bundle the caller actually launches, so a third configuration
# would work without touching this file, and a renamed one cannot half-update.
set -uo pipefail

: "${APP:?app-identity.sh needs APP set to a .app bundle path}"

[ -d "$APP" ] || { echo "no such bundle: $APP" >&2; return 1 2>/dev/null || exit 1; }

APP_BUNDLE=$(cd "$APP" && pwd)
APP_PLIST="$APP_BUNDLE/Contents/Info.plist"
[ -f "$APP_PLIST" ] || { echo "no Info.plist in $APP_BUNDLE" >&2; return 1 2>/dev/null || exit 1; }

# Read rather than guessed from the directory listing: `Contents/MacOS` also
# holds `__preview.dylib` and a `.debug.dylib` in a Debug build, so picking the
# first entry is a coin toss that happens to be right.
APP_NAME=$(plutil -extract CFBundleExecutable raw -o - "$APP_PLIST")
APP_ID=$(plutil -extract CFBundleIdentifier raw -o - "$APP_PLIST")
APP_EXEC="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

[ -n "$APP_NAME" ] || { echo "no CFBundleExecutable in $APP_PLIST" >&2; return 1 2>/dev/null || exit 1; }
[ -x "$APP_EXEC" ] || { echo "not executable: $APP_EXEC" >&2; return 1 2>/dev/null || exit 1; }

# Where this build keeps `session.json`, `control.sock` and
# `recent-projects.tsv`. Read from `BAIASupportDirectory`, which is the same key
# `Sources/SupportDirectory.swift` reads at launch, so a probe and the app it
# launched cannot disagree about which directory is in play. Spelling it
# `baia` here is what made five probes seed the daily driver's session and then
# assert against a build that never saw it.
APP_SUPPORT_NAME=$(plutil -extract BAIASupportDirectory raw -o - "$APP_PLIST" 2>/dev/null)
[ -n "$APP_SUPPORT_NAME" ] || {
    echo "no BAIASupportDirectory in $APP_PLIST" >&2
    return 1 2>/dev/null || exit 1
}
APP_SUPPORT="$HOME/Library/Application Support/$APP_SUPPORT_NAME"
APP_SESSION="$APP_SUPPORT/session.json"
APP_SOCKET="$APP_SUPPORT/control.sock"

# `pkill -f` takes an extended regular expression and matches it against the
# whole command line, so every metacharacter in an absolute path has to be
# escaped or the pattern is wider than the path. `.` is the one that matters and
# is exactly how the old pattern reached the wrong bundle: unescaped, `baia.app`
# matches `baiaXapp` as well.
APP_EXEC_PATTERN="^$(printf '%s' "$APP_EXEC" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"

# Kills the app this probe launched, and only that one.
#
# Anchored at the start of the command line against the bundle's absolute path,
# so it cannot reach a second copy of baia under any other prefix. The daily
# driver in `/Applications` is safe by construction rather than by care.
#
# **⌘Q where the session matters.** `tree-expansions/README.md` says it: the
# session is flushed as the app terminates and a killed process flushes nothing,
# so a probe checking persistence must quit rather than kill. This is for the
# probes that want the process gone and the state discarded.
quit_app() {
    pkill -f "$APP_EXEC_PATTERN" 2>/dev/null
    return 0
}

# True while the app this probe launched is running.
app_is_running() {
    pgrep -f "$APP_EXEC_PATTERN" >/dev/null 2>&1
}

# Brings it to the front and refuses to continue until it is genuinely there.
#
# By bundle id rather than by name, because two bundles answer to names one
# character apart and only the id is unique. The frontmost check compares against
# `APP_NAME`, which is the process name macOS reports, so it confirms *this*
# build came forward rather than that something called baia did.
activate_app() {
    local front
    for _ in 1 2 3 4 5 6 7 8; do
        osascript -e "tell application id \"$APP_ID\" to activate" >/dev/null 2>&1
        sleep 0.5
        front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
        [ "$front" = "$APP_NAME" ] && return 0
    done
    echo "  ABORT: $APP_NAME never came to the front, refusing to type into $front" >&2
    return 1
}
