#!/usr/bin/python3
"""Resource churn over the control socket with descriptor, child and latency census.

Two workloads, both driven from outside the process through `AF_UNIX` bytes:

* **split/close** (`--rounds`): each round splits the anchor pane, waits for the
  new pane's shell to report its token, closes the new pane through its own
  token, and waits for the layout to return to one pane.
* **subscription churn** (`--subscribe-batches`): each batch parks eight
  `subscribe --wait` clients, two per scratch pane across four seeded scratch
  panes (below the per-pane quota of four connections), confirms all eight are
  parked, times a request served while they are parked, then ends the batch by
  closing every client. Odd batches disconnect before the wait elapses; even
  batches let the server's deadline answer them first. A census of open
  descriptors, resident memory and descendant processes is taken after a warm-up,
  every ten batches, and after the churn settles. After settling, a fresh
  subscription must still be woken by the next real event with an advanced
  sequence, and a live failure control must be rejected by the same grader:
  eight deliberately retained sockets, then a known owned leftover child.

The claim is bounded: after the churn settles, the descriptor count is within a
small tolerance of the warmed baseline with no sustained per-batch growth, and
the descendant set is the baseline's. Memory is reported, not asserted, because
an allocator's steady state is not a leak.

Importing this module has no side effects. `main()` sits behind the entry-point
guard so `test_probe.py` can drive the seed builder and the graders on
synthetic samples without a socket, a token directory or an app.
"""

import argparse
import glob
import json
import os
import select
import signal
import socket
import subprocess
import sys
import time

CONNECT_TIMEOUT = 5.0
SETTLE = 15.0

# The pass criterion's numbers, named once so the README and the tests can
# point at them.
DESCRIPTOR_TOLERANCE = 4
LATENCY_LIMIT = 2.0

# Eight concurrent parked clients over four scratch panes, two each. The server
# caps one pane at four connections (`ControlWire.maxConnectionsPerPane`) and
# the pool at sixteen (`ControlWire.maxConnections`), so nothing here is evicted
# to make room; an early answer is therefore a defect to report, never a client
# to count as parked.
SUBSCRIBE_CLIENTS_PER_PANE = 2
SUBSCRIBE_WAIT_CAP = 5
SUBSCRIBE_CENSUS_EVERY = 10
SUBSCRIBE_WARMUP_BATCHES = 2
SUBSCRIBE_KINDS = ["paneOpened"]
# Mid-churn split/close samples land every six rounds. Fewer rounds never
# produce a plateau, so that path is warmup and does not grade growth.
SPLIT_CLOSE_CENSUS_EVERY = 6

# The session this probe seeds. `SessionSnapshot.currentSchemaVersion` is 2 at
# this revision; seeding the current schema keeps a first-launch migration out
# of the churn samples.
SESSION_SCHEMA = 2
ALPHA = "BA1AC0DE-0000-4000-8000-000000000001"
SCRATCH = [
    "BA1AC0DE-0000-4000-8000-000000000011",
    "BA1AC0DE-0000-4000-8000-000000000012",
    "BA1AC0DE-0000-4000-8000-000000000013",
    "BA1AC0DE-0000-4000-8000-000000000014",
]
TAB = "BA1AC0DE-0000-4000-8000-0000000000AA"
GROUP = "BA1AC0DE-0000-4000-8000-0000000000BB"
WINDOW_FRAME = {"x": 120, "y": 120, "width": 1000, "height": 640}


# MARK: seeding


def leaf(pane):
    return {"leaf": {"_0": {"rawValue": pane}}}


def tree(panes):
    """A right-leaning chain of horizontal splits holding `panes` in order."""
    if len(panes) == 1:
        return leaf(panes[0])
    return {
        "split": {
            "axis": "horizontal",
            "ratio": round(1.0 / len(panes), 6),
            "first": leaf(panes[0]),
            "second": tree(panes[1:]),
        }
    }


def seed_document(root, scratch):
    """A schema-2 session: one group, one tab, the anchor plus `scratch` panes."""
    panes = [ALPHA] + list(scratch)
    return {
        "schemaVersion": SESSION_SCHEMA,
        "groups": [
            {
                "id": GROUP,
                "tabs": [{"id": TAB, "focusedPane": {"rawValue": ALPHA}, "tree": tree(panes)}],
                "selectedTab": TAB,
                "frame": dict(WINDOW_FRAME),
            }
        ],
        "activeGroup": GROUP,
        "panes": [{"id": {"rawValue": pane}, "workingDirectory": str(root)} for pane in panes],
    }


