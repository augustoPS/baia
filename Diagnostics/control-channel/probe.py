#!/usr/bin/python3
"""Every arm and every control of the control-channel probe, over the real socket.

Driven by `run.sh`, which owns the app's lifetime and the two files this reads.
Nothing here imports, links, or calls anything the app is built from: the only
contact with baia is `AF_UNIX` bytes on `$BAIA_SOCK`, which is the whole point of
the probe. A control that reached a Swift function would keep passing while the
socket in front of it was deleted, which is the failure this directory exists to
avoid.

Python rather than Swift for that reason alone. A Swift client could open the
same socket, but it would sit one `import` away from the types it is supposed to
be testing from the outside, and the reviewer would have to check that it did
not take that step.

**Assertions read parsed JSON and never response bytes.** Key order in a frame is
`JSONEncoder`'s to choose, it is stable only within a process, and the paths in a
record come back with their solidi escaped. A control that grepped for
`{"v":1,"ok":false` would pass on the run it was written against and fail on the
next one for a reason nobody would find quickly. The one case that reads bytes at
all is the over-cap frame, whose assertion is that there were none.
"""

import glob
import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid

FRAME_CAP = 256 * 1024
CONNECT_TIMEOUT = 5.0
SETTLE_TIMEOUT = 15.0

# The bound on the churn that wraps the ring, not a plan for it. A split and the
# close the pane answers with are two events, and the ring holds 512, so the loop
# reaches the wrap well before this and stops the moment it sees it. The cap is
# here so a ring that never wraps fails the check instead of spawning panes until
# somebody notices.
CHURN_SPLITS = 340

VERBS = [
    "split", "close", "focus", "zoom", "resize", "equalize",
    "whoami", "list", "publish", "connect", "peers", "send", "recv", "revoke", "run",
]


