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

has() { printf '%s' "$COMMAND" | grep -qE "$1"; }

if has '(^|[;&|()]+[[:space:]]*)pkill([[:space:]]+-[a-zA-Z]+)*[[:space:]]+baia'; then
  emit_deny "Blocked: pkill baia would kill the app hosting this pane, the orchestrator, and every sibling executor."
fi

if has 'Diagnostics/[a-zA-Z0-9_-]+/run\.sh'; then
  emit_deny "Blocked: a Diagnostics probe quits any running baia and launches its own. It would end this run. Use 'make test' to verify package work."
fi

if has '(^|[;&|()]+[[:space:]]*)make[[:space:]]+run([[:space:]]|$)' \
   || has '(^|[;&|()]+[[:space:]]*)make[[:space:]]+run-attached([[:space:]]|$)'; then
  emit_deny "Blocked: make run launches a second baia, and 'open' may resolve to the installed copy through LaunchServices. Verify with 'make test'."
fi

if has 'osascript.*quit[[:space:]]+app[[:space:]]*"?baia'; then
  emit_deny "Blocked: quitting baia would end this run."
fi

if has '(^|[;&|()]+[[:space:]]*)open[[:space:]]+[^;&|]*baia\.app'; then
  emit_deny "Blocked: opening baia.app launches a second instance. Verify with 'make test'."
fi

exit 0