def write_seed(path, root, scratch_count):
    scratch = SCRATCH[:scratch_count]
    document = seed_document(root, scratch)
    with open(path, "w") as handle:
        json.dump(document, handle, indent=1)
        handle.write("\n")
    return document


# MARK: graders (pure)


def descriptor_types(lines):
    """lsof lines by their TYPE column, so a census can say what grew."""
    out = {}
    for line in lines:
        parts = line.split()
        if len(parts) >= 5 and parts[3][0].isdigit():
            out[parts[4]] = out.get(parts[4], 0) + 1
    return out


def census_agrees(previous, current):
    """Two samples agree only when numeric FDs, unix FDs, and descendants match.

    Total FD count can stay flat while unix sockets are still closing and REG
    rows move the other way; requiring unix as well keeps that from freezing
    as a settled plateau.
    """
    return (
        previous["fds"] == current["fds"]
        and previous["descendants"] == current["descendants"]
        and previous.get("types", {}).get("unix") == current.get("types", {}).get("unix")
    )


def grade_census(warm, plateau, settled, tolerance=DESCRIPTOR_TOLERANCE):
    """Grades one census against the warmed baseline.

    `warm` is the settled baseline taken after warm-up, `plateau` the mid-churn
    samples in order, `settled` the sample after the churn settled. Every sample
    carries `fds` and `descendants`. Returns `[(name, ok, detail)]`; nothing here
    prints or exits, so a test can feed it synthetic samples.
    """
    results = []
    counts = [warm["fds"]] + [sample["fds"] for sample in plateau] + [settled["fds"]]
    low, high = min(counts), max(counts)
    results.append((
        "descriptors stay within %d across the churn (%d..%d)" % (tolerance, low, high),
        high - low <= tolerance,
        "range %d" % (high - low),
    ))
    step = settled["fds"] - warm["fds"]
    results.append((
        "descriptors after settling stay within %d of the warm baseline (%d vs %d)"
        % (tolerance, settled["fds"], warm["fds"]),
        abs(step) <= tolerance,
        "step %+d" % step,
    ))
    # Sustained growth is a rise between the first and second half of the
    # churn, not a single noisy sample: a leak of one descriptor per batch
    # separates the halves by far more than half the tolerance, while a flat
    # series with jitter keeps the two means together.
    series = [sample["fds"] for sample in plateau] + [settled["fds"]]
    if len(series) >= 4:
        half = len(series) // 2
        first = sum(series[:half]) / float(half)
        second = sum(series[-half:]) / float(half)
        rise = second - first
        results.append((
            "no sustained per-batch descriptor growth (first half %.1f, second half %.1f)"
            % (first, second),
            rise <= tolerance / 2.0,
            "rise %.1f" % rise,
        ))
    else:
        results.append((
            "no sustained per-batch descriptor growth (too few samples for a trend; the range check stands)",
            True,
            "",
        ))
    stray = sorted(set(settled["descendants"]) - set(warm["descendants"]))
    lost = sorted(set(warm["descendants"]) - set(settled["descendants"]))
    results.append(("no descendant remains beyond the warm baseline", not stray, str(stray)))
    results.append(("no baseline descendant was lost", not lost, str(lost)))
    if any(sample.get("stable") is False for sample in [warm] + plateau + [settled]):
        results.append(("every graded census reached a stable sample", False, "settle deadline expired"))
    return results


def failed_names(results):
    return [name for name, ok, _ in results if not ok]


