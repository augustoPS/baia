#!/usr/bin/python3
"""Split/close churn over the control socket with resource sampling.

Each round splits the anchor pane, waits for the new pane's shell to report its
token, closes the new pane through its own token, and waits for the layout to
return to one pane. Descriptors, resident memory and descendant processes are
sampled from outside the process before, during and after settling.

The claim is bounded: after the churn settles, the owned descriptor set and the
descendant process set are back within a small margin of the baseline. Memory
is reported, not asserted, because an allocator's steady state is not a leak.
"""

import glob
import json
import os
import socket
import subprocess
import sys
import time

SOCKET, TOKEN_DIR, PID, ALPHA, EVIDENCE, ROUNDS = sys.argv[1:7]
PID = int(PID)
ROUNDS = int(ROUNDS)
CONNECT_TIMEOUT = 5.0
SETTLE = 15.0

failures = []
checks = 0


def check(name, condition, detail=""):
    global checks
    checks += 1
    if condition:
        print("ok    " + name)
    else:
        failures.append(name)
        print("FAIL  " + name + (": " + detail if detail else ""))


def request(token, verb, args=None):
    frame = json.dumps({"v": 1, "token": token, "verb": verb, "args": args or {}}) + "\n"
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(CONNECT_TIMEOUT)
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


def pane_ids(token):
    """The pane ids the `list` verb reports for the requesting pane's window."""
    response = request(token, "list")
    if "result" not in response:
        return None
    records = (response.get("result") or {}).get("panes") or []
    return sorted(record.get("pane") for record in records if isinstance(record, dict))


def await_panes(token, count):
    deadline = time.time() + SETTLE
    while time.time() < deadline:
        ids = pane_ids(token)
        if ids is not None and len(ids) == count:
            return ids
        time.sleep(0.1)
    return pane_ids(token)


def descendants(pid):
    out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in out.split("\n"):
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, frontier = [], [pid]
    while frontier:
        parent = frontier.pop()
        for child in children.get(parent, []):
            found.append(child)
            frontier.append(child)
    return sorted(found)


def sample(label):
    fds = subprocess.run(["lsof", "-p", str(PID)], capture_output=True, text=True).stdout
    lines = fds.strip().split("\n")[1:]
    fd_count = len(lines)
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(PID)], capture_output=True, text=True).stdout.strip()
    record = {"label": label, "fds": fd_count, "rss_kb": int(rss or 0), "descendants": descendants(PID),
              "lsof": lines}
    print("sample %-10s fds=%d rss=%dKB descendants=%d" % (label, fd_count, record["rss_kb"], len(record["descendants"])))
    return record


def settle_baseline(label):
    """Two samples 1.5 s apart that agree on descriptors, so a still-starting
    shell is not mistaken for the baseline."""
    deadline = time.time() + SETTLE
    previous = None
    while time.time() < deadline:
        current = sample(label)
        if previous and previous["fds"] == current["fds"] and previous["descendants"] == current["descendants"]:
            return current
        previous = current
        time.sleep(1.5)
    return previous


samples = []
alpha = None
deadline = time.time() + SETTLE
while time.time() < deadline and not alpha:
    alpha = tokens().get(ALPHA)
    time.sleep(0.2)
check("anchor pane reported its token", bool(alpha))
if not alpha:
    sys.exit(1)
check("anchor pane answers whoami", request(alpha, "whoami").get("ok") is True)
check("one pane before the churn", await_panes(alpha, 1) == [ALPHA])

baseline = settle_baseline("baseline")
samples.append(baseline)

closed_children = []
for round_number in range(1, ROUNDS + 1):
    known = set(tokens())
    response = request(alpha, "split", {})
    if response.get("ok") is not True:
        check("round %d split accepted" % round_number, False, json.dumps(response)[:200])
        break
    ids = await_panes(alpha, 2)
    new = [identifier for identifier in (ids or []) if identifier != ALPHA]
    if len(new) != 1:
        check("round %d layout shows the new pane" % round_number, False, str(ids))
        break
    new_id = new[0]
    token = None
    wait_until = time.time() + SETTLE
    while time.time() < wait_until and not token:
        token = tokens().get(new_id)
        time.sleep(0.1)
    if not token:
        check("round %d new pane reported its token" % round_number, False, new_id)
        break
    mid = descendants(PID)
    response = request(token, "close", {})
    if response.get("ok") is not True:
        check("round %d close accepted" % round_number, False, json.dumps(response)[:200])
        break
    if await_panes(alpha, 1) != [ALPHA]:
        check("round %d layout back to one pane" % round_number, False, str(pane_ids(alpha)))
        break
    closed_children.append(sorted(set(mid) - set(baseline["descendants"])))
    if round_number % 6 == 0:
        samples.append(sample("round %d" % round_number))
else:
    check("all %d rounds completed" % ROUNDS, True)

final = settle_baseline("settled")
samples.append(final)

# The bound is on growth with churn, not on the first split: the first pane
# opened after launch pays one-time costs (lazily created queues, the first
# surface's resources), so the plateau is the samples from the first
# mid-churn sample on. Descriptors must stay within four of that plateau's
# low point, and descendants must return to the baseline set.
plateau = [s for s in samples if s["label"].startswith("round")] + [final]
low = min(s["fds"] for s in plateau)
high = max(s["fds"] for s in plateau)
check("descriptors do not grow across the churn (plateau %d..%d)" % (low, high), high - low <= 4)
check("descriptors after settling stay within 4 of the plateau low (%d vs %d)" % (final["fds"], low),
      abs(final["fds"] - low) <= 4)
stray = sorted(set(final["descendants"]) - set(baseline["descendants"]))
check("no descendant survives the churn", not stray, str(stray))
step = final["fds"] - baseline["fds"]
def kinds(lines):
    out = {}
    for line in lines:
        parts = line.split()
        if len(parts) >= 5:
            out[parts[4]] = out.get(parts[4], 0) + 1
    return out
before, after = kinds(baseline["lsof"]), kinds(final["lsof"])
changed = {k: after.get(k, 0) - before.get(k, 0) for k in set(before) | set(after) if after.get(k, 0) != before.get(k, 0)}
print("info  descriptor step from cold baseline to settled: %+d by type %s (reported, not asserted)" % (step, changed))
rss_delta = final["rss_kb"] - baseline["rss_kb"]
print("info  resident memory delta after settling: %+d KB (reported, not asserted)" % rss_delta)
print("info  each round's closed pane spawned %s descendants" %
      sorted({len(children) for children in closed_children}))

with open(os.path.join(EVIDENCE, "resource-soak-report.json"), "w") as handle:
    json.dump({"pid": PID, "rounds": ROUNDS, "samples": samples, "failures": failures, "checks": checks},
              handle, indent=1)
print("%d checks, %d failures" % (checks, len(failures)))
sys.exit(1 if failures else 0)
