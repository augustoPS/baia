#!/usr/bin/env python3
"""Prints the focused pane's last line, read over the control channel.

    read-prompt.py <socket> <readout-directory>

Spoken over the socket directly rather than through `nc`. The control-channel
probe records why, and it is a real trap rather than a preference: `nc` closes
the whole socket when its stdin ends, so a shell pipeline that writes one frame
and closes hangs up before the answer arrives. It reads as an unparseable
response, which looks like a protocol fault and is not one.

A file of its own rather than a heredoc inside `run.sh`, because a heredoc
holding python inside a script that is itself generated is one nesting level too
many, and the terminator collided the first time.

The capability is read from the pane's own readout: `run.sh` has the shell write
`$BAIA_TOKEN` and `$BAIA_PANE` into the output directory as it starts. That is a
readout rather than a forgery, since a token is minted per pane per run and
written nowhere else. `read` is `.descendant` and resolves `subject == actor`,
which is what lets a pane read itself.

Every failure prints a parenthesised reason rather than raising, so the caller's
comparison shows what went wrong instead of an empty string.
"""

import json
import socket
import sys

CONNECT_TIMEOUT = 5


def main():
    if len(sys.argv) != 3:
        print("(usage: read-prompt.py <socket> <readout>)")
        return 0

    sock_path, readout = sys.argv[1], sys.argv[2]

    try:
        token = open(readout + "/pane.token").read().strip()
        pane = open(readout + "/pane.id").read().strip()
    except OSError:
        print("(no capability)")
        return 0
    if not token or not pane:
        print("(no capability)")
        return 0

    frame = json.dumps({
        "v": 1,
        "token": token,
        "verb": "read",
        "args": {"peer": pane, "lines": 1},
    }) + "\n"

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
    except OSError as error:
        print("(socket: %s)" % error)
        return 0

    try:
        answer = json.loads(buffered.split(b"\n")[0].decode())
    except Exception:
        print("(unparseable: %r)" % buffered[:120])
        return 0

    if not answer.get("ok"):
        print("(refused: %s)" % (answer.get("error") or {}).get("code"))
        return 0

    lines = (answer.get("result") or {}).get("lines") or []
    print(lines[-1] if lines else "(empty)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