def grade_batches(batches, wait, clients):
    """Grades the per-batch records the churn wrote.

    Every batch must have parked all `clients` with none answered early, and
    every timeout batch must have had all of them answered by the deadline with
    an empty batch: an early answer is an eviction or an unexpected event, and
    neither is a client that was concurrently parked.
    """
    results = []
    short = [b["batch"] for b in batches if b["parked"] != clients]
    results.append((
        "every batch parked %d subscriptions" % clients, not short, "short batches %s" % short,
    ))
    early = [b["batch"] for b in batches if b["early"]]
    results.append((
        "no parked subscription was answered before its batch ended", not early,
        "early answers in batches %s" % early,
    ))
    timeouts = [b for b in batches if b["mode"] == "timeout"]
    unanswered = [b["batch"] for b in timeouts
                  if b.get("answered") != clients or b.get("empty") != clients]
    results.append((
        "every timeout batch was answered by the deadline with an empty batch",
        not unanswered, "batches %s" % unanswered,
    ))
    late = [b["batch"] for b in timeouts if b.get("slowest", 0) > wait + CONNECT_TIMEOUT]
    results.append((
        "no timeout answer arrived later than the wait plus %.0fs" % CONNECT_TIMEOUT,
        not late, "batches %s" % late,
    ))
    refused = [b["batch"] for b in batches if b.get("served") is not True]
    results.append(("every request succeeds while subscriptions are parked",
                    not refused, "failed requests in batches %s" % refused))
    disconnects = [b for b in batches if b["mode"] == "disconnect"]
    results.append((
        "the churn alternated disconnect and timeout batches",
        bool(timeouts) and bool(disconnects) and abs(len(timeouts) - len(disconnects)) <= 1,
        "%d disconnect, %d timeout" % (len(disconnects), len(timeouts)),
    ))
    return results


def grade_latencies(latencies, limit=LATENCY_LIMIT):
    slowest = max(latencies) if latencies else 0.0
    return [(
        "every request is served under %.0fs while the subscriptions are parked (slowest %.2fs)"
        % (limit, slowest),
        bool(latencies) and slowest < limit,
        "%d timed requests" % len(latencies),
    )]


def grade_postchurn(cursor, woken, born):
    """Grades the fresh subscription parked after the churn.

    It must be woken by the split it was waiting for, name that pane, and
    report a sequence past the cursor it was parked at.
    """
    result = woken.get("result") or {}
    events = result.get("events") if isinstance(result.get("events"), list) else []
    seen = [(event.get("kind"), event.get("pane")) for event in events]
    seq = result.get("seq")
    return [
        (
            "a fresh subscription after the churn is woken by the next real event",
            woken.get("ok") is True and seen == [("paneOpened", born)],
            json.dumps(seen)[:200],
        ),
        (
            "and its sequence advanced past the cursor it was parked at",
            isinstance(seq, int) and isinstance(cursor, int) and seq > cursor,
            "cursor %r seq %r" % (cursor, seq),
        ),
    ]


# MARK: the wire


def request(socket_path, token, verb, args=None):
    frame = json.dumps({"v": 1, "token": token, "verb": verb, "args": args or {}}) + "\n"
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(CONNECT_TIMEOUT)
    received = b""
    try:
        connection.connect(socket_path)
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


def park_subscribe(socket_path, token, cursor, kinds, seconds):
    """Sends `subscribe --wait` and returns the connection still holding it.

    Mirrors `Probe.park_subscribe` in `Diagnostics/control-channel/probe.py`
    rather than importing it across diagnostics. The caller closes it.
    """
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(CONNECT_TIMEOUT)
    connection.connect(socket_path)
    frame = json.dumps({
        "v": 1, "token": token, "verb": "subscribe",
        "args": {"from": cursor, "kinds": kinds, "wait": seconds},
    }) + "\n"
    connection.sendall(frame.encode())
    return connection


def answered(connection, limit):
    """The line a parked long poll is eventually woken with, within `limit`."""
    connection.settimeout(limit)
    received = b""
    try:
        while b"\n" not in received:
            chunk = connection.recv(65536)
            if not chunk:
                break
            received += chunk
    except (socket.timeout, ConnectionResetError):
        pass
    try:
        return json.loads(received)
    except ValueError:
        return {"parseFailure": received.decode("utf-8", "replace")}


def readable(connections, seconds):
    """The connections with something to read within `seconds`: an answer or EOF."""
    if not connections:
        return []
    ready, _, _ = select.select(connections, [], [], seconds)
    return ready


def sequence(response):
    return (response.get("result") or {}).get("seq")


# MARK: the process from outside


def process_table():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    table = {}
    for line in out.split("\n"):
        parts = line.split(None, 2)
        if len(parts) >= 2:
            table[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) == 3 else "")
    return table


