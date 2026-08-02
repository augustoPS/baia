#!/usr/bin/env bash
# Spawns three executors as a 1|3 split: the caller keeps the left column, the
# three executors stack down the right one.
#
#   spawn-1x3.sh <run-dir> <wt1> <brief1> <model1> <wt2> <brief2> <model2> <wt3> <brief3> <model3>
#
# Run from inside the pane that will be the observer. That pane ends up the left
# column and the direct parent of all three executors.
#
# ## Three splits and two moves
#
# `split` splits the calling pane and stamps `createdBy` with it, so three splits
# from here give three children and four columns. The two moves then carry the
# middle two into the right column, and a move changes geometry only: nothing is
# created and nothing is closed, so `PaneGraph` is never called and the parentage
# the splits established is exactly the parentage that survives.
#
# In tree terms, writing the caller `A`:
#
#   split, split, split   h(h(h(A,P3),P2),P1)          four columns
#   move P2 beside P1 ▼   h(h(A,P3), v(P1,P2))
#   move P3 beside P2 ▼   h(A, v(P1, v(P2,P3)))        A | P1/P2/P3
#
# ## What this replaces, and why
#
# The first version was a chain: the observer made pane 1, pane 1's command made
# pane 2, pane 2's made pane 3. It reached the same shape and paid for it, because
# `PaneGraph.close(pane:)` sets `parentOf[child] = nil` and does not reparent to
# the grandparent. Closing pane 1 orphaned panes 2 and 3 out of the observer's
# scope with no error: `list` simply returned fewer panes.
#
# Flat parentage has no such failure. Each executor is a direct child of the
# observer, so closing one takes nothing else with it. The chain also needed a
# script per pane on disk, to escape three levels of quoting inside one
# `--command`; a flat split needs none, since nothing nests.
#
# The move verb this leans on was verified live on 2026-08-02 rather than assumed:
# `Diagnostics/pane-move/live.sh` moves a real pane and checks the shell came
# through it with the same pid and the same scrollback.
set -euo pipefail

[ "$#" -eq 10 ] || { echo "usage: $0 <run-dir> then three of <worktree> <brief> <model>" >&2; exit 2; }

RUN=$1; shift
[ -n "${BAIA_SOCK:-}" ] || { echo "no BAIA_SOCK: run this from inside a baia pane" >&2; exit 2; }
[ -n "${BAIA_PANE:-}" ] || { echo "no BAIA_PANE: run this from inside a baia pane" >&2; exit 2; }
baia --help 2>/dev/null | grep -q '^  move ' || {
  echo "the running baia has no 'move' verb, so it predates 2026-08-02." >&2
  echo "This layout needs it. Relaunch the dev build." >&2
  exit 2
}
mkdir -p "$RUN"

WT=("$1" "$4" "$7")
BRIEF=("$2" "$5" "$8")
MODEL=("$3" "$6" "$9")

for i in 0 1 2; do
  [ -d "${WT[$i]}" ] || { echo "missing worktree: ${WT[$i]}" >&2; exit 2; }
  [ -f "${BRIEF[$i]}" ] || { echo "missing brief: ${BRIEF[$i]}" >&2; exit 2; }
done

# A `--command` pane closes when its command exits, so every value ends with an
# exec to leave a shell behind. No newlines are permitted in the value, and the
# brief reaches the agent through a file the command reads rather than inline.
#
# `split` prints the new pane's id. Read rather than inferred: `baia list` is
# ordered by the scope walk, which sorts siblings by id, so taking creation order
# from it is a guess that has already been wrong twice in this directory.
# `SPAWN_1X3_REHEARSE` swaps the agent for an echo, so the geometry can be
# exercised without paying for three sessions. Everything else runs unchanged:
# the same three splits, the same two moves, the same assertion. What it does not
# rehearse is an agent's own startup, which is the slowest part of a real wave and
# the part nothing here depends on.
spawn() {                       # spawn <dir> <brief> <model>
  if [ -n "${SPAWN_1X3_REHEARSE:-}" ]; then
    baia split --right --cwd "$1" --command \
      "'/bin/zsh' -lc 'echo \"REHEARSAL pane=\$BAIA_PANE cwd=$1\"; exec \"\$SHELL\" -l'" \
      | tr -d '[:space:]'
    return
  fi
  baia split --right --cwd "$1" --command \
    "'/bin/zsh' -lc 'claude --model $3 \"\$(cat $2)\"; exec \"\$SHELL\" -l'" \
    | tr -d '[:space:]'
}

echo "spawning three executors..."
PANES=()
for i in 0 1 2; do
  pane=$(spawn "${WT[$i]}" "${BRIEF[$i]}" "${MODEL[$i]}")
  case "$pane" in
    ????????-????-????-????-????????????) ;;
    *) echo "split did not answer with a pane id, got: '$pane'" >&2; exit 2 ;;
  esac
  PANES+=("$pane")
  sleep 1
done

# The splits ran in order, so PANES[0] is the rightmost column and the two after
# it were carved out of the caller's own rectangle, leftmost last. Stacking them
# under the first in spawn order is what puts brief 1 at the top of the column.
echo "arranging into one column..."
baia move "${PANES[1]}" --beside "${PANES[0]}" --down >/dev/null
baia move "${PANES[2]}" --beside "${PANES[1]}" --down >/dev/null

# Otherwise the column is halves of halves: the first pane takes half the height
# and the last takes an eighth. `equalize` acts on the caller's whole tab, which
# also evens the two columns, and that is wanted here rather than tolerated.
baia equalize >/dev/null 2>&1 || echo "  note: equalize refused; the column will be uneven"

echo
echo "panes now in scope:"
baia list --tree

# Asserted rather than assumed. Every executor must be a direct child of this
# pane, which is the property the chain could not keep and the reason for the
# rewrite: a flat parent means closing one executor takes nothing else with it.
mine=$(baia list --json | python3 -c '
import json, os, sys
me = os.environ["BAIA_PANE"]
print(sum(1 for p in (json.load(sys.stdin).get("panes") or []) if p.get("createdBy") == me))
')
if [ "$mine" != "3" ]; then
  echo >&2
  echo "expected 3 direct children, found $mine. The moves should not have changed" >&2
  echo "parentage at all, so this means something other than a move happened." >&2
  exit 2
fi
echo
echo "  3 executors, all direct children of this pane."
