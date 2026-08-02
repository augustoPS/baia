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
  echo "Quit it and relaunch:" >&2
  echo "  open $(cd "$HERE/../.." && pwd)/.build/Build/Products/Debug/baia.app" >&2
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

# Panes this one had made *before* this run, so a stray left by an earlier attempt
# is subtracted rather than mistaken for one of today's. Without it a second run
# finds four children, picks two arbitrarily, and moves a pane nobody is watching.
children() {
  baia list --json | python3 -c '
import json, os, sys
me = os.environ["BAIA_PANE"]
for p in json.load(sys.stdin).get("panes") or []:
    if p.get("createdBy") == me:
        print(p["pane"])
'
}
EXISTING=$(children)
[ -n "$EXISTING" ] && echo "  note: this pane already had $(printf '%s\n' "$EXISTING" | wc -l | tr -d ' ') child pane(s); ignoring them"

echo "opening two panes"
baia split --right --command "'/bin/zsh' -lc '$MARKER'" >/dev/null
sleep 2
baia split --down --command "'/bin/zsh' -lc '$MARKER'" >/dev/null
sleep 3

# `while read` rather than `readarray`, which is bash 4 and this machine ships
# 3.2. Found the hard way on the first live run, where the probe opened both panes
# correctly and then could not name them.
KIDS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$EXISTING" in
    *"$line"*) continue ;;
  esac
  KIDS+=("$line")
done <<EOF
$(children)
EOF

if [ "${#KIDS[@]}" -ne 2 ]; then
  echo "expected 2 new panes, got ${#KIDS[@]}. Nothing moved; close any strays by hand." >&2
  exit 2
fi
RIGHT=${KIDS[0]}
BELOW=${KIDS[1]}

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
OUT=$(baia move "$BELOW" --beside "$RIGHT" --down --json 2>&1)
case "$OUT" in
  *'"ok":true'*|*'"ok": true'*) ok "the move was accepted" ;;
  *) bad "the move was accepted" "ok:true" "$OUT" ;;
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
echo "  Look at the window: the two panes should now be stacked in the right"
echo "  column with this one alone on the left. Close them by hand when done."
[ "$fail" -eq 0 ] || exit 1
