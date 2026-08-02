#!/usr/bin/env bash
# Spawns three executors as a 1|3 split: the caller keeps the left column, the
# three executors stack down the right one.
#
#   spawn-1x3.sh <run-dir> <wt1> <brief1> <model1> <wt2> <brief2> <model2> <wt3> <brief3> <model3>
#
# Run from inside the pane that will be the observer. That pane ends up the left
# column and the parent of the whole right one.
#
# ## Why a chain and not three splits
#
# `split` splits **the calling pane** and stamps `createdBy` with it, so the
# layout and the channel are the same act. Three splits from the observer would
# subdivide the observer's own rectangle three times and give four columns, never
# a column of three beside it.
#
# So each pane splits the next: the observer makes pane 1, pane 1's command makes
# pane 2 before starting its agent, pane 2's makes pane 3. Each split is `--down`
# inside the right column, which is how the stack appears.
#
# The observer still sees all three. `ControlServer.scope(of:)` walks children
# transitively, pushing each one back on the frontier, so a chain three deep is
# one scope. That is the property this whole topology rests on and it is worth
# knowing by name rather than by hope.
#
# ## What it costs, and it is not nothing
#
# `PaneGraph.close(pane:)` sets `parentOf[child] = nil` for every child of a
# closing pane, and does **not** reparent to the grandparent. That is deliberate,
# and `SessionStore.reconciled` states the reason: reparenting would silently
# widen whoever inherited the child.
#
# In a chain it means closing pane 1 orphans panes 2 and 3 out of the observer's
# scope. The observer does not error; it sees fewer panes and goes on writing
# verdicts about the one that is left. Three flat siblings would not have this
# failure, and they also cannot make this layout.
#
# **The mitigation is in the observer's prompt, not here.** It counts its
# descendants on every wake and reports `blocked` when the count drops, which
# turns a silent blinding into a loud one. A pane closing is already on the
# `--kinds` list it subscribes to, so it costs no extra call.
set -euo pipefail

[ "$#" -eq 10 ] || { echo "usage: $0 <run-dir> then three of <worktree> <brief> <model>" >&2; exit 2; }

RUN=$1; shift
[ -n "${BAIA_SOCK:-}" ] || { echo "no BAIA_SOCK: run this from inside a baia pane" >&2; exit 2; }
[ -n "${BAIA_PANE:-}" ] || { echo "no BAIA_PANE: run this from inside a baia pane" >&2; exit 2; }
mkdir -p "$RUN"

WT=("$1" "$4" "$7")
BRIEF=("$2" "$5" "$8")
MODEL=("$3" "$6" "$9")

for i in 0 1 2; do
  [ -d "${WT[$i]}" ] || { echo "missing worktree: ${WT[$i]}" >&2; exit 2; }
  [ -f "${BRIEF[$i]}" ] || { echo "missing brief: ${BRIEF[$i]}" >&2; exit 2; }
done

# One script per pane, on disk, rather than three levels of quoting inside one
# `--command` value. The same reason the brief reaches an executor through a file:
# a newline is refused at the CLI and again at the server, and a nested quote that
# survives both is a quote nobody can read.
#
# Each script splits the *next* pane first and starts its own agent second,
# because the agent blocks. A split written after it never runs.
for i in 0 1 2; do
  n=$((i + 1))
  # The last pane splits nothing, and says so rather than carrying a comment
  # about a line that is not there.
  if [ "$i" -lt 2 ]; then
    j=$((i + 1))
    next="# The split comes first because the agent below it blocks until it exits,
# and a split written after it would never run.
baia split --down --cwd '${WT[$j]}' --command \"'/bin/zsh' -lc '$RUN/pane-$((n + 1)).sh'\""
  else
    next="# The bottom of the column. Nothing left to split."
  fi
  cat > "$RUN/pane-$n.sh" <<PANE
#!/bin/zsh
# Pane $n of the right column. Written by spawn-1x3.sh. Do not edit.
$next
claude --model ${MODEL[$i]} "\$(cat '${BRIEF[$i]}')"
# The pane would close when the command exits without this, taking its scrollback
# and its place in the layout with it.
exec "\$SHELL" -l
PANE
  chmod +x "$RUN/pane-$n.sh"
done

echo "wrote $RUN/pane-{1,2,3}.sh"

# The one split this script performs. Everything else happens inside the panes it
# starts, so this returns long before the column is full.
baia split --right --cwd "${WT[0]}" --command "'/bin/zsh' -lc '$RUN/pane-1.sh'"

# Waited for rather than assumed. The chain is three sequential shell startups and
# `list` right after this call reports one child, not three, which would make any
# binding step downstream refuse for the wrong reason.
echo -n "waiting for the column to fill"
for _ in $(seq 1 40); do
  seen=$(baia list --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("panes") or []))' 2>/dev/null || echo 0)
  # The observer plus three, since `list` is scoped to what this pane can see.
  [ "$seen" -ge 4 ] && { echo " ok, $seen panes in scope"; exit 0; }
  echo -n "."
  sleep 1
done

echo
echo "only $seen pane(s) in scope after 40s. The chain stalled: read the right" >&2
echo "column top to bottom and find which pane never ran its split." >&2
exit 2
