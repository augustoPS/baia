#!/usr/bin/env bash
# Opens panes that run a command, against the running app, and looks at them.
#
#   ./Diagnostics/split-command/run.sh            drives the app, needs it running
#   ./Diagnostics/split-command/run.sh --refusals just the parse checks, no app
#
# The question it answers is **what ghostty actually does with the `command`
# config key**, which its own documentation gets wrong, and therefore what a
# caller of `baia split --command` has to write.
#
# The refusal half needs no app: parsing happens before the environment check, so
# `baia split --command` can be exercised with no socket at all. The driving half
# needs a real window and a real surface, which is what makes this a probe rather
# than a package test: nothing about a shell that ghostty spawns is decidable
# without spawning one.
#
# The driving half types into the *focused* pane. Focus it on a plain shell
# first. `⌥⌘←` and `⌥⌘→` move focus; the run refuses to type if baia is not
# frontmost, which is `drive.sh`'s own rule and the reason it exists.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN="$ROOT/.build/Build/Products/Debug/baia-dev.app/Contents/Helpers/baia"
OUT="${TMPDIR:-/tmp}/baia-split-command"

pass=0
fail=0
ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; echo "        $2"; fail=$((fail + 1)); }

[ -x "$BIN" ] || { echo "ABORT: no baia at $BIN. Run make build first." >&2; exit 2; }

echo "-- what the CLI refuses, before it opens anything"

# Parsing happens before the environment check, so these exercise the real
# refusals with no socket rather than dying on a missing one.
refusal() {
    local label=$1
    shift
    local out status
    out=$(env -u BAIA_SOCK -u BAIA_TOKEN "$BIN" "$@" 2>&1)
    status=$?
    if [ "$status" = "1" ] && printf '%s' "$out" | grep -q -- "--command"; then
        ok "$label"
    else
        bad "$label" "exit $status: $out"
    fi
}

# **The newline rule is the one that matters.** The value is rendered into a
# ghostty config file as `command = <value>` and that file is parsed line by
# line, so a value carrying a newline writes a second key of the caller's
# choosing. `clipboard-read = allow` is one line long and undoes the OSC 52
# denial every pane is built with.
refusal "a newline in --command is refused" \
    split --command "$(printf 'claude\nclipboard-read = allow')"
refusal "a carriage return in --command is refused" \
    split --command "$(printf 'claude\rclipboard-read = allow')"
refusal "an empty --command is refused" split --command ""
refusal "--command with nothing after it is refused" split --command
refusal "a --command over the cap is refused" \
    split --command "$(head -c 5000 < /dev/zero | tr '\0' 'x')"

out=$(env -u BAIA_SOCK -u BAIA_TOKEN "$BIN" split --command "claude --resume x" 2>&1)
status=$?
if [ "$status" = "2" ]; then
    ok "an ordinary --command parses and dies on the missing socket instead"
else
    bad "an ordinary --command parses and dies on the missing socket instead" "exit $status: $out"
fi

if "$BIN" --help | grep -q -- "--command"; then
    ok "the help names --command"
else
    bad "the help names --command" "no --command in baia --help"
fi

if [ "${1:-}" = "--refusals" ]; then
    echo
    if [ "$fail" -eq 0 ]; then echo "PASS $pass checks (refusals only)"; exit 0; fi
    echo "FAILED $fail of $((pass + fail))"
    exit 1
fi

echo "-- against the running app"

if ! pgrep -x baia > /dev/null; then
    echo "SKIP: baia is not running. make run, focus a shell pane, then rerun." >&2
    echo
    if [ "$fail" -eq 0 ]; then echo "PASS $pass checks (refusals only; app half skipped)"; exit 0; fi
    echo "FAILED $fail of $((pass + fail))"
    exit 1
fi

mkdir -p "$OUT"
# shellcheck source=../lib/drive.sh
OUT="$OUT" REPO="$ROOT" source "$ROOT/Diagnostics/lib/drive.sh"

# The value goes through a file rather than through the typed line, so the shell
# being typed into never re-quotes it. Everything here has single quotes in it
# and the point is to deliver them unchanged.
value() { printf '%s' "$1" > "$OUT/value.txt"; }
run_split() {
    value "$1"
    type_line "CMD=\$(cat \"$OUT/value.txt\"); baia split --command \"\$CMD\""
    sleep 3
}

# **No leading `exec`, and this is the whole finding.** Ghostty does not run the
# value through `/bin/sh -c` the way its documentation reads. Measured 2026-08-01
# by reading its own failure screen, it runs:
#
#   /usr/bin/login -q -flp <user> /bin/bash --noprofile --norc -c exec -l <value>
#
# so the `exec -l` is already supplied, and a value beginning with one becomes
# `exec -l exec …`, which asks bash for a program called `exec`. That wrapper is
# also why a login PATH is present at all: `/usr/bin/login` builds one, which a
# bare command value would not get.
#
# The trailing `exec "$SHELL" -l` is what keeps the pane once the command is
# done, so it becomes an ordinary terminal rather than closing.
run_split "'/bin/zsh' -lc 'echo SPLIT-COMMAND-OK; echo PATH-CLAUDE=\$(command -v claude || echo MISSING); exec \"\$SHELL\" -l'"
shot 01-command

cat <<'LOOK'

  LOOK at 01-command.png. The new pane should show, in order:

    SPLIT-COMMAND-OK
    PATH-CLAUDE=/…/claude          not MISSING, which is the login PATH working
    a shell prompt                 not a closed pane, and not ghostty's red
                                   "failed to launch the requested command"

  A red failure screen naming `exec -l exec` means a leading exec came back.
  MISSING means the login wrapper stopped building a PATH, and anything that
  relies on finding a tool by name in a spawned pane is broken with it.
LOOK

echo
if [ "$fail" -eq 0 ]; then
    echo "PASS $pass automated checks, plus one capture to LOOK at"
    exit 0
fi
echo "FAILED $fail of $((pass + fail))"
exit 1
