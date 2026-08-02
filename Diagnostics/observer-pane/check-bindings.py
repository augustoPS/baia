#!/usr/bin/env python3
"""Refuses an observer prompt whose bindings are not this wave's.

    check-bindings.py <prompt.md>

Exits 0 when every pane id the prompt names is a pane the caller can currently
see, and 2 otherwise, with the reason on stderr.

**The failure this closes happened.** On 2026-08-01 a wave spawned and the
substitution step was skipped, leaving the previous run's prompt in place. That
file holds no placeholders, because a run hours earlier had already replaced them
with real ids, so the launcher's placeholder check passed on it. An observer
launched from there binds three panes that no longer exist, subscribes to a scope
none of them are in, and produces nothing while looking exactly like a run that
works.

A placeholder check answers "was this ever substituted". This answers "was it
substituted for the panes that exist now", which is the question.

Spoken to the socket directly rather than through the `baia` CLI: the CLI is on
the caller's PATH from the running bundle and this has to work before anything
else in the launcher does. A file of its own rather than a heredoc inside the
launcher, because the launcher is itself written by a heredoc in `run.sh`, and
`path-picker` already recorded that nesting python inside that is one level too
many and collides on the terminator.
"""

import json
import os
import re
import socket
import sys

CONNECT_TIMEOUT = 5
UUID = re.compile(
    r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"
)


def visible_panes() -> set[str] | None:
    """Every pane id `list` answers with, or None when the channel cannot be asked."""
    token = os.environ.get("BAIA_TOKEN")
    sock_path = os.environ.get("BAIA_SOCK")
    if not token or not sock_path:
        return None

    frame = json.dumps({"v": 1, "token": token, "verb": "list", "args": {}}) + "\n"
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(CONNECT_TIMEOUT)
        connection.connect(sock_path)
        connection.sendall(frame.encode())
        buffered = b""
        while b"\n" not in buffered:
            chunk = connection.recv(65536)
            if not chunk:
                break
            buffered += chunk
        connection.close()
        answer = json.loads(buffered.split(b"\n")[0].decode())
    except (OSError, ValueError):
        return None

    if not answer.get("ok"):
        return None
    records = (answer.get("result") or {}).get("panes") or []
    return {record["pane"] for record in records if record.get("pane")}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-bindings.py <prompt.md>", file=sys.stderr)
        return 2

    try:
        prompt = open(sys.argv[1], encoding="utf-8").read()
    except OSError as error:
        print("refusing: cannot read the prompt: %s" % error, file=sys.stderr)
        return 2

    bound = {match.upper() for match in UUID.findall(prompt)}
    if not bound:
        print("refusing: the prompt names no pane id at all, so nothing is bound.",
              file=sys.stderr)
        return 2

    visible = visible_panes()
    if visible is None:
        # Refused rather than waved through. A check that passes when it cannot
        # run is the shape of the placeholder check this exists to repair.
        print("refusing: could not ask the channel which panes exist. Run this from "
              "inside a baia pane, where $BAIA_SOCK and $BAIA_TOKEN are set.",
              file=sys.stderr)
        return 2

    stale = sorted(bound - {pane.upper() for pane in visible})
    if stale:
        print("refusing: the prompt binds %d pane(s) this pane cannot see:"
              % len(stale), file=sys.stderr)
        for pane in stale:
            print("  " + pane, file=sys.stderr)
        print("That is a prompt left over from an earlier run. It holds no "
              "placeholders, because an earlier run already replaced them, so the "
              "placeholder check cannot catch it. Redo the substitution step "
              "against the panes that exist now.", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
