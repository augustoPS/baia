#!/bin/sh
#
# Tells the baia pane this session is running in what the agent is doing.
#
# Installed by `baia install-hooks`, which prepends the managed header naming the
# version. Every rule below has a failure behind it, and four of them were paid
# for by herdr's integration before baia had one.
#
# **Fails closed and silent, on every path.** A hook attached to an agent's
# session must never be the reason that session breaks, so every guard is
# `|| exit 0` and nothing here ever writes to stdout or stderr. A non-zero exit
# from a PreToolUse hook blocks the tool call.
set -eu

# No channel, no pane, or no tool to reach them with. All three are normal: this
# file survives a baia that is not running and a shell outside baia entirely.
[ -n "${BAIA_SOCK:-}" ] || exit 0
[ -n "${BAIA_PANE:-}" ] || exit 0
command -v baia > /dev/null 2>&1 || exit 0
command -v python3 > /dev/null 2>&1 || exit 0

payload=$(cat) || exit 0
[ -n "$payload" ] || exit 0

# The whole decision, in one place, so the shell below has nothing to interpret.
#
#   PreToolUse  AskUserQuestion  blocked   waiting on a human
#   PreToolUse  anything else    working
#   PostToolUse AskUserQuestion  working   the human answered
#   Stop                         idle      the turn ended
#   SessionEnd                   release   authority back to the pollers
#
# `Stop` is how `idle` gets a producer at all. A resident agent's process never
# exits, so the process-tree poller reports it running forever and nothing else
# can tell a finished agent from a working one.
#
# **`SubagentStop` is absent on purpose.** It is a completion event, and Claude
# recap or away-summary can emit it after the main turn has already stopped, so
# mapping it to anything would let it revive an idle pane. Printing nothing here
# means the script reports nothing and exits.
#
# **A payload carrying `agent_id` is dropped.** That is a subagent, and a
# subagent's lifecycle is not the pane's.
state=$(printf '%s' "$payload" | python3 -c '
import json, sys

try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

if not isinstance(payload, dict) or payload.get("agent_id"):
    raise SystemExit(0)

event = payload.get("hook_event_name") or ""
tool = payload.get("tool_name") or ""

if event == "PreToolUse":
    print("blocked" if tool == "AskUserQuestion" else "working")
elif event == "PostToolUse":
    print("working")
elif event == "Stop":
    print("idle")
elif event == "SessionEnd":
    print("release")
' 2> /dev/null) || exit 0

[ -n "$state" ] || exit 0

if [ "$state" = "release" ]; then
    baia report --release > /dev/null 2>&1 || exit 0
    exit 0
fi

# **The sequence comes from a clock, not a counter.** `ReportStore` keeps
# ordering across a release and across an expiry, so a counter restarted with the
# session would be superseded for the rest of the run and every report after the
# first would be silently ignored.
seq=$(python3 -c 'import time; print(int(time.time() * 1000))' 2> /dev/null) || exit 0
[ -n "$seq" ] || exit 0

baia report --state "$state" --seq "$seq" > /dev/null 2>&1 || exit 0
exit 0
