#!/usr/bin/env bash
# Spawns one executor pane per brief in `briefs/`, from the pane that runs this,
# then prints the by-hand steps for the observer.
#
# Run this from inside a baia pane. It needs $BAIA_SOCK and $BAIA_TOKEN, which
# only a pane has: the token is the capability the channel authenticates on and
# it is never on disk and never in argv.
set -euo pipefail

# Superseded, and it refuses rather than half-working. `orchestrator.md`, the
# prompt this script spawned executors for and then told you to substitute by
# hand, was retired on 2026-08-02: its binding table named a wave that had merged,
# and a stale table binds panes to items nobody is running and produces verdicts
# that read exactly like a working run.
#
# `orchestrator-standalone.md` replaces the pair. It creates the worktrees, runs
# the gate, spawns through `spawn-1x3.sh`, and binds panes to items by working
# directory after the splits, so there is no table to go stale and no placeholder
# to leave unsubstituted. Doing the setup from inside the orchestrator also
# dissolves what this script needed its generated launcher to guard: the pane that
# creates the executors is the only one that can see them, and it is now the
# orchestrator by construction.
#
# Kept for its history rather than its use. Everything it closed lives on in
# `spawn-1x3.sh`, `trust-worktrees.sh`, `seed-worktree-settings.sh` and
# `brief-check/`, all of which the standalone prompt calls.
cat >&2 <<'RETIRED'
run.sh is retired. Its observer prompt no longer exists.

Use the standalone orchestrator instead, from a baia pane at the repo root:

  cd /Users/pasqualotto/Projects/baia
  claude --model claude-fable-5 "$(cat Diagnostics/observer-pane/orchestrator-standalone.md)"

It creates the worktrees, gates the briefs, spawns the executors and watches
them, so none of this script's by-hand steps are needed.
RETIRED
exit 2

REPO=/Users/pasqualotto/Projects/baia
WT=/Users/pasqualotto/Projects/.worktrees
OBS="$REPO/Diagnostics/observer-pane"
LOG=/tmp/baia-observer

[ -n "${BAIA_SOCK:-}" ] || { echo "no BAIA_SOCK: run this from inside a baia pane" >&2; exit 2; }
[ -n "${BAIA_PANE:-}" ] || { echo "no BAIA_PANE: run this from inside a baia pane" >&2; exit 2; }

# The running app must be new enough to have `split --command`. The pane's baia
# CLI comes from the *running* app's bundle, so an installed copy makes the whole
# toolchain lie consistently: --command reads as missing rather than as stale.
#
# Test the capability, not the path. The path form was tried first and was wrong
# twice over: `ps -o command=` reports whatever argv[0] the launch used, so a dev
# build started with a relative path never matches an absolute prefix, and the
# same check returned empty inside a pane. This asks the running binary what it
# can do, which is the thing that matters.
if ! baia --help 2>/dev/null | grep -q -- '--command'; then
  echo "the running baia's CLI has no 'split --command'." >&2
  echo "It is probably the installed copy. Relaunch the dev build with:" >&2
  echo "  $REPO/.build/Build/Products/Debug/baia.app/Contents/MacOS/baia &" >&2
  exit 2
fi

