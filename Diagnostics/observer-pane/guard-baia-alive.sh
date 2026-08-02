#!/usr/bin/env bash
# PreToolUse(Bash) guard for observer-pane executors.
# Refuses any command that would kill the baia hosting the run.
# Exit 2 = deny. Exit 0 = allow.
#
# An executor works on baia from inside baia. Every route below ends the
# orchestrator, all three executors, and the measurement, and each one looks
# like ordinary work from inside the worktree.
set -uo pipefail

emit_deny() {
  local reason="${1//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  # Also on stderr: the harness reads stderr rather than the stdout JSON when a
  # PreToolUse hook exits non-zero. Keeping exit 2 means a malformed JSON line
  # can never soften this into an allow.
  printf '%s\n' "$reason" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || emit_deny "jq is required by the observer-pane guard and is not installed."

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$COMMAND" ] && exit 0

# Where a command can begin: the start of the line, after a shell separator, or
# behind an `rtk` prefix.
#
# **The rtk arm is not defensive padding.** The `rtk hook claude` PreToolUse hook
# rewrites commands before the permission check, so the executors' allowlist
# carries `Bash(rtk:*)` to stop every rewritten verb prompting, and `rtk proxy`
# runs its argument raw with no filtering. Measured 2026-08-01: `pkill -x baia`
# was denied here and `rtk proxy pkill -x baia` was allowed, which is the whole
# deny list bypassed by a nine-character prefix.
#
# The allowlist now denies `Bash(rtk proxy:*)` as well, and this is the backstop
# rather than the fix: a hook that only holds while the settings file is right is
# not a guard, and the settings file is the thing most likely to be edited by
# whoever is in a hurry.
START='(^|[;&|()]+[[:space:]]*)(rtk[[:space:]]+(proxy[[:space:]]+)?)?'

has() { printf '%s' "$COMMAND" | grep -qE "$1"; }

if has "${START}"'pkill([[:space:]]+-[a-zA-Z]+)*[[:space:]]+baia'; then
  emit_deny "Blocked: pkill baia would kill the app hosting this pane, the orchestrator, and every sibling executor."
fi

if has 'Diagnostics/[a-zA-Z0-9_-]+/run\.sh'; then
  emit_deny "Blocked: a Diagnostics probe quits any running baia and launches its own. It would end this run. Use 'make test' to verify package work."
fi

if has "${START}"'make[[:space:]]+run([[:space:]]|$)' \
   || has "${START}"'make[[:space:]]+run-attached([[:space:]]|$)'; then
  emit_deny "Blocked: make run launches a second baia, and 'open' may resolve to the installed copy through LaunchServices. Verify with 'make test'."
fi

if has "${START}"'osascript.*quit[[:space:]]+app[[:space:]]*"?baia'; then
  emit_deny "Blocked: quitting baia would end this run."
fi

# `baia(-dev)?\.app` rather than `baia\.app`, because the Debug product was
# renamed on 2026-08-02 so an installed copy and a build under test can run at
# once. `baia-dev.app` does not contain the substring `baia.app`, so the narrower
# pattern stopped matching the only bundle an executor is ever near: the one in
# `.build/Build/Products/Debug`. The rename passed every existing check and
# silently opened the hole, which is the second time a pattern in this file has
# been outlived by the string it matches.
if has "${START}"'open[[:space:]]+[^;&|]*baia(-dev)?\.app'; then
  emit_deny "Blocked: opening a baia bundle launches a second instance. Verify with 'make test'."
fi

exit 0
