#!/usr/bin/python3
"""Seed a window with N panes, then time `focus` round trips across them.

`seed` writes a v1 session with a balanced split tree of N leaves. `measure`
cycles focus through every pane's own token and records each round trip as the
app's main thread sees it: the response is written after the focus has been
applied, so the latency includes whatever a focus change reconfigures.
`compare` reads the per-count reports and states whether the median moved with
the pane count.
"""

import glob
import json
import os
import socket
import statistics
import sys
import time

CONNECT_TIMEOUT = 5.0


def pane_id(index):
    return "BA1AC0DE-0000-4000-8000-%012X" % (index + 1)


def tree(ids, depth=0):
    if len(ids) == 1:
        return {"leaf": {"_0": {"rawValue": ids[0]}}}
    half = len(ids) // 2
    return {"split": {"axis": "horizontal" if depth % 2 == 0 else "vertical", "ratio": 0.5,
                      "first": tree(ids[:half], depth + 1), "second": tree(ids[half:], depth + 1)}}


def seed(session_path, root, count):
    ids = [pane_id(i) for i in range(count)]
    document = {
        "panes": [{"id": {"rawValue": i}, "workingDirectory": root} for i in ids],
        "schemaVersion": 1,
        "workspace": {"tabs": [{"id": "BA1AC0DE-0000-4000-8000-0000000000AA",
                                "focusedPane": {"rawValue": ids[0]}, "tree": tree(ids)}],
                      "focusedTabIndex": 0},
        "windowFrame": {"x": 80, "y": 80, "width": 1400, "height": 900},
    }
    with open(session_path, "w") as handle:
        json.dump(document, handle)


def request(sock, token, verb, args=None):
    frame = json.dumps({"v": 1, "token": token, "verb": verb, "args": args or {}}) + "\n"
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(CONNECT_TIMEOUT)
    received = b""
    try:
        connection.connect(sock)
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


def tokens(token_dir):
    found = {}
    for path in sorted(glob.glob(os.path.join(token_dir, "pane-*.env"))):
        with open(path) as handle:
            fields = dict(line.split("=", 1) for line in handle.read().split("\n") if "=" in line)
        if fields.get("pane") and fields.get("token"):
            found[fields["pane"]] = fields["token"]
    return found


def measure(sock, token_dir, count, report_path, moves):
    ids = [pane_id(i) for i in range(count)]
    deadline = time.time() + 20
    live = {}
    while time.time() < deadline and any(i not in live for i in ids):
        live = tokens(token_dir)
        time.sleep(0.2)
    missing = [i for i in ids if i not in live]
    if missing:
        print("FAIL %d panes did not report a token: %s" % (len(missing), missing[:3]))
        return 1
    # A warm-up so the first focus after launch does not sit in the sample.
    for i in ids:
        request(sock, live[i], "focus")
    latencies = []
    refused = 0
    for move in range(moves):
        target = ids[(move + 1) % count]
        started = time.perf_counter()
        response = request(sock, live[target], "focus")
        elapsed = (time.perf_counter() - started) * 1000
        if response.get("ok") is True:
            latencies.append(elapsed)
        else:
            refused += 1
            if refused == 1:
                print("info  first refusal: %s" % json.dumps(response)[:160])
    if not latencies:
        print("FAIL no focus request succeeded (%d refused)" % refused)
        return 1
    latencies.sort()
    report = {
        "panes": count, "moves": moves, "refused": refused,
        "median_ms": statistics.median(latencies),
        "p95_ms": latencies[int(len(latencies) * 0.95) - 1],
        "max_ms": latencies[-1],
    }
    with open(report_path, "w") as handle:
        json.dump(report, handle, indent=1)
    print("panes=%d moves=%d refused=%d median=%.2fms p95=%.2fms max=%.2fms" % (
        count, moves, refused, report["median_ms"], report["p95_ms"], report["max_ms"]))
    if refused:
        print("FAIL %d focus requests were refused" % refused)
        return 1
    return 0


def compare(evidence, counts):
    reports = []
    for count in counts:
        path = os.path.join(evidence, "panes-%s-report.json" % count)
        if not os.path.exists(path):
            print("FAIL no report for %s panes" % count)
            return 1
        with open(path) as handle:
            reports.append(json.load(handle))
    smallest, largest = reports[0], reports[-1]
    ratio = largest["median_ms"] / max(smallest["median_ms"], 0.01)
    print("median focus latency: %d panes %.2f ms, %d panes %.2f ms (ratio %.2f); p95 %.2f -> %.2f ms" % (
        smallest["panes"], smallest["median_ms"], largest["panes"], largest["median_ms"], ratio,
        smallest["p95_ms"], largest["p95_ms"]))
    # The claim under test is that a focus move reconfigures two panes, not
    # every pane. Six times the panes must not cost anything like six times the
    # latency; a factor of two leaves room for layout work that does scale.
    if ratio > 2.0:
        print("FAIL median focus latency grew %.2fx from %d to %d panes" % (ratio, smallest["panes"], largest["panes"]))
        return 1
    print("ok    median focus latency does not scale with pane count")
    return 0


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "seed":
        seed(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif command == "measure":
        sys.exit(measure(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], int(sys.argv[6])))
    elif command == "compare":
        sys.exit(compare(sys.argv[2], [int(c) for c in sys.argv[3:]]))
    else:
        sys.exit(2)