# The wave is whatever `briefs/` holds, rather than three names written here.
# Hardcoding them meant that retiring a wave to `briefs/spent/` left this script
# pointing at files that had moved, and the failure would have been a `cat` of a
# missing brief inside a pane, which reaches the agent as an empty prompt.
#
# One convention carries it: a brief `X.md` runs in `baia--X` on `observer/X`.
ITEMS=()
for brief in "$OBS"/briefs/*.md; do
  [ -e "$brief" ] || { echo "no briefs in $OBS/briefs" >&2; exit 2; }
  ITEMS+=("$(basename "$brief" .md)")
done

# The observer watches for drift across a wave, and a wave of one is a pane the
# owner can read. Refused rather than run, so nobody spends a Fable session
# learning that.
if [ "${#ITEMS[@]}" -lt 2 ]; then
  echo "only ${#ITEMS[@]} brief in $OBS/briefs: ${ITEMS[*]}" >&2
  echo "The observer measures drift across a wave, so it wants two or more." >&2
  echo "For one item, spawn it directly and read the pane:" >&2
  echo "  baia split --cwd $WT/baia--${ITEMS[0]} --command \\" >&2
  echo "    \"'/bin/zsh' -lc 'claude \\\"\\\$(cat $OBS/briefs/${ITEMS[0]}.md)\\\"; exec \\\"\\\$SHELL\\\" -l'\"" >&2
  exit 2
fi

WORKTREES=()
for w in "${ITEMS[@]}"; do
  [ -d "$WT/baia--$w" ] || { echo "missing worktree: $WT/baia--$w" >&2; exit 2; }
  WORKTREES+=("$WT/baia--$w")
done

# The brief gate, and it blocks rather than warns. On 2026-08-01 two briefs could
# not reach their own goals and both said so in writing, so the observer spent a
# wave judging adherence to instructions that could not arrive.
#
# `briefs/` is the wave definition, so filling it is what planning a wave means and
# the gate reads whatever is in it. It refused the 2026-08-01 briefs until they
# were retired to `briefs/spent/`, which is the behaviour to expect rather than a
# fault to work around.
if ! "$REPO/Diagnostics/brief-check/run.sh"; then
  echo >&2
  echo "refusing to spawn: fix the briefs above first." >&2
  echo "A brief whose verification cannot observe its own change produces work" >&2
  echo "nobody can check, and an observer watching it judges the wrong question." >&2
  exit 2
fi

# Surface 1, closed 2026-08-01: pre-accept the workspace-trust dialog for each
# worktree. Without this every executor halts before its first tool call, and the
# acceptance does not survive a killed session.
"$OBS/trust-worktrees.sh" "${WORKTREES[@]}"

# Surfaces 2 and 4, closed 2026-08-01: the executors' allowlist and guard hook.
# Seeded rather than assumed present. The settings existed for run 2 and were
# hand-written and untracked, so they lived in three directories that get deleted
# and remade, and a fresh worktree met both surfaces again.
"$OBS/seed-worktree-settings.sh" "${WORKTREES[@]}"

# The previous run's verdicts move aside rather than being deleted or left in
# place. Left in place they are a scoring hazard: verdicts are keyed by seq, the
# ring restarts with the app, and run 2's seq 29 would sit in the same directory
# as this run's seq 29 with nothing but a file date to tell them apart. Deleted
# they are gone, and the log is the one artefact the whole exercise produces.
if [ -d "$OBS/verdicts" ] && [ -n "$(ls -A "$OBS/verdicts" 2>/dev/null)" ]; then
  previous="$OBS/verdicts-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$OBS/verdicts" "$previous"
  echo "moved the previous run's verdicts to $(basename "$previous")"
fi
mkdir -p "$OBS/verdicts"
mkdir -p "$LOG"
: > "$LOG/verdicts.jsonl"

# A --command pane closes when its command exits, so every value ends with an
# exec to leave a shell behind. No newlines are permitted in the value.
spawn() {                       # spawn <dir> <brief> <model>
  baia split --cwd "$1" --command \
    "'/bin/zsh' -lc 'claude --model $3 \"\$(cat $2)\"; exec \"\$SHELL\" -l'"
}

echo "spawning executors..."
for w in "${ITEMS[@]}"; do
  # The tier lives in the brief, so the wave definition stays in one directory.
  # Absent means Sonnet, which is what most moves want.
  model=$(sed -n 's/^<!-- model: *\([a-z0-9-]*\) *-->$/\1/p' "$OBS/briefs/$w.md" | head -1)
  spawn "$WT/baia--$w" "$OBS/briefs/$w.md" "${model:-claude-sonnet-5}"
done

echo
echo "panes now in scope:"
baia list --tree

# The launcher, written here because this is the only moment the answer exists:
# the pane that created the executors is the pane running this line, and after
# this script exits nothing else knows which one that was.
#
# **Printing the rule was not enough.** Runs 1, 2 and 3 all typed the observer
# command into the wrong pane, and all three were caught by `baia whoami` after
# the fact rather than by the instruction before it. An observer in a sibling
# pane does not fail: it sees exactly one pane, itself, and loops on an empty
# scope looking like it works. So the check moved to where the mistake is made.
cat > "$LOG/observe.sh" <<LAUNCHER
#!/usr/bin/env bash
# Launches the observer, and refuses from any pane but the one that spawned the
# executors. Written by run.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Do not edit.
set -euo pipefail

CREATOR=$BAIA_PANE
PROMPT=$LOG/orchestrator.md

here=\${BAIA_PANE:-}
if [ -z "\$here" ]; then
  echo "refusing: no \\\$BAIA_PANE, so this is not a baia pane at all." >&2
  exit 2
fi
if [ "\$here" != "\$CREATOR" ]; then
  echo "refusing: this is pane \$here." >&2
  echo "The executors were created by \$CREATOR, and scope is sibling-blind: a" >&2
  echo "pane sees itself, what it created, and its peers. From here the observer" >&2
  echo "would see one pane, itself, and loop on an empty scope looking like it" >&2
  echo "works. Run this from the pane that ran run.sh." >&2
  exit 2
fi
if [ ! -s "\$PROMPT" ]; then
  echo "refusing: \$PROMPT is missing or empty. Substitute the pane ids and the" >&2
  echo "starting seq into it first (step 3)." >&2
  exit 2
fi
# The other silent failure, and the reason step 3 is by hand: an unsubstituted
# placeholder binds no pane to any brief, and every verdict after it is about
# nothing while reading exactly like a working run.
if grep -qE '\\\$(PANE_ACTIVITY|PANE_CONTROL|PANE_LAYOUT|START_SEQ)' "\$PROMPT"; then
  echo "refusing: \$PROMPT still holds unsubstituted placeholders:" >&2
  grep -oE '\\\$(PANE_ACTIVITY|PANE_CONTROL|PANE_LAYOUT|START_SEQ)' "\$PROMPT" | sort -u >&2
  exit 2
fi
# And the failure the check above cannot see, which happened on 2026-08-01: a
# prompt left over from an earlier run holds no placeholders, because that run
# already replaced them, so it passes as substituted while binding panes that no
# longer exist. Asking the channel which panes are real is the only spelling of
# this question that a stale file cannot answer correctly.
python3 "$OBS/check-bindings.py" "\$PROMPT" || exit 2

exec claude --model claude-fable-5 "\$(cat "\$PROMPT")"
LAUNCHER
chmod +x "$LOG/observe.sh"

cat <<EOF

Next, by hand:
  1. Read the three pane ids:            baia list --json
  2. Note the starting seq:              baia list --json | grep seq
  3. Substitute the ids and the seq for \$PANE_ACTIVITY, \$PANE_CONTROL, \$PANE_LAYOUT and
     \$START_SEQ in $OBS/orchestrator.md, writing the result to
     $LOG/orchestrator.md
  4. Run the observer IN THIS PANE:

     $LOG/observe.sh

**The observer must be this pane, and that is not a preference.** Scope is
sibling-blind: baia --help says a pane sees itself, the panes it created, and its
peers, nothing else. This pane created the three executors, so this pane is the
only one that can read or subscribe to them. An observer opened as a fourth
split would be their sibling and would see exactly one pane: itself. It would
loop forever on an empty scope and look like it was working.

Found 2026-08-01 by nearly doing it. The earlier version of this message told you
to split for the observer.

$LOG/observe.sh enforces both of the failures this step has, rather than
describing them: it refuses from any pane but this one ($BAIA_PANE), and it
refuses a prompt still holding an unsubstituted placeholder. The substitution
stays by hand because the ids only exist after the splits; what does not stay by
hand is noticing that it was skipped.
EOF
