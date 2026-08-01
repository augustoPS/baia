#!/usr/bin/env bash
# Spawns three executor panes from the pane that runs this, then prints the
# by-hand steps for the observer.
#
# Run this from inside a baia pane. It needs $BAIA_SOCK and $BAIA_TOKEN, which
# only a pane has: the token is the capability the channel authenticates on and
# it is never on disk and never in argv.
set -euo pipefail

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

for w in tree-expansions utf8-filenames app-target-rules; do
  [ -d "$WT/baia--$w" ] || { echo "missing worktree: $WT/baia--$w" >&2; exit 2; }
done

# Surface 1, closed 2026-08-01: pre-accept the workspace-trust dialog for each
# worktree. Without this every executor halts before its first tool call, and the
# acceptance does not survive a killed session.
"$OBS/trust-worktrees.sh" \
  "$WT/baia--tree-expansions" "$WT/baia--utf8-filenames" "$WT/baia--app-target-rules"

# Surfaces 2 and 4, closed 2026-08-01: the executors' allowlist and guard hook.
# Seeded rather than assumed present. The settings existed for run 2 and were
# hand-written and untracked, so they lived in three directories that get deleted
# and remade, and a fresh worktree met both surfaces again.
"$OBS/seed-worktree-settings.sh" \
  "$WT/baia--tree-expansions" "$WT/baia--utf8-filenames" "$WT/baia--app-target-rules"

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
spawn "$WT/baia--tree-expansions"  "$OBS/briefs/tree-expansions.md"  claude-sonnet-5
spawn "$WT/baia--utf8-filenames"   "$OBS/briefs/utf8-filenames.md"   claude-opus-5
spawn "$WT/baia--app-target-rules" "$OBS/briefs/app-target-rules.md" claude-sonnet-5

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
if grep -qE '\\\$(PANE_TREE|PANE_UTF8|PANE_RULES|START_SEQ)' "\$PROMPT"; then
  echo "refusing: \$PROMPT still holds unsubstituted placeholders:" >&2
  grep -oE '\\\$(PANE_TREE|PANE_UTF8|PANE_RULES|START_SEQ)' "\$PROMPT" | sort -u >&2
  exit 2
fi

exec claude --model claude-fable-5 "\$(cat "\$PROMPT")"
LAUNCHER
chmod +x "$LOG/observe.sh"

cat <<EOF

Next, by hand:
  1. Read the three pane ids:            baia list --json
  2. Note the starting seq:              baia list --json | grep seq
  3. Substitute the ids and the seq for \$PANE_TREE, \$PANE_UTF8, \$PANE_RULES and
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
