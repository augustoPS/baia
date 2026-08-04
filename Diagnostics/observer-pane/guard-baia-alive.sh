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

# Five probes launch nothing, quit nothing and take no focus, so the reason this
# block gives does not apply to them. `theme-catalog` builds a binary and sweeps
# the shipped themes; `app-icon` reads plists and compares files. `clip-layout`,
# `theme-refresh` and `pane-resize` each build an `NSWindow` and measure it, but
# every one of them sets an `.accessory` or `.prohibited` activation policy
# first, so the window never reaches the Dock, never becomes key, and never takes
# focus from the pane that started it.
#
# Carved out rather than left blanket, because the blanket cost something
# measurable: the wave-five reviewer needed the theme-catalog sweep, could not run
# it, and hand-transcribed its `swiftc` lines into one Bash call instead. That
# call carries a shell function, and a brace holding a quote reads to Claude
# Code's own analyser as expansion obfuscation, which no allow rule can
# pre-approve. A guard wider than its reason routes work into shapes nothing can
# authorise.
#
# It cost something a second time on 2026-08-03. Six of the seven probes that
# compile a package were found dead, none of them by a `make` target, because a
# hand-written link line goes stale when a file moves between packages and no
# build compiles a probe. The blanket is part of why they stayed dead: the five
# named in this block could not be run from the pane where the work happens, and
# an unrunnable probe is one nobody notices has stopped building. The list was
# widened only after reading each probe's source, not on the strength of that
# argument.
#
# **`footer-corners` and `fullscreen-strip` stay denied, and for a reason this
# block did not previously state.** Neither quits baia either, so the message
# below is wrong about them too, but both call `makeKeyAndOrderFront` and
# `activate`, and `fullscreen-strip` additionally runs a real event loop and
# drives its window into full screen and back twice. They steal focus from the
# pane that launched them, which is disruption of a different kind than the one
# named here rather than an absence of it.
#
# Every probe named must be safe, so a command pairing a safe one with a real
# driver is still denied.
SAFE_PROBES='^(theme-catalog|app-icon|clip-layout|theme-refresh|pane-resize)$'
probes=$(printf '%s' "$COMMAND" | grep -oE 'Diagnostics/[a-zA-Z0-9_-]+/run\.sh' | sed -E 's|Diagnostics/([^/]+)/run\.sh|\1|')
if [ -n "$probes" ]; then
  unsafe=0
  while IFS= read -r probe; do
    printf '%s' "$probe" | grep -qE "$SAFE_PROBES" || unsafe=1
  done <<EOF
$probes
EOF
  if [ "$unsafe" = "1" ]; then
    emit_deny "Blocked: this Diagnostics probe takes over the screen. footer-corners and fullscreen-strip open a key window and activate, and fullscreen-strip runs an event loop driving it in and out of full screen, so either would pull focus off this pane mid-run. Others quit any running baia and launch their own. Use 'make test' for package work, or theme-catalog, app-icon, clip-layout, theme-refresh and pane-resize, which take no focus."
  fi
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