class Probe:
    def __init__(self, socket_path, token_dir, config_path, session_path, shells_dir, scratch):
        self.socket_path = socket_path
        self.token_dir = token_dir
        self.config_path = config_path
        self.session_path = session_path
        self.shells_dir = shells_dir
        self.scratch = scratch
        self.failures = []
        self.checks = 0

    def shell_reports(self):
        """What each pane's own `.zshrc` found, keyed by pane id.

        Written after `/etc/zprofile` has run `path_helper`, which is the only
        point where the PATH question can honestly be asked.
        """
        reports = {}
        for name in sorted(os.listdir(self.shells_dir)):
            fields = {}
            with open(os.path.join(self.shells_dir, name), encoding="utf-8") as handle:
                for line in handle:
                    key, _, value = line.strip().partition("=")
                    if key:
                        fields[key] = value
            if fields.get("pane"):
                reports[fields["pane"]] = fields
        return reports

    # MARK: the wire

    def send(self, payload, read=True):
        """Writes `payload` on a fresh connection and reads one line back.

        Returns the bytes received, which are empty when the app closed without
        answering. One connection per request because the token travels on every
        frame: nothing is carried between requests, so nothing is proved by
        reusing a connection.
        """
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(CONNECT_TIMEOUT)
        received = b""
        try:
            connection.connect(self.socket_path)
            connection.sendall(payload)
            if read:
                while b"\n" not in received:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    received += chunk
        except (BrokenPipeError, ConnectionResetError):
            # The app closing mid-write is an answer in itself, and it is the
            # answer the over-cap control is looking for.
            pass
        except socket.timeout:
            received = b"<no answer within %.0fs>" % CONNECT_TIMEOUT
        finally:
            connection.close()
        return received

    def request(self, token, verb, args=None, version=1):
        frame = json.dumps({
            "v": version,
            "token": token,
            "verb": verb,
            "args": args if args is not None else {},
        })
        received = self.send((frame + "\n").encode())
        try:
            return json.loads(received)
        except ValueError:
            return {"parseFailure": received.decode("utf-8", "replace")}

    def request_through_nc(self, token, verb):
        """The same request, spelled the way the protocol's own docs promise.

        `ControlWire` justifies newline-delimited JSON over a length-prefixed
        frame by saying the channel stays debuggable with `nc`, and a claim that
        nothing exercises is a claim that stops being true quietly. `nc` closes
        the whole socket when its stdin ends, so stdin is held open until the
        answer has been read.
        """
        frame = json.dumps({"v": 1, "token": token, "verb": verb, "args": {}}) + "\n"
        process = subprocess.Popen(
            ["/usr/bin/nc", "-U", self.socket_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        killer = threading.Timer(CONNECT_TIMEOUT, process.kill)
        killer.start()
        try:
            process.stdin.write(frame.encode())
            process.stdin.flush()
            line = process.stdout.readline()
        finally:
            killer.cancel()
            process.kill()
            process.wait()
        try:
            return json.loads(line)
        except ValueError:
            return {"parseFailure": line.decode("utf-8", "replace")}

    @staticmethod
    def code(response):
        """A response as the one word every expectation below is written in."""
        if "parseFailure" in response:
            return "unparseable"
        if response.get("ok") is True:
            return "ok"
        error = response.get("error")
        if isinstance(error, dict) and isinstance(error.get("code"), str):
            return error["code"]
        return "malformed"

    @staticmethod
    def named_panes(response):
        records = (response.get("result") or {}).get("panes")
        if not isinstance(records, list):
            return None
        return sorted(record.get("pane") for record in records)

    @staticmethod
    def events(response):
        """The events a `subscribe` answered with, or None when it answered none.

        None rather than an empty list for a malformed answer, so a check that
        expected events prints the difference between "the batch was empty" and
        "there was no batch at all".
        """
        batch = (response.get("result") or {}).get("events")
        return batch if isinstance(batch, list) else None

    @staticmethod
    def sequence(response):
        """The ring's sequence, which `list` reports and `subscribe` continues from.

        The bootstrap in one field: a supervisor reads the records and the
        sequence they were read at, and everything after it arrives as an event.
        """
        return (response.get("result") or {}).get("seq")

    @staticmethod
    def gap(response):
        """Whether the ring evicted events before the cursor that was asked for."""
        return (response.get("result") or {}).get("gap")

    @staticmethod
    def record_of(response, pane):
        """One pane's record out of a `list`, or None when that list omitted it."""
        for record in (response.get("result") or {}).get("panes") or []:
            if record.get("pane") == pane:
                return record
        return None

    # MARK: what the app told the panes

    def tokens(self):
        """Pane id to capability, as the panes' own shells reported them.

        The map is built from `$BAIA_TOKEN` as each pane's shell saw it, which is
        the only place a capability exists: it is minted per pane per run and
        never written anywhere. `run.sh` explains how the shells report it and
        why that is a readout rather than a forgery.
        """
        found = {}
        for path in sorted(glob.glob(os.path.join(self.token_dir, "pane-*.env"))):
            with open(path) as handle:
                fields = dict(
                    line.split("=", 1)
                    for line in handle.read().strip().split("\n")
                    if "=" in line
                )
            if fields.get("pane") and fields.get("token"):
                found[fields["pane"]] = fields["token"]
        return found

    def pane_ids_on_disk(self):
        """Every pane id in `session.json`, which is what the finding turns on.

        A pane id is public by construction: this file is mode 0600 in a 0700
        directory, which excludes other users and not other processes of this
        one. Any pane running `cat` on it learns every id in the workspace.
        """
        with open(self.session_path) as handle:
            document = json.load(handle)
        return [entry["id"]["rawValue"] for entry in document["panes"]]

    def await_token(self, pane, limit=SETTLE_TIMEOUT):
        deadline = time.time() + limit
        while time.time() < deadline:
            found = self.tokens()
            if pane in found:
                return found[pane]
            time.sleep(0.2)
        return None

    # MARK: settings

    def write_config(self, channel_enabled, allow_run):
        with open(self.config_path, "w") as handle:
            json.dump({
                "controlChannelEnabled": channel_enabled,
                "controlAllowRun": allow_run,
                "restoreSession": True,
                "notificationsEnabled": False,
            }, handle, indent=2)
            handle.write("\n")

    def await_code(self, token, verb, want, limit=SETTLE_TIMEOUT):
        """Polls until the app has read the config, or gives up and reports.

        A fixed sleep would either be too short on a loaded machine or waste the
        difference on every run. The wait is the assertion: a key with no
        consumer never reaches `want` and the case fails on the deadline.
        """
        deadline = time.time() + limit
        last = None
        while time.time() < deadline:
            last = self.code(self.request(token, verb))
            if last == want:
                return last
            time.sleep(0.1)
        return last

    def park(self, token, seconds):
        """Sends `recv --wait` and returns the connection still holding it open.

        The caller closes it. Nothing is read here on purpose: a parked `recv` is
        a connection the app is deliberately not answering yet, and the point of
        holding one is to ask what the rest of the channel does meanwhile.
        """
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(CONNECT_TIMEOUT)
        connection.connect(self.socket_path)
        frame = json.dumps({
            "v": 1,
            "token": token,
            "verb": "recv",
            "args": {"wait": seconds},
        }) + "\n"
        connection.sendall(frame.encode())
        return connection

    def park_subscribe(self, token, cursor, kinds, seconds):
        """Sends `subscribe --wait` and returns the connection still holding it.

        ``park``'s twin rather than a parameter on it, for the reason the server
        keeps a `ParkedKind` at all: the two long polls are woken by different
        machinery, and a probe that parked one while claiming the other would
        prove nothing about the one it named.
        """
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(CONNECT_TIMEOUT)
        connection.connect(self.socket_path)
        frame = json.dumps({
            "v": 1,
            "token": token,
            "verb": "subscribe",
            "args": {"from": cursor, "kinds": kinds, "wait": seconds},
        }) + "\n"
        connection.sendall(frame.encode())
        return connection

    @staticmethod
    def answered(connection):
        """The line a parked long poll is eventually woken with."""
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

    def await_events(self, token, cursor, count, kinds=None, pane=None, limit=SETTLE_TIMEOUT):
        """Polls `subscribe` until the batch holds `count` of the events asked for.

        ``await_code``'s shape and its reason: the wait is the assertion, so an
        event that never arrives fails on the deadline rather than on a sleep
        that was too short. Nothing here consumes anything, so every poll reads
        from the same cursor and the batch that comes back is the whole answer
        rather than an increment on the last one.
        """
        deadline = time.time() + limit
        seen = []
        while time.time() < deadline:
            args = {"from": cursor}
            if kinds is not None:
                args["kinds"] = kinds
            seen = [
                event
                for event in self.events(self.request(token, "subscribe", args)) or []
                if pane is None or event.get("pane") == pane
            ]
            if len(seen) >= count:
                break
            time.sleep(0.1)
        return seen

    # MARK: making a pane do something nothing here can type into it

    def arm(self, name):
        """Plants the file the panes' `.zshrc` reads as their shells start.

        The readout's trick turned the other way round. Nothing here can reach a
        keyboard, so a check that needs a pane to run a command plants a file and
        splits: a shell started while the file is there obeys it. `run.sh` holds
        the two arms and explains what each one does.
        """
        with open(os.path.join(self.scratch, "arm-" + name), "w"):
            pass

    def disarm(self, name):
        """Removes an arm, so the panes after this one are ordinary panes again."""
        os.remove(os.path.join(self.scratch, "arm-" + name))

    def timed(self, token, verb):
        """A request, and how long the answer took to arrive."""
        started = time.time()
        response = self.request(token, verb)
        return response, time.time() - started

    # MARK: reporting

    def check(self, name, got, want):
        self.checks += 1
        if got == want:
            print("ok    %s" % name)
            return True
        print("FAIL  %s" % name)
        print("        expected: %r" % (want,))
        print("        got:      %r" % (got,))
        self.failures.append(name)
        return False

    def abort(self, message):
        print("PROBE CANNOT RUN: %s" % message)
        sys.exit(2)


def main():
    if len(sys.argv) != 7:
        print("usage: probe.py <socket> <token-dir> <config> <session> <shells-dir> <scratch>")
        return 2

    probe = Probe(*sys.argv[1:7])
    live = probe.tokens()
    if len(live) < 3:
        probe.abort(
            "only %d pane capabilities were reported and the probe needs three. "
            "run.sh restores a three-pane session before launching." % len(live)
        )

    on_disk = probe.pane_ids_on_disk()
    registered = [pane for pane in on_disk if pane in live]
    if len(registered) < 3:
        probe.abort(
            "session.json names %d panes that hold a live capability and the probe "
            "needs three" % len(registered)
        )

    alpha, bravo = registered[0], registered[1]

    print("-- the wire answers at all")
    probe.check(
        "whoami through nc names the calling pane and nothing else",
        probe.named_panes(probe.request_through_nc(live[alpha], "whoami")),
        [alpha],
    )

    print()
    print("-- a token is a capability and nothing else is")
    probe.check(
        "a token that was never issued is refused with badToken",
        probe.code(probe.request("this-token-was-never-issued", "whoami")),
        "badToken",
    )
    # The finding this probe exists for. Both ids are read out of session.json
    # rather than invented, and both belong to panes that hold a live capability
    # at this moment, so neither is refused for being stale or unknown. An
    # implementation that let `authorize` fall back to a pane id "so the read
    # verbs keep working with the ids they return" answers `ok` here.
    probe.check(
        "the caller's own pane id, read out of session.json, is refused with badToken",
        probe.code(probe.request(alpha, "whoami")),
        "badToken",
    )
    probe.check(
        "another live pane's id, read out of session.json, is refused with badToken",
        probe.code(probe.request(bravo, "whoami")),
        "badToken",
    )

    print()
    print("-- the version field is enforced in the direction that matters")
    probe.check(
        "a frame claiming v0 is refused with badVersion",
        probe.code(probe.request(live[alpha], "whoami", version=0)),
        "badVersion",
    )
    probe.check(
        "a frame claiming v2 is refused with badVersion",
        probe.code(probe.request(live[alpha], "whoami", version=2)),
        "badVersion",
    )

    print()
    print("-- the frame cap is enforced on the bytes, before anything parses them")
    # No newline anywhere in it: the read loop has to decide on the bytes as they
    # arrive rather than on a line that ended, which is why this is closed on
    # rather than answered `badFrame`.
    oversized = (
        b'{"v":1,"token":"'
        + b"x" * (FRAME_CAP + 4096)
        + b'","verb":"whoami","args":{}}\n'
    )
    probe.check(
        "a line over the frame cap is closed on without a response",
        probe.send(oversized),
        b"",
    )

    print()
    print("-- scope, asserted on what came back rather than on a refusal")
    split = probe.request(live[alpha], "split", {"axis": "horizontal"})
    child = (split.get("result") or {}).get("pane")
    probe.check("split through the channel answers with the child's id", probe.code(split), "ok")
    if not child:
        probe.abort("split returned no pane id, so the scope arms below have nothing to assert on")

    child_token = probe.await_token(child)
    probe.check(
        "the pane split through the channel is a real pane with a capability of its own",
        child_token is not None,
        True,
    )
    # The arm the whole section is for. A read leak fails by over-succeeding, so
    # this asserts the contents of the answer: the workspace holds four panes at
    # this point and alpha is entitled to see exactly two of them.
    probe.check(
        "list names exactly the calling pane and the pane it created",
        probe.named_panes(probe.request(live[alpha], "list")),
        sorted([alpha, child]),
    )
    probe.check(
        "a pane that created nothing lists only itself",
        probe.named_panes(probe.request(live[bravo], "list")),
        [bravo],
    )
    probe.check(
        "whoami still names one pane after that pane has created another",
        probe.named_panes(probe.request(live[alpha], "whoami")),
        [alpha],
    )

    print()
    print("-- a pane that exists and a pane that does not are the same answer")
    to_non_peer = probe.request(live[alpha], "send", {"peer": bravo, "text": "probe"})
    to_nobody = probe.request(
        live[alpha], "send", {"peer": str(uuid.uuid4()).upper(), "text": "probe"}
    )
    probe.check(
        "send to a live pane that is not a peer is refused with unauthorized",
        probe.code(to_non_peer),
        "unauthorized",
    )
    probe.check(
        "send to a pane that does not exist is refused with the same code",
        probe.code(to_nobody),
        probe.code(to_non_peer),
    )

    print()
    print("-- controlChannelEnabled has a consumer")
    probe.write_config(channel_enabled=False, allow_run=False)
    settled = probe.await_code(live[alpha], "whoami", "disabled")
    if probe.check("switching the channel off is picked up live", settled, "disabled"):
        for verb in VERBS:
            probe.check(
                "with the channel off, %s answers disabled" % verb,
                probe.code(probe.request(live[alpha], verb)),
                "disabled",
            )
    probe.write_config(channel_enabled=True, allow_run=False)
    probe.check(
        "switching the channel back on is picked up live",
        probe.await_code(live[alpha], "whoami", "ok"),
        "ok",
    )

    print()
    print("-- controlAllowRun has a consumer, and it is a different one")
    probe.check(
        "run answers disabled while controlAllowRun is false",
        probe.code(probe.request(live[alpha], "run")),
        "disabled",
    )
    probe.write_config(channel_enabled=True, allow_run=True)
    probe.check(
        "allowing run changes its code from disabled to refused",
        probe.await_code(live[alpha], "run", "refused"),
        "refused",
    )
    probe.check(
        "allowing run does not switch anything else on",
        probe.code(probe.request(live[alpha], "whoami")),
        "ok",
    )
    probe.write_config(channel_enabled=True, allow_run=False)
    probe.check(
        "disallowing run again puts its code back",
        probe.await_code(live[alpha], "run", "disabled"),
        "disabled",
    )

    print()
    print("-- the helper reaches a pane's PATH, and runs when it gets there")
    # Both of these were on the by-hand list until a `.zshrc` plant turned out to
    # answer them. PATH is the riskiest assumption in the whole design: ghostty
    # spawns `login -flp`, so the pane's zsh is a login shell, `/etc/zprofile`
    # runs `path_helper`, and `path_helper` REBUILDS PATH from `/etc/paths` and
    # appends whatever was already there behind it. Survival is the claim, not
    # position; nothing in `/usr/bin` is named `baia`.
    shells = probe.shell_reports()
    probe.check(
        "every pane's shell reported what it found on PATH",
        len(shells) >= 3,
        True,
    )
    for pane, fields in sorted(shells.items()):
        found = fields.get("which", "")
        probe.check(
            "baia is on PATH in pane %s after path_helper has rebuilt it" % pane[-12:],
            found.endswith("/Contents/Helpers/baia"),
            True,
        )
        # A trailing slash on the injected directory reaches PATH and surfaces as
        # `…/Contents/Helpers//baia` the first time anybody runs `command -v`. It
        # resolves, so nothing breaks, and it reads as a bug in the one place a
        # reader looks to confirm the embedding worked.
        probe.check(
            "and the PATH entry has no doubled separator in pane %s" % pane[-12:],
            "//" not in found,
            True,
        )
        # Running it, not just finding it: this is the embedded tool executing
        # under hardened runtime with an ad-hoc signature, from inside a real
        # pane, through the whole login/bash/zsh spawn chain.
        probe.check(
            "and `baia whoami` runs from that pane and exits 0",
            fields.get("whoami_exit"),
            "0",
        )

    print()
    print("-- a parked recv holds one connection and nothing else")
    # Two of the spec's six live-verification items turned out not to need a
    # keyboard after all, so they are here rather than on the owner's list. This
    # one is "recv --wait leaves the UI responsive and every other pane's channel
    # served". The UI half still needs eyes; the channel half is measurable, and
    # it is the half that regresses silently. A server that answered a parked
    # recv on the main thread would make the request below wait out the whole
    # park, so the assertion is the elapsed time and not the code.
    parked = probe.park(live[alpha], 20)
    try:
        served, elapsed = probe.timed(live[bravo], "whoami")
        probe.check(
            "another pane is served while a recv is parked",
            probe.code(served),
            "ok",
        )
        probe.check(
            "and it is served immediately rather than after the park",
            "under 2s" if elapsed < 2.0 else "%.1fs, which is the park" % elapsed,
            "under 2s",
        )
    finally:
        parked.close()

    print()
    print("-- what a supervising pane hears about the panes below it")
    # Everything here splits, so it sits below the PATH section, whose count is
    # every pane that reported. It sits above the close section for the opposite
    # reason: charlie is spent there and these checks need alpha's subtree to
    # still be a subtree.
    #
    # `--kinds` narrows almost every read below, and that is not decoration. A
    # pane's activity is polled on a timer, so an `activityChanged` about
    # somebody else can land between any two frames here, and a check that
    # asserted a whole batch without narrowing it would fail on a timer rather
    # than on the wire.
    opening = probe.sequence(probe.request(live[alpha], "list"))
    waiting = probe.park_subscribe(live[alpha], opening, ["paneOpened"], 10)
    try:
        born = (probe.request(live[alpha], "split", {"axis": "vertical"})
                .get("result") or {}).get("pane")
        woken = probe.answered(waiting)
    finally:
        waiting.close()
    if not born:
        probe.abort("the split for the subscribe arms returned no pane id")
    probe.check(
        "a parked subscribe is woken by a descendant opening, and names its creator",
        [(event.get("kind"), event.get("pane"), event.get("createdBy"))
         for event in probe.events(woken) or []],
        [("paneOpened", born, alpha)],
    )

    # The check the audience design exists for, and the one that fails if the
    # emit in `forgetPane` ever moves after `graph.close`: the parentage that
    # puts the parent in the audience is gone by then, and the death notice
    # reaches only the pane that died.
    born_token = probe.await_token(born)
    closing = probe.sequence(probe.request(live[alpha], "list"))
    probe.request(born_token, "close")
    probe.check(
        "a parent hears the close of a child that no longer exists to authorise it",
        [event.get("pane")
         for event in probe.await_events(live[alpha], closing, 1, kinds=["paneClosed"])],
        [born],
    )

    # A read leak fails by over-succeeding, so this asserts contents like the
    # scope section above it. Bravo's own opening is in the ring and bravo is
    # entitled to it, which is why the assertion is about every pane that is not
    # bravo: alpha's subtree has just opened and closed a pane, and none of it is
    # bravo's business.
    stray = probe.events(probe.request(live[bravo], "subscribe", {"from": 0})) or []
    probe.check(
        "a pane outside the subtree is told about no pane but itself",
        sorted({event.get("pane") for event in stray} - {bravo}),
        [],
    )

    # The bootstrap handoff. `list` reports the sequence it read the records at,
    # so a subscriber that continues from it must see every event after that
    # point exactly once and none of the ones already in the records.
    handoff = probe.sequence(probe.request(live[alpha], "list"))
    spent = (probe.request(live[alpha], "split", {"axis": "horizontal"})
             .get("result") or {}).get("pane")
    probe.request(probe.await_token(spent), "close")
    kept = (probe.request(live[alpha], "split", {"axis": "horizontal"})
            .get("result") or {}).get("pane")
    probe.check(
        "subscribe from the sequence list reported has no duplicate and no hole",
        [(event.get("kind"), event.get("pane"))
         for event in probe.await_events(
             live[alpha], handoff, 3, kinds=["paneOpened", "paneClosed"]
         )],
        [("paneOpened", spent), ("paneClosed", spent), ("paneOpened", kept)],
    )

    # The live half of the one-renderer rule. `PaneRecord.activity` and the
    # event's `activity` are the same property read in two places, and the whole
    # point is that a subscriber's bootstrap and its stream speak one vocabulary,
    # so the assertion compares them to each other and to what is running.
    #
    # Before the churn below rather than after it, which is not tidiness: the
    # activity a pane reports is polled on a two-second timer, and a run that had
    # just spawned and reaped two hundred and fifty shells took long enough to
    # start this one that the poll had nothing to see inside the deadline. The
    # check was measuring the machine.
    probe.arm("activity")
    try:
        starting = probe.sequence(probe.request(live[alpha], "list"))
        busy = (probe.request(live[alpha], "split", {"axis": "vertical"})
                .get("result") or {}).get("pane")
        heard = probe.await_events(
            live[alpha], starting, 1, kinds=["activityChanged"], pane=busy
        )
        record = probe.record_of(probe.request(live[alpha], "list"), busy) or {}
    finally:
        probe.disarm("activity")
    probe.check(
        "the activity in an event is the activity list reports for the same pane",
        [heard[-1].get("activity") if heard else None, record.get("activity")],
        ["sleep", "sleep"],
    )

    # Overflow, with the arm doing the closing: a pane that closes itself as its
    # shell starts is one split for two events, which is the cheapest ring churn
    # a script with no keyboard can cause. The loop stops at the wrap rather than
    # running to its cap, and it goes last in this section because it leaves the
    # machine two hundred and fifty shells busier than it found it.
    probe.arm("churn")
    wrapped = False
    try:
        for _ in range(CHURN_SPLITS):
            probe.request(live[alpha], "split", {"axis": "horizontal"})
            wrapped = probe.gap(probe.request(live[alpha], "subscribe", {"from": 0}))
            if wrapped:
                break
    finally:
        probe.disarm("churn")
    probe.check(
        "a ring that wrapped past the cursor answers gap rather than a quiet hole",
        wrapped,
        True,
    )

    print()
    print("-- close answers before the shell it kills")
    # The other item that turned out scriptable: "the response arrives before the
    # shell dies on baia close". The spec has the server flush the answer before
    # scheduling the close on the next main-loop turn, and a client that sees EOF
    # instead must treat it as success, so an implementation that stopped
    # flushing would still look fine from the CLI. It does not look fine here: an
    # answer that never arrived reads as `unparseable` against an empty line.
    #
    # Charlie is spent deliberately and goes last, because after this it has no
    # pane. Everything above needs three panes; nothing below needs any.
    charlie = registered[2]
    probe.check(
        "a pane closing itself is answered rather than cut off",
        probe.code(probe.request(live[charlie], "close")),
        "ok",
    )
    probe.check(
        "and its capability stops working once the pane is gone",
        probe.await_code(live[charlie], "whoami", "badToken"),
        "badToken",
    )

    print()
    if probe.failures:
        print("FAILED %d of %d checks:" % (len(probe.failures), probe.checks))
        for name in probe.failures:
            print("  - %s" % name)
        return 1
    print("PASS: all %d checks" % probe.checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
