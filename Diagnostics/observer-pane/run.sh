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

# The running app must be the dev build. The pane's baia CLI comes from the
# *running* app's bundle, so an installed copy makes the whole toolchain lie
# consistently: split --command reads as missing rather than as stale.
running=$(ps -o command= -p "$(pgrep -x baia | head -1)" 2>/dev/null || true)
case "$running" in
  "$REPO"/.build/*) ;;
  *) echo "running baia is not the dev build: $running" >&2
     echo "relaunch with: $REPO/.build/Build/Products/Debug/baia.app/Contents/MacOS/baia &" >&2
     exit 2 ;;
esac

for w in tree-expansions utf8-filenames app-target-rules; do
  [ -d "$WT/baia--$w" ] || { echo "missing worktree: $WT/baia--$w" >&2; exit 2; }
done

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

cat <<EOF

Next, by hand:
  1. Read the three pane ids:            baia list --json | jq -r '.panes[].id'
  2. Note the starting seq:              baia list --json | jq -r '.seq'
  3. Substitute the ids and the seq for \$PANE_TREE, \$PANE_UTF8, \$PANE_RULES and
     \$START_SEQ in $OBS/orchestrator.md, writing the result to
     $LOG/orchestrator.md
  4. Spawn the observer:

     baia split --cwd $REPO --command \\
       "'/bin/zsh' -lc 'claude --model claude-fable-5 \"\\\$(cat $LOG/orchestrator.md)\"; exec \"\\\$SHELL\" -l'"

The substitution is by hand on purpose: the ids only exist after the splits, and
a wrong binding is the one failure that makes every verdict meaningless while
looking exactly like a working run.
EOF