def descendants(pid, table=None):
    table = table if table is not None else process_table()
    children = {}
    for child, (parent, _) in table.items():
        children.setdefault(parent, []).append(child)
    found, frontier = [], [pid]
    while frontier:
        parent = frontier.pop()
        for child in children.get(parent, []):
            found.append(child)
            frontier.append(child)
    return sorted(found)


class Soak:
    def __init__(self, socket_path, token_dir, pid, evidence, scratch_dir):
        self.socket_path = socket_path
        self.token_dir = token_dir
        self.pid = pid
        self.evidence = evidence
        self.scratch_dir = scratch_dir
        self.failures = []
        self.checks = 0
        self.samples = []
        self.report = {}
        self.census_observations = []

    def check(self, name, condition, detail=""):
        self.checks += 1
        if condition:
            print("ok    " + name)
        else:
            self.failures.append(name)
            print("FAIL  " + name + (": " + detail if detail else ""))
        return bool(condition)

    def grade(self, results):
        for name, ok, detail in results:
            self.check(name, ok, detail)
        return failed_names(results)

    def request(self, token, verb, args=None):
        return request(self.socket_path, token, verb, args)

    def timed(self, token, verb):
        started = time.time()
        response = self.request(token, verb)
        return response, time.time() - started

    def tokens(self):
        found = {}
        for path in sorted(glob.glob(os.path.join(self.token_dir, "pane-*.env"))):
            with open(path) as handle:
                fields = dict(line.split("=", 1) for line in handle.read().split("\n") if "=" in line)
            if fields.get("pane") and fields.get("token"):
                found[fields["pane"]] = fields["token"]
        return found

    def await_token(self, pane, limit=SETTLE):
        deadline = time.time() + limit
        while time.time() < deadline:
            token = self.tokens().get(pane)
            if token:
                return token
            time.sleep(0.1)
        return None

    def pane_ids(self, token):
        """The pane ids the `list` verb reports for the requesting pane's scope."""
        response = self.request(token, "list")
        if "result" not in response:
            return None
        records = (response.get("result") or {}).get("panes") or []
        return sorted(record.get("pane") for record in records if isinstance(record, dict))

    def await_panes(self, token, count):
        deadline = time.time() + SETTLE
        while time.time() < deadline:
            ids = self.pane_ids(token)
            if ids is not None and len(ids) == count:
                return ids
            time.sleep(0.1)
        return self.pane_ids(token)

    def arm(self, name):
        with open(os.path.join(self.scratch_dir, "arm-" + name), "w"):
            pass

    def disarm(self, name):
        path = os.path.join(self.scratch_dir, "arm-" + name)
        if os.path.exists(path):
            os.remove(path)

    def sample(self, label, extra=None):
        fds = subprocess.run(["lsof", "-p", str(self.pid)], capture_output=True, text=True).stdout
        lines = fds.strip().split("\n")[1:]
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(self.pid)], capture_output=True, text=True).stdout.strip()
        table = process_table()
        found = descendants(self.pid, table)
        record = {
            "label": label, "fds": sum(descriptor_types(lines).values()), "mapped_and_open_rows": len(lines), "rss_kb": int(rss or 0), "descendants": found,
            "commands": {str(pid): table[pid][1] for pid in found if pid in table},
            "types": descriptor_types(lines), "lsof": lines,
        }
        if extra:
            record.update(extra)
        print("sample %-18s fds=%d rss=%dKB descendants=%d unix=%d"
              % (label, record["fds"], record["rss_kb"], len(found), record["types"].get("unix", 0)))
        self.census_observations.append(record)
        return record

    def settle_baseline(self, label):
        """Two samples 1.5 s apart that agree on numeric FDs, unix FDs, and
        descendants, so a still-starting shell or a closing socket is not
        mistaken for the baseline."""
        deadline = time.time() + SETTLE
        previous = None
        while time.time() < deadline:
            current = self.sample(label)
            if previous and census_agrees(previous, current):
                current["stable"] = True
                return current
            previous = current
            time.sleep(1.5)
        previous["stable"] = False
        return previous

    # MARK: split/close

    def split_close(self, alpha, rounds):
        baseline = self.settle_baseline("baseline")
        samples = [baseline]
        closed_children = []
        for round_number in range(1, rounds + 1):
            response = self.request(alpha, "split", {})
            if response.get("ok") is not True:
                self.check("round %d split accepted" % round_number, False, json.dumps(response)[:200])
                break
            ids = self.await_panes(alpha, 2)
            new = [identifier for identifier in (ids or []) if identifier != ALPHA]
            if len(new) != 1:
                self.check("round %d layout shows the new pane" % round_number, False, str(ids))
                break
            token = self.await_token(new[0])
            if not token:
                self.check("round %d new pane reported its token" % round_number, False, new[0])
                break
            mid = descendants(self.pid)
            response = self.request(token, "close", {})
            if response.get("ok") is not True:
                self.check("round %d close accepted" % round_number, False, json.dumps(response)[:200])
                break
            if self.await_panes(alpha, 1) != [ALPHA]:
                self.check("round %d layout back to one pane" % round_number, False, str(self.pane_ids(alpha)))
                break
            closed_children.append(sorted(set(mid) - set(baseline["descendants"])))
            if round_number % SPLIT_CLOSE_CENSUS_EVERY == 0:
                samples.append(self.sample("round %d" % round_number))
        else:
            self.check("all %d rounds completed" % rounds, True)

        final = self.settle_baseline("settled")
        samples.append(final)

        # The bound is on growth with churn, not on the first split: the first
        # pane opened after launch pays one-time costs (lazily created queues, the
        # first surface's resources), so the plateau is the samples from the first
        # mid-churn sample on. Descriptors must stay within four of that plateau's
        # low point, and descendants must return to the baseline set. Fewer than
        # SPLIT_CLOSE_CENSUS_EVERY rounds never take a mid-churn sample, so the
        # plateau would be a single settled point and the range/low checks
        # identities; that path is warmup, not a soak.
        if rounds >= SPLIT_CLOSE_CENSUS_EVERY:
            plateau = [s for s in samples if s["label"].startswith("round")] + [final]
            low = min(s["fds"] for s in plateau)
            high = max(s["fds"] for s in plateau)
            self.check("descriptors do not grow across the churn (plateau %d..%d)" % (low, high),
                       high - low <= DESCRIPTOR_TOLERANCE)
            self.check("descriptors after settling stay within 4 of the plateau low (%d vs %d)" % (final["fds"], low),
                       abs(final["fds"] - low) <= DESCRIPTOR_TOLERANCE)
        else:
            print("info  split/close warmup (%d round%s): plateau growth checks skipped"
                  % (rounds, "" if rounds == 1 else "s"))
        stray = sorted(set(final["descendants"]) - set(baseline["descendants"]))
        self.check("no descendant survives the churn", not stray, str(stray))
        step = final["fds"] - baseline["fds"]
        before, after = baseline["types"], final["types"]
        changed = {k: after.get(k, 0) - before.get(k, 0) for k in set(before) | set(after)
                   if after.get(k, 0) != before.get(k, 0)}
        print("info  descriptor step from cold baseline to settled: %+d by type %s (reported, not asserted)" % (step, changed))
        print("info  resident memory delta after settling: %+d KB (reported, not asserted)"
              % (final["rss_kb"] - baseline["rss_kb"]))
        print("info  each round's closed pane spawned %s descendants" %
              sorted({len(children) for children in closed_children}))
        self.samples.extend(samples)
        entry = {"rounds": rounds, "samples": samples}
        if rounds < SPLIT_CLOSE_CENSUS_EVERY:
            entry["warmup"] = True
            self.report["splitCloseWarmup"] = entry
        else:
            self.report["splitClose"] = entry

    # MARK: subscription churn

    def park_batch(self, tokens, wait, parked):
        """Parks two subscriptions per scratch pane from the current ring head.

        Appends into the caller's `parked` list rather than returning one, so a
        connect that fails halfway leaves the sockets already opened where the
        caller's `finally` can close them.
        """
        cursor = sequence(self.request(tokens[ALPHA], "list"))
        for pane in SCRATCH:
            for _ in range(SUBSCRIBE_CLIENTS_PER_PANE):
                parked.append(park_subscribe(self.socket_path, tokens[pane], cursor, SUBSCRIBE_KINDS, wait))
        return cursor

    def run_batch(self, number, mode, tokens, wait):
        """One batch: park, confirm parked, time a request, then end it by `mode`."""
        started = time.time()
        record = {"batch": number, "mode": mode, "parked": 0, "early": [], "latency": None}
        parked = []
        try:
            try:
                cursor = self.park_batch(tokens, wait, parked)
            except OSError as error:
                record["parked"] = len(parked)
                record["error"] = "%s: %s" % (type(error).__name__, error)
                return record
            record["parked"] = len(parked)
            record["cursor"] = cursor
            record["park_seconds"] = round(time.time() - started, 3)
            # A client the server has parked has nothing to read. One that was
            # evicted, refused or woken has an answer or an EOF waiting, and is
            # not a concurrently parked client whatever the count says.
            record["early"] = [parked.index(c) for c in readable(parked, 0.3)]
            served, latency = self.timed(tokens[ALPHA], "whoami")
            record["latency"] = round(latency, 4)
            record["served"] = served.get("ok") is True
            if mode == "timeout":
                elapsed = []
                answers = []
                for connection in parked:
                    response = answered(connection, wait + CONNECT_TIMEOUT)
                    elapsed.append(time.time() - started)
                    answers.append(response)
                record["answered"] = sum(1 for r in answers if r.get("ok") is True)
                record["empty"] = sum(1 for r in answers
                                      if r.get("ok") is True and (r.get("result") or {}).get("events") == [])
                record["slowest"] = round(max(elapsed), 3)
                record["fastest"] = round(min(elapsed), 3)
                # Answered ahead of the deadline is an eviction or a stray event,
                # which the grader treats exactly as an early answer.
                record["early"] += [i for i, seconds in enumerate(elapsed)
                                    if seconds < wait - 0.5 and i not in record["early"]]
                if answers and any(r.get("ok") is not True for r in answers):
                    record["firstRefusal"] = json.dumps(next(r for r in answers if r.get("ok") is not True))[:200]
        finally:
            for connection in parked:
                connection.close()
        record["seconds"] = round(time.time() - started, 3)
        return record

    def subscribe_churn(self, tokens, batches, wait):
        clients = SUBSCRIBE_CLIENTS_PER_PANE * len(SCRATCH)
        print("-- subscription churn: %d batches of %d parked subscriptions, %ds wait, alternating disconnect/timeout"
              % (batches, clients, wait))
        for pane in SCRATCH:
            self.check("scratch pane %s answers whoami" % pane[-2:],
                       self.request(tokens[pane], "whoami").get("ok") is True)

        # Pay the first dynamic surface/Metal cache cost before taking the
        # subscription baseline, unless a full split/close soak already ran.
        # A completed N-round soak paid that cost and owns report["splitClose"];
        # a one-round warmup must not overwrite it.
        if "splitClose" not in self.report:
            self.split_close(tokens[ALPHA], 1)
        warmup = []
        for number in range(1, SUBSCRIBE_WARMUP_BATCHES + 1):
            warmup.append(self.run_batch(-number, "disconnect" if number % 2 else "timeout", tokens, wait))
        self.check("warm-up batches parked every client", all(b["parked"] == clients and not b["early"] for b in warmup),
                   json.dumps(warmup)[:300])
        warm = self.settle_baseline("warm")
        records, plateau, latencies = [], [], []
        for number in range(1, batches + 1):
            mode = "disconnect" if number % 2 else "timeout"
            record = self.run_batch(number, mode, tokens, wait)
            records.append(record)
            if record["latency"] is not None:
                latencies.append(record["latency"])
            if record["parked"] != clients or record["early"]:
                self.check("batch %d parked %d clients with no early answer" % (number, clients), False,
                           json.dumps(record)[:300])
                break
            if number % SUBSCRIBE_CENSUS_EVERY == 0:
                window = latencies[-SUBSCRIBE_CENSUS_EVERY:]
                census = self.settle_baseline("batch %d" % number)
                census["latency"] = {"max": max(window), "min": min(window),
                                     "mean": round(sum(window) / len(window), 4)}
                plateau.append(census)
        else:
            self.check("all %d subscription batches completed" % batches, True)
        settled = self.settle_baseline("settled")

        print("-- subscription census")
        self.grade(grade_batches(records, wait, clients))
        self.grade(grade_latencies(latencies))
        self.grade(grade_census(warm, plateau, settled))
        before, after = warm["types"], settled["types"]
        changed = {k: after.get(k, 0) - before.get(k, 0) for k in set(before) | set(after)
                   if after.get(k, 0) != before.get(k, 0)}
        print("info  descriptor step from warm baseline to settled: %+d by type %s (reported, not asserted)"
              % (settled["fds"] - warm["fds"], changed))
        print("info  resident memory delta after settling: %+d KB (reported, not asserted)"
              % (settled["rss_kb"] - warm["rss_kb"]))
        if latencies:
            ordered = sorted(latencies)
            print("info  served-while-parked latency: min %.3fs median %.3fs max %.3fs over %d batches"
                  % (ordered[0], ordered[len(ordered) // 2], ordered[-1], len(ordered)))

        print("-- a fresh subscription after the churn")
        event = self.postchurn_event(tokens)

        print("-- live failure controls")
        control = self.control_arm(tokens, warm, wait)

        self.samples.extend([warm] + plateau + [settled])
        self.report["subscribe"] = {
            "batches": batches, "wait": wait, "clientsPerBatch": clients,
            "warmup": warmup, "records": records, "latencies": latencies,
            "warm": warm, "plateau": plateau, "settled": settled,
            "postchurn": event, "control": control,
        }

    def postchurn_event(self, tokens):
        alpha = tokens[ALPHA]
        cursor = sequence(self.request(alpha, "list"))
        waiting = park_subscribe(self.socket_path, alpha, cursor, SUBSCRIBE_KINDS, SUBSCRIBE_WAIT_CAP)
        born, woken, token = None, {}, None
        try:
            self.check("the post-churn subscription is parked rather than answered at once",
                       not readable([waiting], 0.3))
            born = (self.request(alpha, "split", {}).get("result") or {}).get("pane")
            woken = answered(waiting, SUBSCRIBE_WAIT_CAP + CONNECT_TIMEOUT)
        finally:
            waiting.close()
        self.grade(grade_postchurn(cursor, woken, born))
        if born:
            token = self.await_token(born)
            if token:
                self.request(token, "close", {})
        self.check("and the pane it announced is closed again", self.await_panes(alpha, 1) == [ALPHA])
        return {"cursor": cursor, "born": born, "woken": woken}

    def control_arm(self, tokens, warm, wait):
        """Two censuses the grader must reject, then one it must accept.

        First eight retained sockets with no other change, so the rejection is
        on descriptors alone and the descendant checks still pass. Then a pane
        whose shell holds a known child, so the rejection names a descendant.
        Both are cleaned and the settled census must pass again.
        """
        clients = SUBSCRIBE_CLIENTS_PER_PANE * len(SCRATCH)
        outcome = {}
        retained = []
        try:
            self.park_batch(tokens, SUBSCRIBE_WAIT_CAP, retained)
            self.check("control: %d sockets are retained and parked" % clients,
                       len(retained) == clients and not readable(retained, 0.3))
            census = self.sample("control-retained")
            verdict = grade_census(warm, [], census)
            failed = failed_names(verdict)
            outcome["retainedSockets"] = {"census": census, "failed": failed}
            self.check("control: the grader rejects the retained-socket census on descriptors",
                       any(name.startswith("descriptors after settling") for name in failed), str(failed))
            self.check("control: and the retained descriptors are unix sockets",
                       census["types"].get("unix", 0) - warm["types"].get("unix", 0) >= clients,
                       "unix %d vs %d" % (census["types"].get("unix", 0), warm["types"].get("unix", 0)))
            self.check("control: the retained-socket census passes the descendant checks",
                       not any(name.startswith("no descendant") or name.startswith("no baseline") for name in failed),
                       str(failed))
        finally:
            for connection in retained:
                connection.close()

        alpha = tokens[ALPHA]
        self.arm("linger")
        born, token, sleeper = None, None, None
        try:
            born = (self.request(alpha, "split", {}).get("result") or {}).get("pane")
            token = self.await_token(born) if born else None
            deadline = time.time() + SETTLE
            while time.time() < deadline and sleeper is None:
                table = process_table()
                for pid in descendants(self.pid, table):
                    if pid not in warm["descendants"] and table.get(pid, ("", ""))[1].endswith("sleep"):
                        sleeper = pid
                        break
                time.sleep(0.2)
        finally:
            self.disarm("linger")
        self.check("control: the linger pane spawned a known child", sleeper is not None, str(born))
        census = self.sample("control-leftover-child")
        verdict = grade_census(warm, [], census)
        failed = failed_names(verdict)
        outcome["leftoverChild"] = {"pane": born, "sleeper": sleeper, "census": census, "failed": failed}
        self.check("control: the grader rejects the census on the known leftover child",
                   "no descendant remains beyond the warm baseline" in failed
                   and sleeper in census["descendants"], str(failed))

        if token:
            self.request(token, "close", {})
        self.check("control: the linger pane is closed again", self.await_panes(alpha, 1) == [ALPHA])
        cleaned = self.settle_baseline("control-cleaned")
        reaped = sleeper is not None and sleeper not in cleaned["descendants"]
        outcome["cleanup"] = {"reapedByClose": reaped}
        if sleeper is not None and not reaped:
            table = process_table()
            still = table.get(sleeper)
            if still and still[1].endswith("sleep") and sleeper in descendants(self.pid, table):
                os.kill(sleeper, signal.SIGTERM)
                outcome["cleanup"]["signalled"] = sleeper
                cleaned = self.settle_baseline("control-cleaned")
        self.check("control: closing the linger pane reaped its child", reaped, "pid %s" % sleeper)
        verdict = grade_census(warm, [], cleaned)
        outcome["cleanup"]["census"] = cleaned
        outcome["cleanup"]["failed"] = failed_names(verdict)
        self.check("control: the grader accepts the census after cleanup", not failed_names(verdict),
                   str(failed_names(verdict)))
        return outcome

    # MARK: run

    def run(self, rounds, batches, wait):
        alpha = None
        deadline = time.time() + SETTLE
        while time.time() < deadline and not alpha:
            alpha = self.tokens().get(ALPHA)
            time.sleep(0.2)
        self.check("anchor pane reported its token", bool(alpha))
        if not alpha:
            return self.finish(rounds, batches, wait)
        self.check("anchor pane answers whoami", self.request(alpha, "whoami").get("ok") is True)
        self.check("one pane in the anchor's scope before the churn", self.await_panes(alpha, 1) == [ALPHA])

        if rounds > 0:
            self.split_close(alpha, rounds)

        if batches > 0:
            tokens = {}
            for pane in [ALPHA] + SCRATCH:
                tokens[pane] = self.await_token(pane)
            missing = [pane for pane, token in tokens.items() if not token]
            if self.check("every scratch pane reported its token", not missing, str(missing)):
                self.subscribe_churn(tokens, batches, wait)
        return self.finish(rounds, batches, wait)

    def finish(self, rounds, batches, wait):
        self.report.update({
            "pid": self.pid, "rounds": rounds, "subscribeBatches": batches, "subscribeWait": wait,
            "samples": self.samples, "censusObservations": self.census_observations,
            "failures": self.failures, "checks": self.checks,
        })
        with open(os.path.join(self.evidence, "resource-soak-report.json"), "w") as handle:
            json.dump(self.report, handle, indent=1)
        print("%d checks, %d failures" % (self.checks, len(self.failures)))
        return 1 if self.failures else 0


def clamp_wait(seconds):
    return max(1, min(int(seconds), SUBSCRIBE_WAIT_CAP))


def parser():
    top = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = top.add_subparsers(dest="command")
    seed = sub.add_parser("seed", help="write a schema-%d session for the fixture" % SESSION_SCHEMA)
    seed.add_argument("--session", required=True)
    seed.add_argument("--root", required=True)
    seed.add_argument("--scratch", type=int, default=0, choices=range(0, len(SCRATCH) + 1))
    run = sub.add_parser("run", help="drive the workloads against a live isolated copy")
    run.add_argument("socket")
    run.add_argument("token_dir")
    run.add_argument("pid", type=int)
    run.add_argument("evidence")
    run.add_argument("--scratch-dir", required=True, help="where the .zshrc arms are planted")
    run.add_argument("--rounds", type=int, default=0)
    run.add_argument("--subscribe-batches", type=int, default=0)
    run.add_argument("--subscribe-wait", type=int, default=2)
    return top


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command == "seed":
        write_seed(args.session, args.root, args.scratch)
        return 0
    if args.command == "run":
        soak = Soak(args.socket, args.token_dir, args.pid, args.evidence, args.scratch_dir)
        return soak.run(args.rounds, args.subscribe_batches, clamp_wait(args.subscribe_wait))
    parser().print_usage()
    return 2


if __name__ == "__main__":
    sys.exit(main())
