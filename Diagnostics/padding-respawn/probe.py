#!/usr/bin/python3
"""Live padding and material edits: does an open pane keep its shell?

Q02 asks what a padding or material edit does to panes that already exist.
The pane's shell and everything under it are the observable: their pids are
recorded before each edit and compared after it. A pane that was respawned
would have a new shell pid; a pane that was reconfigured in place keeps it.
After the edits a new pane is split off over the socket to show the app is
still live and still spawning.
"""

import glob
import json
import os
import socket
import subprocess
import sys
import time

SOCKET, TOKEN_DIR, PID, ALPHA, EVIDENCE, CONFIG = sys.argv[1:7]
PID = int(PID)
failures = []


def check(name, condition, detail=""):
    if condition:
        print("ok    " + name)
    else:
        failures.append(name)
        print("FAIL  " + name + (": " + detail if detail else ""))


def request(token, verb, args=None):
    frame = json.dumps({"v": 1, "token": token, "verb": verb, "args": args or {}}) + "\n"
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(5.0)
    received = b""
    try:
        connection.connect(SOCKET)
        connection.sendall(frame.encode())
        while b"\n" not in received:
            chunk = connection.recv(65536)
            if not chunk:
                break
            received += chunk
    except (BrokenPipeError, ConnectionResetError, socket.timeout):
        pass
    finally:
        connection.close()
    try:
        return json.loads(received)
    except ValueError:
        return {"parseFailure": received.decode("utf-8", "replace")}


def tokens():
    found = {}
    for path in sorted(glob.glob(os.path.join(TOKEN_DIR, "pane-*.env"))):
        with open(path) as handle:
            fields = dict(line.split("=", 1) for line in handle.read().split("\n") if "=" in line)
        if fields.get("pane") and fields.get("token"):
            found[fields["pane"]] = fields["token"]
    return found


def descendants():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    children = {}
    names = {}
    for line in out.split("\n"):
        parts = line.split(None, 2)
        if len(parts) == 3:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
            names[int(parts[0])] = os.path.basename(parts[2])
    found, frontier = {}, [PID]
    while frontier:
        parent = frontier.pop()
        for child in children.get(parent, []):
            found[child] = names.get(child, "?")
            frontier.append(child)
    return found


def write_config(**changes):
    with open(CONFIG) as handle:
        document = json.load(handle)
    document.update(changes)
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(document, handle)
    os.replace(tmp, CONFIG)


def pane_count(token):
    response = request(token, "list")
    records = (response.get("result") or {}).get("panes") or []
    return len(records)


alpha = None
deadline = time.time() + 15
while time.time() < deadline and not alpha:
    alpha = tokens().get(ALPHA)
    time.sleep(0.2)
check("anchor pane reported its token", bool(alpha))
if not alpha:
    sys.exit(1)
time.sleep(1.5)
before = descendants()
print("info  descendants before edits: %s" % sorted(before.items()))
check("the pane has a shell below the app", "zsh" in before.values() or "login" in before.values(), str(before))

steps = [
    ("windowPadding 8 -> 24", {"windowPadding": 24}),
    ("chromeStyle liquidGlass -> solid", {"chromeStyle": "solid"}),
    ("chromeStyle solid -> liquidGlass", {"chromeStyle": "liquidGlass"}),
    ("windowPadding 24 -> 8", {"windowPadding": 8}),
]
for label, changes in steps:
    write_config(**changes)
    time.sleep(3.0)
    after = descendants()
    check("%s kept the pane's processes" % label, after == before,
          "before %s after %s" % (sorted(before.items()), sorted(after.items())))
    check("%s left the app answering" % label, request(alpha, "whoami").get("ok") is True)

count_before = pane_count(alpha)
response = request(alpha, "split", {})
check("a new pane still opens after the edits", response.get("ok") is True, json.dumps(response)[:160])
deadline = time.time() + 15
while time.time() < deadline and pane_count(alpha) != count_before + 1:
    time.sleep(0.2)
check("the new pane is listed", pane_count(alpha) == count_before + 1)
deadline = time.time() + 15
while time.time() < deadline and len(descendants()) <= len(before):
    time.sleep(0.2)
grown = descendants()
check("the new pane spawned its own shell", len(grown) > len(before), str(sorted(grown.items())))
check("the original pane's processes survived the split", all(pid in grown for pid in before), str(sorted(grown.items())))

with open(os.path.join(EVIDENCE, "padding-respawn-report.json"), "w") as handle:
    json.dump({"pid": PID, "before": before, "after_split": grown, "failures": failures}, handle, indent=1)
print("%d failures" % len(failures))
sys.exit(1 if failures else 0)
