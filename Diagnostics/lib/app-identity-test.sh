#!/usr/bin/env bash
# Asserts which processes a kill pattern would reach, without killing anything.
#
# `pkill -f <pattern>` matches an extended regular expression against a whole
# command line, so `grep -E` against the command-line strings answers exactly the
# same question and answers it with no process running and nothing at risk. That
# matters here more than it usually would: the thing under test decides whether a
# probe kills the build it launched or the one the owner is working in.
#
# Runs from any directory. Launches nothing, kills nothing, needs no window.
set -uo pipefail
cd "$(dirname "$0")/../.."

fails=0

# The two command lines that actually exist on this machine.
RELEASE="/Applications/baia.app/Contents/MacOS/baia"
DEBUG="$(pwd)/.build/Build/Products/Debug/baia-dev.app/Contents/MacOS/baia-dev"

matches() {                     # matches <pattern> <command-line>
  printf '%s\n' "$2" | grep -Eq "$1"
}

check() {                       # check <hit|miss> <label> <pattern> <command-line>
  local want=$1 label=$2 pattern=$3 line=$4 got=miss
  matches "$pattern" "$line" && got=hit
  if [ "$got" != "$want" ]; then
    printf 'FAIL want=%s got=%s  %s\n' "$want" "$got" "$label"
    fails=$((fails + 1))
  else
    printf 'ok   %-4s %s\n' "$want" "$label"
  fi
}

echo "== the pattern this harness used until 2026-08-02"
OLD='baia.app/Contents/MacOS/baia'
# The bug, stated as two assertions. Every probe launches the Debug build, so
# these two lines together say: it left what it started running, and killed the
# app the owner was using instead.
check miss 'old pattern does NOT reach the Debug build it launched' "$OLD" "$DEBUG"
check hit  'old pattern DOES reach the Release daily driver'        "$OLD" "$RELEASE"
# And why: an unescaped `.` is any character, so the pattern was always wider
# than the path it was written as.
check hit  'old pattern also reaches a bundle spelled baiaXapp' \
  "$OLD" "/tmp/baiaXapp/Contents/MacOS/baia"

echo
echo "== the pattern app-identity.sh derives"
APP=".build/Build/Products/Debug/baia-dev.app"
if [ ! -d "$APP" ]; then
  echo "  SKIP: no Debug build at $APP. Run 'make build' first." >&2
  exit 2
fi
source Diagnostics/lib/app-identity.sh

check hit  'reaches the Debug build it launched'         "$APP_EXEC_PATTERN" "$DEBUG"
check miss 'does NOT reach the Release daily driver'     "$APP_EXEC_PATTERN" "$RELEASE"
check miss 'does NOT reach a same-named bundle elsewhere' \
  "$APP_EXEC_PATTERN" "/tmp/baia-dev.app/Contents/MacOS/baia-dev"
# Anchored at the start, so a longer command line with the path as an argument
# is not the process itself.
check miss 'does NOT reach a command that merely mentions the path' \
  "$APP_EXEC_PATTERN" "/bin/cat $DEBUG"
check hit  'still reaches it with launch arguments appended' \
  "$APP_EXEC_PATTERN" "$DEBUG -psn_0_12345"

echo
echo "== identity is read from the bundle, not spelled"
check hit 'APP_NAME came from CFBundleExecutable' "^baia-dev$" "$APP_NAME"
check hit 'APP_ID came from CFBundleIdentifier'   "^pasqualotto\.baia\.dev$" "$APP_ID"

echo
echo "== negative control"
# A pattern that reaches both is what the fix exists to prevent. If this stops
# matching both, the harness above has stopped discriminating and every check
# above it is passing for the wrong reason.
BOTH='MacOS/baia'
check hit 'control: an over-broad pattern reaches Release' "$BOTH" "$RELEASE"
check hit 'control: an over-broad pattern reaches Debug'   "$BOTH" "$DEBUG"

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
