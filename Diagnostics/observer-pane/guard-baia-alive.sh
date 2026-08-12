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
# **`design-panel-key` is denied, and it is the member that could never
# qualify.** It was written for the design panel's `wantsKey` leak and evaluated
# against this list when it landed, so the answer is recorded here rather than
# left for the next reader to work out. Its subject *is* the key transition: it
# raises the flag, calls `makeKey()`, ends the editing session five different
# ways and asserts the flag came back down. An arm that avoided taking key would
# be measuring nothing at all, so there is no version of this probe that passes
# the focus criterion.
#
# Measured rather than argued: `makeKey()` on an `.accessory` app's nonactivating
# panel moves `NSApplication.isActive` from false to true and takes key, while
# leaving the frontmost application unchanged at the Dock level. Focus returns
# when the process exits, so the cost is bounded to the two seconds of a run and
# is milder than `fullscreen-strip`'s — but keystrokes typed during it land
# somewhere other than the pane, which is the thing this list exists to prevent.
# Run it from a second terminal. Its README carries the same reasoning.
#
# **`glass-backdrop` is allowed, and it is the first member that is not
# invisible.** Every other probe on this list opens no window at all or opens one
# nothing composites; `glass-backdrop` puts real windows on screen for about
# fifteen seconds, including a full-screen white/black backdrop it needs as a
# controlled thing for glass to sample. It qualifies on the criterion this list
# actually enforces, which is focus rather than invisibility: it is
# `.accessory`, every window is `orderFrontRegardless()`, and it contains no
# `makeKeyAndOrderFront`, no `activate`, and no `pkill`, so the keyboard never
# leaves the pane that launched it. It spawns a real shell for the grid arm and
# exits it.
#
# The distinction is worth stating rather than leaving to the reader, because a
# later probe that flashes windows *and* takes focus would look like this one
# from the outside. Focus is the line. A run of this one will visibly cover
# whatever is in front for a few seconds and then put it back.
#
# **`override-wires` is the strictest member.** It opens no window at all: every
# arm renders a shipped view into an offscreen `NSBitmapImageRep` through
# `cacheDisplay(in:to:)` and reads the bytes back, so there is nothing for the
# window server to composite and nothing to take focus from. It qualifies on the
# focus criterion by never reaching a compositor in the first place.
#
# **`cluster-wires` qualifies the way `override-wires` does: no window at
# all.** It is that probe's pattern applied to `PaneClusterView` — every arm
# renders the capsule into an offscreen `NSBitmapImageRep` through
# `cacheDisplay(in:to:)` and compares bytes, so nothing reaches the window
# server and there is nothing to take focus from. Its sibling
# `cluster-card-key` is the opposite case and stays denied: its subject is the
# cluster cards' key discipline, so like `design-panel-key` it takes the
# keyboard on purpose and no version of it could qualify.
#
# **`cluster-legibility` qualifies on the same ground as `cluster-wires`:**
# the same offscreen `cacheDisplay(in:to:)` harness pointed at a different
# question (contrast grading rather than wire reach), no window, no focus, no
# shell.
#
# **`footer-accessory` qualifies the way `glass-backdrop` does.** Four windows
# on screen for about twenty seconds, scrolling their own content for the
# scroll edge effect the probe compares; `.accessory` policy, every window
# `orderFrontRegardless()` with `canBecomeKey` overridden to false, no
# `activate`, no `pkill`, no shell spawned at all. The keyboard never leaves
# the pane that launched it.
#
# Every probe named must be safe, so a command pairing a safe one with a real
# driver is still denied.
SAFE_PROBES='^(cluster-legibility|theme-catalog|app-icon|clip-layout|theme-refresh|pane-resize|glass-backdrop|override-wires|cluster-wires|footer-accessory)$'
probes=$(printf '%s' "$COMMAND" | grep -oE 'Diagnostics/[a-zA-Z0-9_-]+/run\.sh' | sed -E 's|Diagnostics/([^/]+)/run\.sh|\1|')
if [ -n "$probes" ]; then
  unsafe=0
  while IFS= read -r probe; do
    printf '%s' "$probe" | grep -qE "$SAFE_PROBES" || unsafe=1
  done <<EOF
$probes
EOF
  if [ "$unsafe" = "1" ]; then
    emit_deny "Blocked: this Diagnostics probe takes over the screen. footer-corners and fullscreen-strip open a key window and activate, and fullscreen-strip runs an event loop driving it in and out of full screen, so either would pull focus off this pane mid-run. Others quit any running baia and launch their own. Use 'make test' for package work, or theme-catalog, app-icon, clip-layout, theme-refresh, pane-resize, glass-backdrop, override-wires and cluster-wires, which take no focus. (glass-backdrop does put windows on screen for about fifteen seconds; it never takes the keyboard.)"
  fi
fi

# `make run` was unblocked 2026-08-07 (owner's call). This line denied it from
# before the 2026-08-02 product split, when a second launch really could
# collide with the running app. Since the split, `make run` is a bare detached
# `open` of `baia-dev.app` (Makefile:162-163) with its own bundle id, support
# directory and socket; CLAUDE.md records the 2026-08-02 measurement of both
# copies running side by side, each on its own socket, neither disturbed. The
# stale form of this rule is the one CLAUDE.md warns stales in the direction
# that costs a session: an agent reading it defers every footer question to
# "needs a session outside a baia pane" while the fix is visible in the dev
# build. `make run-attached` stays denied for a different reason the split
# does not touch: it runs the build in the foreground of the calling pane, so
# the pane becomes its console and the agent in it loses its shell.
if has "${START}"'make[[:space:]]+run-attached([[:space:]]|$)'; then
  emit_deny "Blocked: make run-attached runs the build in the foreground of this pane, so the pane becomes its console and the shell here is lost. Use 'make run', which builds and launches baia-dev detached."
fi

if has "${START}"'osascript.*quit[[:space:]]+app[[:space:]]*"?baia'; then
  emit_deny "Blocked: quitting baia would end this run."
fi

# `baia\.app` deliberately narrow again, reversed 2026-08-07 alongside the
# `make run` unblock above. The 2026-08-02 widening to `baia(-dev)?\.app`
# closed a real hole in its day: back then a dev-bundle launch was the hazard
# this file existed to stop. Since the product split made `baia-dev.app` its
# own app (bundle id, support dir, socket), opening it is exactly what
# `make run` does and is allowed for the same reason. The installed
# `/Applications/baia.app` stays denied: it is the owner's daily driver, and
# `open` on a running app activates it, which pulls focus off every pane in
# it. Note `baia-dev.app` does not contain the substring `baia.app` (after
# `baia` comes `-`), so the narrow pattern cannot re-match the dev bundle;
# that non-containment is the same string fact the 2026-08-02 note recorded,
# now load-bearing in the opposite direction.
if has "${START}"'open[[:space:]]+[^;&|]*baia\.app'; then
  emit_deny "Blocked: opening the installed baia.app activates the daily driver and pulls focus off its panes. The dev build is fine: use 'make run' or open baia-dev.app."
fi

exit 0
