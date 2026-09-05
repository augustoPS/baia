#!/usr/bin/env bash
# Moves a real pane and checks its shell lived through it.
#
#   ./Diagnostics/pane-move/live.sh
#
# **Run this from inside a baia pane**, unlike every other probe here. The others
# quit any running baia and launch their own; this one cannot, because the pane it
# needs is the pane it is running in. It opens two panes, moves one, and leaves
# all three on screen.
#
# The question no package test can answer: `PaneTree.moving` is pure and
# `PaneTreeController.move` calls `rebuild()`, and the whole design rests on
# `rebuild()` re-parenting live surfaces rather than making them
# (`makeViewController` answers a `.leaf(id)` with `panes[id]`). If that were
# wrong the pane would come back as a fresh surface with a fresh shell, and every
# test would still pass.
#
# So the check is a shell's own identity, printed by the shell itself before the
# move and read off the screen after: same pid, same marker, same scrollback.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[ -n "${BAIA_SOCK:-}" ] || { echo "no BAIA_SOCK: run this from inside a baia pane" >&2; exit 2; }
[ -n "${BAIA_PANE:-}" ] || { echo "no BAIA_PANE: run this from inside a baia pane" >&2; exit 2; }
baia --help 2>/dev/null | grep -q '^  move ' || {
  echo "the running baia has no 'move' verb, so it predates the merge." >&2
  echo "Quit this pane's host app and relaunch the same build that is hosting it." >&2
  exit 2
}

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; echo "          wanted: $2"; echo "          got:    $3"; fail=$((fail + 1)); }

# Each new pane prints a marker carrying its own pane id and its own shell pid,
# then keeps the shell. The marker is the evidence: a pane whose surface was
# rebuilt from scratch would come back with an empty screen and a different pid,
# and both halves are in the one line.
MARKER='echo "MARKER pane=$BAIA_PANE pid=$$"; exec "$SHELL" -l'

# `split` prints the new pane's id, so which pane is which is read rather than
# inferred. The first version took them from `baia list` order and called them
# RIGHT and BELOW, which was a guess: `list` is ordered by the scope walk, and
# that walk sorts siblings by id. On the first passing run it handed back the two
# the other way round, so the probe's closing description of the layout was wrong
# while every assertion was right.
echo "opening two panes"
RIGHT=$(baia split --right --command "'/bin/zsh' -lc '$MARKER'" | tr -d '[:space:]')
sleep 2
BELOW=$(baia split --down --command "'/bin/zsh' -lc '$MARKER'" | tr -d '[:space:]')
sleep 3

for pane in "$RIGHT" "$BELOW"; do
  case "$pane" in
    ????????-????-????-????-????????????) ;;
    *) echo "split did not answer with a pane id, got: '$pane'" >&2; exit 2 ;;
  esac
done

# What each pane says about itself before anything moves.
marker_of() { baia read "$1" --lines 40 --json 2>/dev/null | python3 -c '
import json, sys
lines = (json.load(sys.stdin).get("lines") or [])
print(next((l.strip() for l in lines if "MARKER pane=" in l), "(no marker)"))
'; }

BEFORE_RIGHT=$(marker_of "$RIGHT")
BEFORE_BELOW=$(marker_of "$BELOW")
echo "  before: $BEFORE_RIGHT"
echo "  before: $BEFORE_BELOW"
case "$BEFORE_BELOW" in
  *"MARKER pane="*) ok "the pane about to move printed a marker" ;;
  *) bad "the pane about to move printed a marker" "a MARKER line" "$BEFORE_BELOW"; exit 1 ;;
esac
MOVED_PID=$(printf '%s' "$BEFORE_BELOW" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')

echo "moving $BELOW beside $RIGHT"
# Parsed, not matched. The first version tested for the substring `"ok":true` and
# failed against the same response pretty-printed across two lines, reporting a
# refusal on a move that had plainly worked: the four checks below it all passed.
OUT=$(baia move "$BELOW" --beside "$RIGHT" --down --json 2>&1)
VERDICT=$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    print("ok" if json.load(sys.stdin).get("ok") else "refused")
except Exception:
    print("unparseable")
' 2>/dev/null)
case "$VERDICT" in
  ok) ok "the move was accepted" ;;
  *) bad "the move was accepted" "ok" "$VERDICT: $OUT" ;;
esac
sleep 2

# The three checks the package tests cannot make.
AFTER_BELOW=$(marker_of "$BELOW")
echo "  after:  $AFTER_BELOW"

[ "$AFTER_BELOW" = "$BEFORE_BELOW" ] \
  && ok "the moved pane's screen survived the rebuild" \
  || bad "the moved pane's screen survived the rebuild" "$BEFORE_BELOW" "$AFTER_BELOW"

AFTER_PID=$(printf '%s' "$AFTER_BELOW" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
[ -n "$AFTER_PID" ] && [ "$AFTER_PID" = "$MOVED_PID" ] \
  && ok "the moved pane's shell is the same process ($MOVED_PID)" \
  || bad "the moved pane's shell is the same process" "pid $MOVED_PID" "pid ${AFTER_PID:-none}"

# Alive rather than merely remembered: the marker is scrollback and would survive
# a dead shell, so the process is asked about separately.
if [ -n "$MOVED_PID" ] && ps -p "$MOVED_PID" >/dev/null 2>&1; then
  ok "that process is still running"
else
  bad "that process is still running" "pid $MOVED_PID alive" "gone"
fi

AFTER_RIGHT=$(marker_of "$RIGHT")
[ "$AFTER_RIGHT" = "$BEFORE_RIGHT" ] \
  && ok "the pane it landed beside was not disturbed" \
  || bad "the pane it landed beside was not disturbed" "$BEFORE_RIGHT" "$AFTER_RIGHT"

echo
echo "  $pass passed, $fail failed"
echo "  Look at the window. $BELOW has left the column it was in and now sits"
echo "  under $RIGHT, and every pane took a SIGWINCH on the way, which is the"
echo "  stated cost and the one thing no assertion here covers. Close them by hand."
[ "$fail" -eq 0 ] || exit 1
