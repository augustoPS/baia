#!/usr/bin/env bash
# Surfaces 2 and 4: writes the executor settings into each worktree.
#
# Usage: seed-worktree-settings.sh [--profile executor|reviewer] <dir> [<dir> ...]
#
# **Two profiles, because the two jobs are opposite shapes.** An executor writes
# code and commits it, so it may `git add` and `git commit` and must never need
# `git checkout --`. A reviewer verifies by mutation: it breaks the thing a claim
# protects, runs the suite, and reverts, so `git checkout --` is its most frequent
# command and committing is the one thing it must never do. Seeding a reviewer
# with the executor profile prompts on every single revert and leaves the ban on
# committing in prose, where nothing enforces it.
#
# Found 2026-08-02, on the first review pass run this way: the agent was seeded
# executor and prompted through `git checkout --`, `swiftc`, `make upstream`,
# `python3`, `md5` and `diff`, none of which an executor has ever needed.
#
# **The settings existed and were not reproducible**, which is why runs 2 and 3
# met the same two surfaces the notes said were understood. Each worktree's
# `.claude/settings.json` was written by hand mid-run and is untracked, so it
# lives in exactly one place: a directory that gets deleted and remade. A fresh
# worktree has none, and an executor in it prompts on every rewritten command and
# every read outside its own tree.
#
# `executor-settings.json` beside this script is the tracked original. Two
# absolute paths cannot be tracked, since neither exists until someone checks the
# repository out somewhere, so `__REPO__` stands in for both and is substituted
# here.
#
# **Surface 2, rtk.** `rtk hook claude` rewrites the command before the permission
# check, so `Bash(cat:*)` never authorises `rtk read` and every rewritten verb
# prompts. Answered with `Bash(rtk:*)`, which opens a hole of its own:
# `rtk proxy <cmd>` runs its argument raw, so `rtk proxy pkill -x baia` was
# allowed on 2026-08-01 while the bare form was denied. Answered here with
# `Bash(rtk proxy:*)` in the deny list and, because a guard that depends on a
# settings file being right is not a guard, again in `guard-baia-alive.sh`.
#
# **Surface 4, out-of-worktree reads.** The briefs quote paths that resolve
# against the main repository, so the first read of a named file leaves the
# workspace and prompts. Answered with a `Read()` rule for the repository rather
# than by rewriting the briefs: the paths are what makes a brief specific, and an
# executor that may read the repository it is working on is not a widening worth
# the loss.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

PROFILE=executor
if [ "${1:-}" = "--profile" ]; then
  [ "$#" -ge 2 ] || { echo "--profile needs a value" >&2; exit 2; }
  PROFILE=$2
  shift 2
fi
case "$PROFILE" in
  executor|reviewer) ;;
  *) echo "unknown profile: $PROFILE (executor or reviewer)" >&2; exit 2 ;;
esac
TEMPLATE="$HERE/$PROFILE-settings.json"

[ "$#" -gt 0 ] || {
  echo "usage: $0 [--profile executor|reviewer] <dir> [<dir> ...]" >&2
  exit 2
}
[ -f "$TEMPLATE" ] || { echo "no $TEMPLATE" >&2; exit 2; }

for raw in "$@"; do
  dir=$(cd "$raw" 2>/dev/null && pwd) || { echo "missing worktree: $raw" >&2; exit 2; }
  target="$dir/.claude/settings.json"
  mkdir -p "$dir/.claude"
  # Backed up rather than overwritten silently, the same contract
  # trust-worktrees.sh keeps against ~/.claude.json. A worktree can outlive a run
  # and carry settings someone added for another reason.
  [ -f "$target" ] && cp "$target" "$target.bak-observer"
  sed "s|__REPO__|$REPO|g" "$TEMPLATE" > "$target"
  # Refused rather than reported, because an unsubstituted placeholder makes the
  # guard hook's command a path that does not exist. A PreToolUse hook that
  # cannot run is a deny list that is not there, and nothing would say so.
  if grep -q '__REPO__' "$target"; then
    echo "refusing: $target still holds __REPO__ after substitution" >&2
    exit 2
  fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$target" \
    || { echo "refusing: $target is not valid JSON" >&2; exit 2; }
  echo "  seeded $target ($PROFILE)"
done
