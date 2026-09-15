#!/usr/bin/python3
"""Regression tests for the resource-soak graders and the session seed.

Runs without an app, a socket or a token directory:

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v Diagnostics/resource-soak/test_probe.py

The graders are validated the way the plan asks: synthetic flat samples pass,
steadily retained descriptors fail, a leftover owned child fails. The live
failure controls (retained sockets, a known leftover child under a real pane)
are in `probe.py`'s control arm and need the app; they are not simulated here.
"""

import importlib.util
import io
import json
import os
import pathlib
import socket
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("resource_soak_probe", HERE / "probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def sample(label, fds, descendants=(101, 102), unix=8):
    return {
        "label": label, "fds": fds, "rss_kb": 100000,
        "descendants": sorted(descendants), "types": {"unix": unix, "REG": fds - unix},
        "lsof": [], "commands": {},
    }


def flat_series(fds, count=10):
    return [sample("batch %d" % (10 * (i + 1)), fds) for i in range(count)]


def failed(results):
    return probe.failed_names(results)


class ImportTests(unittest.TestCase):
    def test_importing_the_module_runs_no_workload(self):
        # Loading the module above touched no socket and parsed no argv; the
        # workload sits behind `main`, which refuses to run without a command.
        self.assertTrue(callable(probe.main))
        with redirect_stdout(io.StringIO()):
            self.assertEqual(2, probe.main([]))

    def test_quota_arithmetic_stays_below_the_per_pane_cap(self):
        # ControlWire.maxConnectionsPerPane is 4 and maxConnections is 16 at
        # this revision. Two parked clients per scratch pane over four panes.
        self.assertEqual(4, len(probe.SCRATCH))
        self.assertLess(probe.SUBSCRIBE_CLIENTS_PER_PANE, 4)
        self.assertLess(probe.SUBSCRIBE_CLIENTS_PER_PANE * len(probe.SCRATCH), 16)

    def test_subscribe_wait_is_bounded_to_five_seconds(self):
        self.assertEqual(5, probe.SUBSCRIBE_WAIT_CAP)
        self.assertEqual(5, probe.clamp_wait(60))
        self.assertEqual(1, probe.clamp_wait(0))
        self.assertEqual(2, probe.clamp_wait(2))


class SeedTests(unittest.TestCase):
    def test_seed_is_the_current_schema_with_groups_and_no_workspace(self):
        document = probe.seed_document("/tmp/soak", probe.SCRATCH)
        self.assertEqual(2, document["schemaVersion"])
        self.assertEqual(probe.SESSION_SCHEMA, document["schemaVersion"])
        self.assertNotIn("workspace", document)
        self.assertNotIn("windowFrame", document)
        self.assertEqual(1, len(document["groups"]))
        group = document["groups"][0]
        self.assertEqual(group["id"], document["activeGroup"])
        self.assertEqual(group["selectedTab"], group["tabs"][0]["id"])
        self.assertEqual({"x", "y", "width", "height"}, set(group["frame"]))

    def test_seed_names_the_anchor_and_every_scratch_pane_once(self):
        document = probe.seed_document("/tmp/soak", probe.SCRATCH)
        ids = [pane["id"]["rawValue"] for pane in document["panes"]]
        self.assertEqual([probe.ALPHA] + probe.SCRATCH, ids)
        self.assertTrue(all(pane["workingDirectory"] == "/tmp/soak" for pane in document["panes"]))
        leaves = self.leaves(document["groups"][0]["tabs"][0]["tree"])
        self.assertEqual(ids, leaves)
        self.assertEqual(probe.ALPHA, document["groups"][0]["tabs"][0]["focusedPane"]["rawValue"])

    def test_split_close_seed_holds_the_anchor_alone(self):
        document = probe.seed_document("/tmp/soak", [])
        self.assertEqual([probe.ALPHA], [pane["id"]["rawValue"] for pane in document["panes"]])
        self.assertEqual({"leaf": {"_0": {"rawValue": probe.ALPHA}}}, document["groups"][0]["tabs"][0]["tree"])

    def test_write_seed_round_trips_through_json(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = os.path.join(scratch, "session.json")
            written = probe.write_seed(path, scratch, 4)
            with open(path) as handle:
                self.assertEqual(written, json.load(handle))

    @staticmethod
    def leaves(node):
        if "leaf" in node:
            return [node["leaf"]["_0"]["rawValue"]]
        split = node["split"]
        return SeedTests.leaves(split["first"]) + SeedTests.leaves(split["second"])


class CensusGraderTests(unittest.TestCase):
    def test_a_census_that_never_settled_fails(self):
        warm = sample("warm", 200)
        final = sample("settled", 200)
        final["stable"] = False
        self.assertIn("every graded census reached a stable sample",
                      failed(probe.grade_census(warm, [], final)))

    def test_flat_samples_pass(self):
        warm = sample("warm", 200)
        results = probe.grade_census(warm, flat_series(200), sample("settled", 200))
        self.assertEqual([], failed(results))
        self.assertEqual(5, len(results))

    def test_jitter_within_tolerance_passes(self):
        warm = sample("warm", 200)
        plateau = [sample("batch %d" % i, fds) for i, fds in enumerate([201, 199, 202, 200, 201, 200, 203, 200, 201, 200])]
        self.assertEqual([], failed(probe.grade_census(warm, plateau, sample("settled", 201))))

    def test_steadily_retained_descriptors_fail(self):
        warm = sample("warm", 200)
        plateau = [sample("batch %d" % (10 * (i + 1)), 200 + 2 * (i + 1)) for i in range(10)]
        names = failed(probe.grade_census(warm, plateau, sample("settled", 220)))
        self.assertTrue(any(name.startswith("descriptors stay within") for name in names), names)
        self.assertTrue(any(name.startswith("descriptors after settling") for name in names), names)
        self.assertTrue(any(name.startswith("no sustained per-batch") for name in names), names)
        self.assertFalse(any(name.startswith("no descendant") for name in names), names)

    def test_slow_retention_that_stays_inside_the_range_is_still_growth(self):
        # One descriptor kept every twenty batches sits inside the range check;
        # the halves of the churn still separate, and the trend names it.
        warm = sample("warm", 200)
        plateau = [sample("batch %d" % i, 200 + i // 2) for i in range(10)]
        names = failed(probe.grade_census(warm, plateau, sample("settled", 205)))
        self.assertIn("descriptors after settling stay within 4 of the warm baseline (205 vs 200)", names)
        self.assertTrue(any(name.startswith("no sustained per-batch") for name in names), names)

    def test_a_leftover_owned_child_fails(self):
        warm = sample("warm", 200, descendants=(101, 102))
        settled = sample("settled", 200, descendants=(101, 102, 4242))
        names = failed(probe.grade_census(warm, flat_series(200), settled))
        self.assertEqual(["no descendant remains beyond the warm baseline"], names)

    def test_a_lost_baseline_child_fails_under_its_own_name(self):
        warm = sample("warm", 200, descendants=(101, 102))
        settled = sample("settled", 200, descendants=(101,))
        names = failed(probe.grade_census(warm, flat_series(200), settled))
        self.assertEqual(["no baseline descendant was lost"], names)

    def test_retained_sockets_census_is_rejected_on_descriptors_alone(self):
        # The shape of the live control arm: eight sockets held open, nothing
        # else changed, no plateau. Descriptors reject, descendants pass.
        warm = sample("warm", 200, unix=8)
        census = sample("control-retained", 208, unix=16)
        names = failed(probe.grade_census(warm, [], census))
        self.assertTrue(any(name.startswith("descriptors after settling") for name in names), names)
        self.assertFalse(any(name.startswith("no descendant") for name in names), names)
        self.assertFalse(any(name.startswith("no baseline") for name in names), names)

    def test_tolerance_boundary_is_inclusive(self):
        warm = sample("warm", 200)
        self.assertEqual([], failed(probe.grade_census(warm, [], sample("settled", 204))))
        self.assertNotEqual([], failed(probe.grade_census(warm, [], sample("settled", 205))))

    def test_mapped_files_are_not_counted_as_descriptors(self):
        lines = ["baia 1 me cwd DIR 1,2 3 4 /x",
                 "baia 1 me txt REG 1,2 3 4 /lib",
                 "baia 1 me 3u unix 0x1 0t0 ->0x2",
                 "baia 1 me 4r REG 1,2 3 4 /cache"]
        self.assertEqual({"unix": 1, "REG": 1}, probe.descriptor_types(lines))

    def test_descriptor_types_count_the_type_column(self):
        lines = [
            "baia 1 me cwd DIR 1,2 3 4 /x",
            "baia 1 me 3u unix 0x1 0t0 ->0x2",
            "baia 1 me 4u unix 0x3 0t0 ->0x4",
            "short line",
        ]
        self.assertEqual({"unix": 2}, probe.descriptor_types(lines))


def batch(number, mode, parked=8, early=(), answered=8, empty=8, slowest=2.1):
    record = {"batch": number, "mode": mode, "parked": parked, "early": list(early), "latency": 0.01, "served": True}
    if mode == "timeout":
        record.update({"answered": answered, "empty": empty, "slowest": slowest})
    return record


class BatchGraderTests(unittest.TestCase):
    def alternating(self, count):
        return [batch(n, "disconnect" if n % 2 else "timeout") for n in range(1, count + 1)]

    def test_full_alternating_batches_pass(self):
        self.assertEqual([], failed(probe.grade_batches(self.alternating(100), 2, 8)))

    def test_a_fast_refusal_is_not_a_served_request(self):
        records = self.alternating(10)
        records[3]["served"] = False
        self.assertIn("every request succeeds while subscriptions are parked",
                      failed(probe.grade_batches(records, 2, 8)))

    def test_an_early_answer_is_not_a_parked_client(self):
        records = self.alternating(10)
        records[2]["early"] = [5]
        names = failed(probe.grade_batches(records, 2, 8))
        self.assertEqual(["no parked subscription was answered before its batch ended"], names)

    def test_a_short_batch_fails(self):
        records = self.alternating(10)
        records[0]["parked"] = 7
        names = failed(probe.grade_batches(records, 2, 8))
        self.assertIn("every batch parked 8 subscriptions", names)

    def test_a_timeout_batch_that_was_not_answered_fails(self):
        records = self.alternating(10)
        records[1]["answered"] = 6
        names = failed(probe.grade_batches(records, 2, 8))
        self.assertIn("every timeout batch was answered by the deadline with an empty batch", names)

    def test_a_timeout_answer_later_than_the_deadline_plus_slack_fails(self):
        records = self.alternating(10)
        records[1]["slowest"] = 2 + probe.CONNECT_TIMEOUT + 1
        names = failed(probe.grade_batches(records, 2, 8))
        self.assertTrue(any(name.startswith("no timeout answer arrived later") for name in names), names)

    def test_one_mode_only_is_not_alternation(self):
        records = [batch(n, "disconnect") for n in range(1, 11)]
        names = failed(probe.grade_batches(records, 2, 8))
        self.assertEqual(["the churn alternated disconnect and timeout batches"], names)


class LatencyAndEventGraderTests(unittest.TestCase):
    def test_latencies_under_the_limit_pass(self):
        self.assertEqual([], failed(probe.grade_latencies([0.01, 0.02, 1.9])))

    def test_a_request_held_for_the_park_fails(self):
        self.assertNotEqual([], failed(probe.grade_latencies([0.01, 2.2])))

    def test_no_latencies_at_all_fails(self):
        self.assertNotEqual([], failed(probe.grade_latencies([])))

    def test_a_woken_subscription_naming_the_split_passes(self):
        woken = {"ok": True, "result": {"events": [{"kind": "paneOpened", "pane": "P"}], "seq": 41}}
        self.assertEqual([], failed(probe.grade_postchurn(40, woken, "P")))

    def test_an_empty_or_stale_wake_fails(self):
        empty = {"ok": True, "result": {"events": [], "seq": 40}}
        names = failed(probe.grade_postchurn(40, empty, "P"))
        self.assertEqual(2, len(names))
        wrong = {"ok": True, "result": {"events": [{"kind": "paneOpened", "pane": "Q"}], "seq": 41}}
        self.assertEqual(1, len(failed(probe.grade_postchurn(40, wrong, "P"))))
        self.assertEqual(2, len(failed(probe.grade_postchurn(40, {"parseFailure": ""}, "P"))))


class FakeChannel(threading.Thread):
    """An AF_UNIX server speaking just enough of the wire for one batch.

    `subscribe --wait` is held for the wait and then answered empty, the way
    the real deadline does, unless `answer_at_once` makes it answer straight
    away, which is the shape of an eviction or a stray event.
    """

    def __init__(self, path, answer_at_once=False):
        super().__init__(daemon=True)
        self.path = path
        self.answer_at_once = answer_at_once
        self.seq = 40
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(32)
        self.listener.settimeout(0.2)
        self.stopping = False

    def run(self):
        while not self.stopping:
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.serve, args=(connection,), daemon=True).start()
        self.listener.close()

    def serve(self, connection):
        try:
            received = b""
            while b"\n" not in received:
                chunk = connection.recv(65536)
                if not chunk:
                    return
                received += chunk
            frame = json.loads(received)
            verb = frame["verb"]
            if verb == "list":
                reply = {"ok": True, "result": {"panes": [{"pane": probe.ALPHA}], "seq": self.seq}}
            elif verb == "whoami":
                reply = {"ok": True, "result": {"panes": [{"pane": probe.ALPHA}]}}
            elif verb == "split":
                self.seq += 1
                reply = {"ok": True, "result": {"pane": "NEW"}}
            elif verb == "subscribe":
                wait = frame["args"].get("wait") or 0
                if wait and not self.answer_at_once:
                    time.sleep(wait)
                reply = {"ok": True, "result": {"events": [], "seq": self.seq, "gap": False}}
            else:
                reply = {"ok": False, "error": {"code": "refused", "message": verb}}
            connection.sendall((json.dumps(reply) + "\n").encode())
            # The real server keeps the connection open after a deadline
            # answer; the client is the one that closes it.
            while connection.recv(65536):
                pass
        except (BrokenPipeError, ConnectionResetError, OSError, ValueError):
            pass
        finally:
            connection.close()

    def stop(self):
        self.stopping = True
        self.join(timeout=2)


class BatchMechanicsTests(unittest.TestCase):
    """`Soak.run_batch` against the fake channel: no app, no lsof, no token dir."""

    def setUp(self):
        self.scratch = tempfile.mkdtemp(prefix="soak")
        self.path = os.path.join(self.scratch, "c.sock")
        self.tokens = {pane: "t-" + pane[-2:] for pane in [probe.ALPHA] + probe.SCRATCH}
        self.server = None

    def tearDown(self):
        if self.server:
            self.server.stop()
        for name in os.listdir(self.scratch):
            os.remove(os.path.join(self.scratch, name))
        os.rmdir(self.scratch)

    def start(self, **options):
        self.server = FakeChannel(self.path, **options)
        self.server.start()
        return probe.Soak(self.path, self.scratch, os.getpid(), self.scratch, self.scratch)

    def test_a_disconnect_batch_parks_eight_and_times_a_served_request(self):
        soak = self.start()
        record = soak.run_batch(1, "disconnect", self.tokens, 1)
        self.assertEqual(8, record["parked"])
        self.assertEqual([], record["early"])
        self.assertTrue(record["served"])
        self.assertLess(record["latency"], 1.0)
        self.assertEqual(40, record["cursor"])
        self.assertLess(record["seconds"], 1.0, "a disconnect batch never waits out the deadline")

    def test_a_timeout_batch_reads_eight_deadline_answers(self):
        soak = self.start()
        record = soak.run_batch(2, "timeout", self.tokens, 1)
        self.assertEqual(8, record["parked"])
        self.assertEqual([], record["early"])
        self.assertEqual(8, record["answered"])
        self.assertEqual(8, record["empty"])
        self.assertGreaterEqual(record["fastest"], 0.5)
        self.assertEqual([], probe.failed_names(probe.grade_batches([record], 1, 8)[:4]))

    def test_a_server_that_answers_at_once_is_recorded_as_early(self):
        soak = self.start(answer_at_once=True)
        record = soak.run_batch(1, "disconnect", self.tokens, 1)
        self.assertEqual(8, record["parked"])
        # The fake answers from eight threads, so the 0.3 s readiness window
        # may miss a straggler; the claim is that an answered client is named
        # as early and the batch is then rejected, not that all eight are.
        self.assertTrue(record["early"])
        self.assertTrue(set(record["early"]) <= set(range(8)))
        names = probe.failed_names(probe.grade_batches([record], 1, 8))
        self.assertIn("no parked subscription was answered before its batch ended", names)

    def test_a_socket_that_is_not_listening_is_recorded_not_raised(self):
        soak = probe.Soak(os.path.join(self.scratch, "absent.sock"), self.scratch,
                          os.getpid(), self.scratch, self.scratch)
        record = soak.run_batch(1, "disconnect", self.tokens, 1)
        self.assertEqual(0, record["parked"])
        self.assertIn("error", record)
        self.assertIn("every batch parked 8 subscriptions",
                      probe.failed_names(probe.grade_batches([record], 1, 8)))

    def test_a_census_of_this_process_reads_lsof_and_ps(self):
        soak = self.start()
        with redirect_stdout(io.StringIO()):
            record = soak.sample("self")
        self.assertGreater(record["fds"], 0)
        self.assertEqual(record["fds"], sum(record["types"].values()))
        self.assertIsInstance(record["descendants"], list)


class _Clock:
    """Advances only when the probe sleeps, so settle tests do not wait out SETTLE."""

    def __init__(self, start=1000.0):
        self.now = start

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ScriptedCensusSoak(probe.Soak):
    """`sample()` returns canned censuses; no lsof, no socket."""

    def __init__(self, script, cycle=False):
        super().__init__("/nonesuch.sock", "/tmp", os.getpid(), "/tmp", "/tmp")
        self.script = list(script)
        self.cycle = cycle
        self.index = 0

    def sample(self, label, extra=None):
        if self.cycle:
            record = dict(self.script[self.index % len(self.script)])
        else:
            record = dict(self.script[self.index])
        self.index += 1
        record["label"] = label
        record["types"] = dict(record.get("types") or {})
        if extra:
            record.update(extra)
        return record


class SettleAgreementTests(unittest.TestCase):
    def setUp(self):
        self.clock = _Clock()
        self._time = probe.time.time
        self._sleep = probe.time.sleep
        probe.time.time = self.clock.time
        probe.time.sleep = self.clock.sleep

    def tearDown(self):
        probe.time.time = self._time
        probe.time.sleep = self._sleep

    def test_falling_unix_with_a_flat_fd_total_is_not_a_stable_census(self):
        # Same numeric FD total, descendants unchanged, unix still dropping:
        # the first live Fail 1 shape. Agreement on fds+descendants alone
        # would freeze that as a plateau.
        soak = ScriptedCensusSoak([
            sample("warm", 90, unix=9),
            sample("warm", 90, unix=2),
        ], cycle=True)
        with redirect_stdout(io.StringIO()):
            result = soak.settle_baseline("warm")
        self.assertIs(False, result.get("stable"))
        self.assertGreater(soak.index, 2)

    def test_matching_fds_descendants_and_unix_settle_as_stable(self):
        soak = ScriptedCensusSoak([
            sample("warm", 52, unix=2),
            sample("warm", 52, unix=2),
        ])
        with redirect_stdout(io.StringIO()):
            result = soak.settle_baseline("warm")
        self.assertIs(True, result.get("stable"))
        self.assertEqual(2, result["types"]["unix"])
        self.assertEqual(2, soak.index)

    def test_oscillating_unix_never_sets_stable_true(self):
        soak = ScriptedCensusSoak([
            sample("batch", 97, unix=9),
            sample("batch", 97, unix=2),
        ], cycle=True)
        with redirect_stdout(io.StringIO()):
            result = soak.settle_baseline("batch 40")
        self.assertIs(False, result.get("stable"))


class SplitCloseHarness(probe.Soak):
    """split/close without a socket: every round succeeds, censuses are canned."""

    def __init__(self):
        super().__init__("/nonesuch.sock", "/tmp", os.getpid(), "/tmp", "/tmp")
        self.check_names = []
        self.check_results = []

    def check(self, name, condition, detail=""):
        self.check_names.append(name)
        self.check_results.append((name, bool(condition)))
        return super().check(name, condition, detail)

    def settle_baseline(self, label):
        return sample(label, 50, unix=2)

    def request(self, token, verb, args=None):
        if verb == "split":
            return {"ok": True, "result": {"pane": "NEW-PANE"}}
        return {"ok": True}

    def await_panes(self, token, count):
        if count == 2:
            return [probe.ALPHA, "NEW-PANE"]
        return [probe.ALPHA]

    def await_token(self, pane, limit=probe.SETTLE):
        return "child-token"

    def sample(self, label, extra=None):
        return sample(label, 50, unix=2)


class SplitCloseWarmupTests(unittest.TestCase):
    def test_one_round_warmup_skips_tautological_plateau_checks(self):
        soak = SplitCloseHarness()
        with redirect_stdout(io.StringIO()) as buf:
            soak.split_close("alpha", 1)
        self.assertFalse(any("descriptors do not grow" in name for name in soak.check_names),
                         soak.check_names)
        self.assertFalse(any("plateau low" in name for name in soak.check_names), soak.check_names)
        self.assertTrue(any("no descendant survives" in name for name in soak.check_names),
                        soak.check_names)
        self.assertIn("warmup", buf.getvalue().lower())

    def test_one_round_warmup_is_recorded_separately_from_a_full_soak(self):
        soak = SplitCloseHarness()
        soak.report["splitClose"] = {"rounds": 24, "samples": [{"label": "round 6", "fds": 50}]}
        with redirect_stdout(io.StringIO()):
            soak.split_close("alpha", 1)
        self.assertEqual(24, soak.report["splitClose"]["rounds"])
        self.assertEqual("round 6", soak.report["splitClose"]["samples"][0]["label"])
        self.assertTrue(soak.report["splitCloseWarmup"]["warmup"])
        self.assertEqual(1, soak.report["splitCloseWarmup"]["rounds"])

    def test_six_rounds_still_grade_plateau_growth(self):
        soak = SplitCloseHarness()
        soak.sample = lambda label, extra=None: sample(label, 60, unix=2)
        with redirect_stdout(io.StringIO()):
            soak.split_close("alpha", 6)
        self.assertTrue(any("descriptors do not grow" in name for name in soak.check_names),
                        soak.check_names)
        self.assertIn("splitClose", soak.report)
        self.assertNotIn("warmup", soak.report.get("splitClose", {}))
        self.assertTrue(
            any(not ok for name, ok in soak.check_results if "descriptors do not grow" in name),
            soak.check_results,
        )


class SubscribeWarmupSkipTests(unittest.TestCase):
    def _subscribe_soak(self, report):
        soak = probe.Soak("/nonesuch.sock", "/tmp", os.getpid(), "/tmp", "/tmp")
        soak.report.update(report)
        soak.split_calls = []
        soak.split_close = lambda token, rounds: soak.split_calls.append((token, rounds))
        soak.request = lambda *a, **k: {"ok": True}
        soak.run_batch = lambda number, mode, tokens, wait: {
            "batch": number, "mode": mode, "parked": 8, "early": [],
            "latency": 0.01, "served": True, "answered": 8, "empty": 8, "slowest": wait,
        }
        soak.settle_baseline = lambda label: sample(label, 52, unix=2)
        soak.postchurn_event = lambda tokens: {"cursor": 1, "born": "P", "woken": {}}
        soak.control_arm = lambda tokens, warm, wait: {}
        soak.grade = lambda results: []
        return soak

    def test_subscribe_churn_skips_warmup_when_a_full_split_close_already_ran(self):
        soak = self._subscribe_soak({"splitClose": {"rounds": 24, "samples": []}})
        tokens = {pane: "t" for pane in [probe.ALPHA] + probe.SCRATCH}
        with redirect_stdout(io.StringIO()):
            soak.subscribe_churn(tokens, 1, 1)
        self.assertEqual([], soak.split_calls)

    def test_subscribe_churn_pays_one_warmup_split_when_no_prior_soak(self):
        soak = self._subscribe_soak({})
        tokens = {pane: "t" for pane in [probe.ALPHA] + probe.SCRATCH}
        with redirect_stdout(io.StringIO()):
            soak.subscribe_churn(tokens, 1, 1)
        self.assertEqual([(tokens[probe.ALPHA], 1)], soak.split_calls)


if __name__ == "__main__":
    unittest.main()
