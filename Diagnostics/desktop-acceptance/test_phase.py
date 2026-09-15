#!/usr/bin/env python3
"""No-app checks for the desktop-acceptance phase helper and recorder.

Nothing here builds or launches baia. The fixture identity is a temporary
tree, the "copied app" is a shell script that presents its own path as its
command, and the runner is a thread answering the request file.
"""

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import pty
import shutil
import signal
import stat
import subprocess
import tempfile
import termios
import threading
import time
import unittest
import uuid

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("desktop_acceptance_phase", HERE / "phase.py")
PHASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PHASE)
RECORDER = HERE / "recorder.py"
PYTHON = "/usr/bin/python3"


def walk(root):
    found = set()
    for base, dirs, files in os.walk(root):
        for name in dirs + files:
            found.add(os.path.join(base, name))
    return found


class ReadinessScopeTests(unittest.TestCase):
    def test_seeded_siblings_are_checked_with_their_own_capabilities(self):
        from unittest.mock import patch
        class ScopedProbe:
            def tokens(self):
                return {"P1": "t1", "P2": "t2"}
            def request(self, token, verb):
                pane = {"t1": "P1", "t2": "P2"}[token]
                return {"ok": True, "result": {"panes": [{"pane": pane}]}}
            def code(self, reply):
                return "ok" if reply.get("ok") else "failed"
            def named_panes(self, reply):
                return [p["pane"] for p in reply["result"]["panes"]]
        with tempfile.NamedTemporaryFile() as channel:
            state = {"pid": 1234, "binary": "/fixture", "socket": channel.name}
            windows = [{"onscreen": True, "layer": 0, "bounds": {"Height": 400}}]
            with patch.object(PHASE, "require_same_process", return_value=1234), \
                 patch.object(PHASE, "process_command", return_value="/fixture"), \
                 patch.object(PHASE, "make_probe", return_value=ScopedProbe()), \
                 patch.object(PHASE, "window_census", return_value=windows):
                result = None
                try:
                    result = PHASE.await_ready(state, ["P1", "P2"], seconds=0.05)
                except PHASE.FixtureError:
                    pass
                self.assertIsNotNone(result, "self-only replies must prove each seeded sibling ready")
                self.assertEqual(["P1", "P2"], result["listedPanes"])

    def test_process_window_readiness_needs_exact_binary_and_visible_window(self):
        from unittest.mock import patch
        state = {"pid": 1234, "binary": "/fixture"}
        visible = [{"onscreen": True, "layer": 0, "bounds": {"Height": 400}}]
        with patch.object(PHASE, "require_same_process", return_value=1234), \
             patch.object(PHASE, "process_command", return_value="/fixture"), \
             patch.object(PHASE, "window_census", return_value=visible):
            result = PHASE.await_process_window_ready(state, seconds=0.05)
        self.assertEqual(1234, result["pid"])
        self.assertEqual(visible, result["windows"])

        with patch.object(PHASE, "require_same_process", return_value=1234), \
             patch.object(PHASE, "process_command", return_value="/other"), \
             patch.object(PHASE, "window_census", return_value=visible):
            with self.assertRaises(PHASE.FixtureError):
                PHASE.await_process_window_ready(state, seconds=0.05)

        with patch.object(PHASE, "require_same_process", return_value=1234), \
             patch.object(PHASE, "window_census", return_value=[]):
            with self.assertRaises(PHASE.FixtureError) as caught:
                PHASE.await_process_window_ready(state, seconds=0.01)
        self.assertIn("visible window", str(caught.exception))


class Fixture:
    """A fake owned fixture tree with the same shape run.sh produces."""

    def __init__(self):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="baia-desktop-acceptance-test."))
        self.run_id = str(uuid.uuid4()).upper()
        self.evidence_root = os.path.join(self.root, "acceptance")
        self.evidence = os.path.join(self.evidence_root, self.run_id)
        self.scratch = os.path.join(self.root, "baia-desktop-acceptance.abc123")
        self.support = os.path.join(self.root, "Application Support", "baia-desktop-acceptance.xyz789")
        self.app = os.path.join(self.scratch, "desktop-acceptance.app")
        self.binary = os.path.join(self.app, "Contents", "MacOS", "baia-desktop-acceptance-abc123")
        self.normal = os.path.join(self.root, "normal")
        for path in (self.evidence, self.scratch, self.support, os.path.dirname(self.binary), self.normal):
            os.makedirs(path, mode=0o700)
        self.fifo = os.path.join(self.scratch, "hold.fifo")
        os.mkfifo(self.fifo, 0o600)
        with open(self.binary, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/bash\nexec 3<>"%s"\nexec -a "$0" /bin/cat <&3 >/dev/null\n' % self.fifo)
        os.chmod(self.binary, 0o700)
        self.process = None
        present = os.path.join(self.normal, "config.json")
        with open(present, "w", encoding="utf-8") as handle:
            handle.write('{"normal": true}\n')
        self.normal_paths = [present, os.path.join(self.normal, "session.json")]
        self.fingerprints = os.path.join(self.evidence, "normal-state-before.%s.tsv" % self.run_id)
        with open(self.fingerprints, "w", encoding="utf-8") as handle:
            handle.write("\n".join(PHASE.fingerprint_lines(self.normal_paths)) + "\n")
        self.state_path = pathlib.Path(self.evidence) / "fixture.json"
        self.state = {
            "version": 1,
            "runId": self.run_id,
            "repoRoot": self.root,
            "gitRevision": "0123456789abcdef0123456789abcdef01234567",
            "gitDirty": 0,
            "sourceBinarySha256": "source-sha",
            "app": self.app,
            "binary": self.binary,
            "binarySha256": PHASE.sha256_of(self.binary),
            "bundleId": "pasqualotto.baia.desktop-acceptance.TEST",
            "pid": None,
            "batches": 0,
            "scratch": self.scratch,
            "support": self.support,
            "session": os.path.join(self.support, "session.json"),
            "socket": os.path.join(self.support, "control.sock"),
            "config": os.path.join(self.scratch, "config.json"),
            "zdot": os.path.join(self.scratch, "zdot"),
            "tokenDir": os.path.join(self.scratch, "tokens"),
            "jobsDir": os.path.join(self.scratch, "jobs"),
            "projectsDir": os.path.join(self.scratch, "projects"),
            "evidenceRoot": self.evidence_root,
            "evidence": self.evidence,
            "ledger": os.path.join(self.evidence, "ledger.json"),
            "fingerprintsBefore": self.fingerprints,
            "stopMarker": os.path.join(self.scratch, "coordinator-stop"),
            "runnerRequest": os.path.join(self.scratch, "runner-request.json"),
            "runnerResult": os.path.join(self.scratch, "runner-result.json"),
            "controlProbe": os.path.join(self.root, "probe.py"),
            "recorder": str(RECORDER),
            "batchSeconds": 900,
            "maxSeconds": 10800,
            "startedAt": time.time(),
            "deadlineAt": time.time() + 900,
            "nextSequence": 1,
            "scenario": None,
        }
        for key in ("zdot", "tokenDir", "jobsDir", "projectsDir"):
            os.makedirs(self.state[key], mode=0o700, exist_ok=True)
        self.save()

    def save(self):
        PHASE.atomic_json(self.state_path, self.state)

    def launch(self):
        """Start the fake copied binary so ps reports exactly state.binary."""
        self.process = subprocess.Popen([self.binary], stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if PHASE.process_command(self.process.pid) == self.binary:
                break
            time.sleep(0.05)
        self.state["pid"] = self.process.pid
        self.save()
        return self.process.pid

    def prepared(self, scenario="accessibility", arm="default", batch=1):
        self.state["scenario"] = {"scenario": scenario, "arm": arm, "batch": batch,
                                  "panes": ["PANE-A"], "projects": [], "files": []}
        self.save()

    def evidence_file(self, name, content=b"evidence bytes\n"):
        path = os.path.join(self.evidence, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(content)
        return path

    def result(self, **overrides):
        shot = self.evidence_file("captures/a01-palette.png", b"\x89PNG fake\n")
        document = {
            "version": 1,
            "case": "A01",
            "result": "PASS",
            "fixtureRunId": self.state["runId"],
            "pid": self.state["pid"],
            "binarySha256": self.state["binarySha256"],
            "gitRevision": self.state["gitRevision"],
            "scenario": "accessibility",
            "setup": "seeded alpha.txt and folder/beta.txt",
            "expected": "palette lists alpha and beta; VO speaks the selected name",
            "observed": "VO caption read 'beta.txt'; Files selected beta",
            "actions": [{"at": time.time(), "action": "opened palette with Cmd-P"}],
            "verifiedBy": ["caption", "ui-readback"],
            "evidence": [{"path": shot, "kind": "screenshot",
                          "judgment": "beta.txt row highlighted, caption panel shows beta.txt"}],
            "restoration": {"required": True, "verified": True, "readback": "VoiceOver off in System Settings"},
            "cleanup": "no scratch changes beyond seeded files",
        }
        document.update(overrides)
        return document

    def write_result(self, document, name="results/a01.json"):
        path = os.path.join(self.evidence, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        PHASE.atomic_json(path, document)
        return path

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        for base, dirs, _files in os.walk(self.root):
            for name in dirs:
                os.chmod(os.path.join(base, name), 0o700)
        shutil.rmtree(self.root, ignore_errors=True)


def run_cli(*argv):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = PHASE.main(list(argv))
    return status, out.getvalue(), err.getvalue()


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)


class OwnershipTests(FixtureCase):
    def refused(self, mutate, message):
        state = json.loads(json.dumps(self.fixture.state))
        mutate(state)
        with self.assertRaises(PHASE.FixtureError, msg=message) as caught:
            PHASE.require_state_ownership(state, self.fixture.state_path)
        return str(caught.exception)

    def test_valid_state_is_accepted(self):
        PHASE.require_state_ownership(self.fixture.state, self.fixture.state_path)

    def test_stop_marker_outside_scratch_is_refused(self):
        foreign = os.path.join(self.fixture.root, "coordinator-stop")
        self.refused(lambda s: s.update(stopMarker=foreign), "foreign stop marker")

    def test_stop_marker_with_another_name_is_refused(self):
        self.refused(lambda s: s.update(stopMarker=os.path.join(self.fixture.scratch, "stop")),
                     "stop marker name")

    def test_stop_marker_symlink_escape_is_refused(self):
        outside = os.path.join(self.fixture.root, "escape")
        os.makedirs(outside)
        link = os.path.join(self.fixture.scratch, "link")
        os.symlink(outside, link)
        self.refused(lambda s: s.update(stopMarker=os.path.join(link, "coordinator-stop")),
                     "symlink escape")

    def test_state_file_outside_evidence_is_refused(self):
        foreign = pathlib.Path(self.fixture.root) / "fixture.json"
        PHASE.atomic_json(foreign, self.fixture.state)
        with self.assertRaises(PHASE.FixtureError):
            PHASE.require_state_ownership(PHASE.read_json(foreign), foreign)

    def test_evidence_outside_root_is_refused(self):
        self.refused(lambda s: s.update(evidence=self.fixture.root), "evidence root")

    def test_session_outside_support_is_refused(self):
        self.refused(lambda s: s.update(session=os.path.join(self.fixture.scratch, "session.json")),
                     "session location")

    def test_product_support_directory_is_refused(self):
        product = os.path.join(self.fixture.root, "Application Support", "baia")
        os.makedirs(product)
        self.refused(lambda s: s.update(support=product, session=os.path.join(product, "session.json"),
                                        socket=os.path.join(product, "control.sock")),
                     "product support")

    def test_binary_outside_app_is_refused(self):
        self.refused(lambda s: s.update(binary="/bin/cat"), "foreign binary")

    def test_request_files_outside_scratch_are_refused(self):
        self.refused(lambda s: s.update(runnerRequest=os.path.join(self.fixture.root, "runner-request.json")),
                     "foreign request file")

    def test_stop_touches_only_the_owned_marker(self):
        status, out, err = run_cli("--state", str(self.fixture.state_path), "stop")
        self.assertEqual(0, status, err)
        self.assertTrue(os.path.exists(self.fixture.state["stopMarker"]))
        self.assertEqual(stat.S_IMODE(os.stat(self.fixture.state["stopMarker"]).st_mode), 0o600)
        observation = json.loads(out)
        self.assertEqual("stop", observation["action"])
        self.assertIsNone(observation["sameProcessAtStop"])
        ledger = PHASE.read_json(self.fixture.state["ledger"])
        self.assertEqual("stop", ledger["events"][-1]["action"])

    def test_cli_refuses_a_state_whose_stop_marker_is_foreign(self):
        self.fixture.state["stopMarker"] = os.path.join(self.fixture.root, "coordinator-stop")
        self.fixture.save()
        status, _out, err = run_cli("--state", str(self.fixture.state_path), "stop")
        self.assertEqual(1, status)
        self.assertIn("not inside its owner", err)
        self.assertFalse(os.path.exists(self.fixture.state["stopMarker"]))


class ProcessIdentityTests(FixtureCase):
    def test_pid_of_another_command_is_not_the_fixture(self):
        self.fixture.state["pid"] = 1
        with self.assertRaises(PHASE.FixtureError):
            PHASE.require_same_process(self.fixture.state)

    def test_dead_pid_is_not_the_fixture(self):
        pid = self.fixture.launch()
        self.fixture.process.kill()
        self.fixture.process.wait()
        self.assertFalse(PHASE.same_process(self.fixture.state))
        with self.assertRaises(PHASE.FixtureError):
            PHASE.require_same_process(dict(self.fixture.state, pid=pid))

    def test_live_fake_binary_is_the_fixture(self):
        self.fixture.launch()
        self.assertTrue(PHASE.same_process(self.fixture.state))


class RecordGradingTests(FixtureCase):
    def setUp(self):
        super().setUp()
        self.fixture.launch()
        self.fixture.prepared()

    def record(self, document, case="A01", name="results/a01.json"):
        path = self.fixture.write_result(document, name)
        return run_cli("--state", str(self.fixture.state_path), "record", "--case", case,
                       "--result-file", path)

    def ledger_cases(self):
        ledger = self.fixture.state["ledger"]
        return PHASE.read_json(ledger)["cases"] if os.path.exists(ledger) else {}

    def assert_refused(self, document, needle, case="A01", name="results/a01.json"):
        before = self.ledger_cases()
        status, _out, err = self.record(document, case=case, name=name)
        self.assertEqual(1, status, "expected refusal for %s" % needle)
        self.assertIn(needle, err)
        self.assertEqual(before, self.ledger_cases(), "a refused record must not enter the ledger")

    def test_complete_pass_is_accepted_into_the_ledger(self):
        status, out, err = self.record(self.fixture.result())
        self.assertEqual(0, status, err)
        observation = json.loads(out)
        self.assertEqual("PASS", observation["result"])
        ledger = PHASE.read_json(self.fixture.state["ledger"])
        latest = ledger["cases"]["A01"]["latest"]
        self.assertEqual(self.fixture.state["pid"], latest["pid"])
        self.assertEqual(self.fixture.state["binarySha256"], latest["binarySha256"])
        self.assertTrue(latest["normalState"]["unchanged"])
        self.assertEqual(1, len(latest["evidence"]))
        self.assertEqual(64, len(latest["evidence"][0]["sha256"]))
        self.assertEqual([self.fixture.run_id], [run["runId"] for run in ledger["fixtureRuns"]])

    def test_wrong_pid_is_refused(self):
        self.assert_refused(self.fixture.result(pid=self.fixture.state["pid"] + 1), "not the live fixture pid")

    def test_wrong_binary_hash_is_refused(self):
        self.assert_refused(self.fixture.result(binarySha256="0" * 64), "binary SHA-256")

    def test_wrong_git_revision_is_refused(self):
        self.assert_refused(self.fixture.result(gitRevision="deadbeef"), "git revision")

    def test_wrong_fixture_run_id_is_refused(self):
        self.assert_refused(self.fixture.result(fixtureRunId=str(uuid.uuid4())), "another fixture run id")

    def test_wrong_scenario_is_refused(self):
        self.assert_refused(self.fixture.result(scenario="recovery"), "not the prepared scenario")

    def test_case_mismatch_is_refused(self):
        self.assert_refused(self.fixture.result(case="A02"), "does not match --case")

    def test_result_file_outside_evidence_is_refused(self):
        foreign = os.path.join(self.fixture.root, "a01.json")
        PHASE.atomic_json(foreign, self.fixture.result())
        status, _out, err = run_cli("--state", str(self.fixture.state_path), "record",
                                    "--case", "A01", "--result-file", foreign)
        self.assertEqual(1, status)
        self.assertIn("result file is not inside its owner", err)

    def test_result_file_symlink_escape_is_refused(self):
        foreign = os.path.join(self.fixture.root, "a01.json")
        PHASE.atomic_json(foreign, self.fixture.result())
        link = os.path.join(self.fixture.evidence, "results", "linked.json")
        os.makedirs(os.path.dirname(link), exist_ok=True)
        os.symlink(foreign, link)
        status, _out, err = run_cli("--state", str(self.fixture.state_path), "record",
                                    "--case", "A01", "--result-file", link)
        self.assertEqual(1, status)
        self.assertIn("not inside its owner", err)

    def test_pass_without_evidence_is_refused(self):
        self.assert_refused(self.fixture.result(evidence=[]), "at least one evidence file")

    def test_pass_with_evidence_outside_the_run_is_refused(self):
        foreign = os.path.join(self.fixture.root, "shot.png")
        with open(foreign, "wb") as handle:
            handle.write(b"png\n")
        self.assert_refused(self.fixture.result(evidence=[
            {"path": foreign, "kind": "screenshot", "judgment": "looks fine"}]), "evidence path is not inside")

    def test_pass_with_missing_evidence_file_is_refused(self):
        missing = os.path.join(self.fixture.evidence, "captures", "missing.png")
        self.assert_refused(self.fixture.result(evidence=[
            {"path": missing, "kind": "screenshot", "judgment": "x"}]), "not a regular file")

    def test_pass_with_empty_evidence_file_is_refused(self):
        empty = self.fixture.evidence_file("captures/empty.png", b"")
        self.assert_refused(self.fixture.result(evidence=[
            {"path": empty, "kind": "screenshot", "judgment": "x"}]), "evidence file is empty")

    def test_screenshot_without_a_judgment_is_refused(self):
        shot = self.fixture.evidence_file("captures/no-judgment.png", b"png\n")
        self.assert_refused(self.fixture.result(evidence=[
            {"path": shot, "kind": "screenshot"}]), "filename is not proof")

    def test_pass_inferred_only_from_input_delivery_is_refused(self):
        self.assert_refused(self.fixture.result(verifiedBy=["input-delivered", "api-success"]),
                            "not only by input delivery")

    def test_unknown_verification_word_is_refused(self):
        self.assert_refused(self.fixture.result(verifiedBy=["looked-fine"]), "unknown verifiedBy")

    def test_pass_with_unverified_restoration_is_refused(self):
        self.assert_refused(self.fixture.result(restoration={"required": True, "verified": False}),
                            "verified restoration")

    def test_pass_without_timestamped_actions_is_refused(self):
        self.assert_refused(self.fixture.result(actions=[{"action": "clicked"}]), "numeric `at`")

    def test_blocked_without_missing_capability_is_refused(self):
        self.assert_refused(self.fixture.result(result="BLOCKED", missingCapability=""),
                            "exact missing capability")

    def test_blocked_with_a_named_capability_is_accepted(self):
        status, out, err = self.record(self.fixture.result(
            result="BLOCKED", missingCapability="neither provider can read VoiceOver captions",
            evidence=[]))
        self.assertEqual(0, status, err)
        self.assertEqual("BLOCKED", json.loads(out)["result"])

    def test_capability_like_keys_never_enter_the_ledger(self):
        self.assert_refused(self.fixture.result(wire={"token": "abc"}), "capability-like key")

    def test_pass_after_normal_state_changed_is_refused(self):
        with open(self.fixture.normal_paths[0], "w", encoding="utf-8") as handle:
            handle.write('{"normal": "changed"}\n')
        self.assert_refused(self.fixture.result(), "normal state changed")

    def test_pass_when_the_process_died_is_refused(self):
        self.fixture.process.kill()
        self.fixture.process.wait()
        self.assert_refused(self.fixture.result(), "not the recorded copied binary at record time")

    def test_the_ledger_itself_is_not_evidence(self):
        status, _out, _err = self.record(self.fixture.result())
        self.assertEqual(0, status)
        self.assert_refused(self.fixture.result(evidence=[
            {"path": self.fixture.state["ledger"], "kind": "log"}]), "ledger is not evidence")

    def test_ledger_keeps_history_across_fixture_runs(self):
        status, _out, err = self.record(self.fixture.result())
        self.assertEqual(0, status, err)
        # A restarted runner: new run id, same evidence directory and ledger.
        self.fixture.state["runId"] = str(uuid.uuid4()).upper()
        self.fixture.state["previousRunId"] = self.fixture.run_id
        self.fixture.save()
        status, _out, err = self.record(self.fixture.result(
            fixtureRunId=self.fixture.state["runId"], result="FAIL",
            observed="beta was not selected"), name="results/a01-second.json")
        self.assertEqual(0, status, err)
        ledger = PHASE.read_json(self.fixture.state["ledger"])
        self.assertEqual(2, len(ledger["cases"]["A01"]["history"]))
        self.assertEqual("FAIL", ledger["cases"]["A01"]["latest"]["result"])
        self.assertEqual(2, len(ledger["fixtureRuns"]))


class ReportTests(FixtureCase):
    def test_report_prints_identity_without_capabilities(self):
        secret = "capability-" + uuid.uuid4().hex
        token_file = os.path.join(self.fixture.state["tokenDir"], "pane-PANE-A.env")
        with open(token_file, "w", encoding="utf-8") as handle:
            handle.write("pane=PANE-A\ntoken=%s\n" % secret)
        self.fixture.launch()
        self.fixture.prepared()
        status, out, err = run_cli("--state", str(self.fixture.state_path), "report")
        self.assertEqual(0, status, err)
        self.assertNotIn(secret, out)
        report = json.loads(out)
        self.assertNotIn("tokenDir", report)
        self.assertEqual(self.fixture.state["pid"], report["pid"])
        self.assertTrue(report["sameProcess"])
        self.assertEqual(self.fixture.state["binarySha256"], report["binarySha256"])
        self.assertTrue(report["normalState"]["unchanged"])
        self.assertEqual("accessibility", report["scenario"]["scenario"])

    def test_report_lists_recorded_jobs_and_their_liveness(self):
        sleeper = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(lambda: (sleeper.kill(), sleeper.wait()))
        other = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(lambda: (other.kill(), other.wait()))
        started = PHASE.process_start(sleeper.pid)
        jobs = self.fixture.state["jobsDir"]
        with open(os.path.join(jobs, "sleep-1.job"), "w") as handle:
            handle.write("pid=%d\nstarted=%s\nshell=1\npane=PANE-A\n" % (sleeper.pid, started))
        # A reused pid: the recorded start time is not the live one.
        with open(os.path.join(jobs, "sleep-2.job"), "w") as handle:
            handle.write("pid=%d\nstarted=Thu Jan  1 00:00:00 2026\nshell=2\npane=PANE-A\n" % other.pid)
        with open(os.path.join(jobs, "sleep-3.job"), "w") as handle:
            handle.write("pid=999999\nstarted=%s\n" % started)
        census = PHASE.jobs_census(self.fixture.state)
        self.assertEqual([True, False, False], [job["alive"] for job in census])
        self.assertEqual("PANE-A", census[0]["pane"])

    def test_busy_hook_records_the_start_identity_of_its_job(self):
        text = PHASE.busy_zshrc_text("/scratch", "/scratch/jobs")
        self.assertIn("lstart=", text)
        self.assertIn('"$!"', text)
        self.assertIn("/scratch/jobs/sleep-$$.job", text)
        self.assertIn("fg %1", text)


class AttentionTests(FixtureCase):
    def idle_observation(self, seen, attention):
        from unittest.mock import patch

        class Probe:
            sequence = None

            def tokens(self):
                return {"PANE-A": "token"}

            def request(self, _token, verb, payload=None):
                if verb == "report":
                    self.sequence = payload["seq"]
                    return {"ok": True}
                if verb == "list":
                    return {"ok": True, "result": {"panes": [
                        {"pane": "PANE-A", "attention": attention},
                    ]}}
                return {"ok": True, "result": {"explanation": {
                    "seen": seen, "report": {"seq": self.sequence},
                }}}

            def code(self, response):
                return "ok" if response.get("ok") else "failed"

            def record_of(self, response, pane):
                return next(record for record in response["result"]["panes"]
                            if record["pane"] == pane)

        def settle(read, accepts, **_kwargs):
            value = read()
            if not accepts(value):
                raise PHASE.FixtureError("attention did not settle")
            return value

        self.fixture.prepared()
        with patch.object(PHASE, "require_same_process", return_value=1234), \
             patch.object(PHASE, "make_probe", return_value=Probe()), \
             patch.object(PHASE, "monotonic_wait", side_effect=settle):
            return PHASE.phase_attention(
                self.fixture.state, self.fixture.state_path, "PANE-A", "idle", "finished", False)

    def test_idle_unseen_accepts_done(self):
        observation = self.idle_observation(seen=False, attention="done")
        self.assertEqual("done", observation["effectiveAttention"])

    def test_idle_seen_accepts_no_attention(self):
        observation = self.idle_observation(seen=True, attention=None)
        self.assertIsNone(observation["effectiveAttention"])


class ScenarioTests(FixtureCase):
    def test_every_scenario_and_arm_builds_a_schema_two_document(self):
        for scenario in PHASE.SCENARIOS:
            for arm in PHASE.ARMS[scenario]:
                prepared = PHASE.build_scenario(self.fixture.state, scenario, arm)
                self.assertEqual(arm, prepared["arm"])
                if prepared["session"] is not None:
                    self.assertEqual(2, prepared["session"]["schemaVersion"])
                    listed = {pane["id"]["rawValue"] for pane in prepared["session"]["panes"]}
                    self.assertEqual(set(prepared["panes"]), listed)
                for path in prepared["projects"] + list(prepared["files"]):
                    self.assertTrue(PHASE.realpath_within(path, self.fixture.scratch), path)
                self.assertNotIn("~", json.dumps(prepared["config"]))

    def test_unknown_scenario_and_arm_are_refused(self):
        with self.assertRaises(PHASE.FixtureError):
            PHASE.build_scenario(self.fixture.state, "wallpaper", None)
        with self.assertRaises(PHASE.FixtureError):
            PHASE.build_scenario(self.fixture.state, "settings", "wallpaper")

    def test_accessibility_seeds_alpha_and_beta(self):
        prepared = PHASE.build_scenario(self.fixture.state, "accessibility", None)
        names = sorted(os.path.relpath(path, prepared["projects"][0]) for path in prepared["files"])
        self.assertEqual(["alpha.txt", "folder/beta.txt"], names)
        self.assertEqual("files", prepared["config"]["sidebar"])

    def test_windows_seeds_two_groups_with_two_tabs_each(self):
        prepared = PHASE.build_scenario(self.fixture.state, "windows", None)
        groups = prepared["session"]["groups"]
        self.assertEqual([2, 2], [len(group["tabs"]) for group in groups])
        self.assertEqual(4, len(prepared["panes"]))
        self.assertEqual(groups[0]["id"], prepared["session"]["activeGroup"])

    def test_commands_empty_root_has_no_project_roots(self):
        prepared = PHASE.build_scenario(self.fixture.state, "commands", "empty-root")
        self.assertEqual([], prepared["config"]["projectRoots"])
        default = PHASE.build_scenario(self.fixture.state, "commands", None)
        self.assertEqual(2, len(default["session"]["groups"]))

    def test_settings_wrong_type_keeps_the_valid_sibling(self):
        prepared = PHASE.build_scenario(self.fixture.state, "settings", "wrong-type")
        self.assertEqual("big", prepared["config"]["fontSize"])
        self.assertEqual(24, prepared["config"]["windowPadding"])
        long_root = PHASE.build_scenario(self.fixture.state, "settings", "long-root")
        self.assertGreater(len(long_root["projects"][0]), 160)

    def test_seeding_writes_only_inside_scratch_and_support(self):
        before = walk(self.fixture.root)
        prepared = PHASE.build_scenario(self.fixture.state, "busy-close", "busy")
        PHASE.seed_scenario(self.fixture.state, prepared)
        created = walk(self.fixture.root) - before
        self.assertTrue(created)
        for path in created:
            self.assertTrue(
                PHASE.realpath_within(path, self.fixture.scratch)
                or PHASE.realpath_within(path, self.fixture.support), path)
        self.assertTrue(os.path.exists(os.path.join(self.fixture.scratch, "arm-busy")))
        self.assertTrue(os.path.exists(os.path.join(self.fixture.state["zdot"], ".zshrc")))
        # The idle arm keeps the job hook but disarms it; another scenario
        # removes the hook entirely.
        idle = PHASE.build_scenario(self.fixture.state, "busy-close", "idle")
        PHASE.seed_scenario(self.fixture.state, idle)
        self.assertFalse(os.path.exists(os.path.join(self.fixture.scratch, "arm-busy")))
        self.assertTrue(os.path.exists(os.path.join(self.fixture.state["zdot"], ".zshrc")))
        PHASE.seed_scenario(self.fixture.state, PHASE.build_scenario(self.fixture.state, "input", None))
        self.assertFalse(os.path.exists(os.path.join(self.fixture.state["zdot"], ".zshrc")))

    def test_accessibility_seeds_repository_for_prompt_insertion(self):
        prepared = PHASE.build_scenario(self.fixture.state, "accessibility", None)
        PHASE.seed_scenario(self.fixture.state, prepared)
        root = pathlib.Path(prepared["projects"][0])
        self.assertTrue((root / ".git").is_dir())
        result = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                                capture_output=True, text=True, check=True)
        self.assertEqual(root.resolve(), pathlib.Path(result.stdout.strip()).resolve())

    def test_feedback_arm_seeds_a_real_control_character_filename(self):
        prepared = PHASE.build_scenario(self.fixture.state, "accessibility", "feedback")
        PHASE.seed_scenario(self.fixture.state, prepared)
        root = pathlib.Path(prepared["projects"][0])
        self.assertTrue((root / "refuse\x01.txt").is_file())

    def test_recovery_seeds_exact_malformed_bytes_and_refused_writes(self):
        prepared = PHASE.build_scenario(self.fixture.state, "recovery", "malformed-write-refused")
        hashes = PHASE.seed_scenario(self.fixture.state, prepared)
        with open(self.fixture.state["session"], "rb") as handle:
            self.assertEqual(PHASE.MALFORMED_SESSION, handle.read())
        self.assertEqual(PHASE.sha256_of(self.fixture.state["session"]), hashes["session"])
        self.assertEqual(0o500, stat.S_IMODE(os.stat(self.fixture.support).st_mode))
        self.assertEqual(0o400, stat.S_IMODE(os.stat(self.fixture.state["session"]).st_mode))
        repaired = PHASE.repair_permissions(self.fixture.state)
        self.assertIn(self.fixture.support, repaired)
        self.assertEqual(0o700, stat.S_IMODE(os.stat(self.fixture.support).st_mode))
        summary = PHASE.scenario_summary(prepared, hashes)
        self.assertEqual(PHASE.MALFORMED_SESSION.hex(), summary["sessionBytesHex"])
        self.assertEqual("0o500", summary["support"]["mode"])

    def test_seeding_clears_stale_capability_reports_and_jobs(self):
        stale_token = os.path.join(self.fixture.state["tokenDir"], "pane-OLD.env")
        stale_job = os.path.join(self.fixture.state["jobsDir"], "sleep-1.job")
        for path in (stale_token, stale_job):
            with open(path, "w") as handle:
                handle.write("x\n")
        PHASE.seed_scenario(self.fixture.state, PHASE.build_scenario(self.fixture.state, "input", None))
        self.assertFalse(os.path.exists(stale_token))
        self.assertFalse(os.path.exists(stale_job))


class RunnerProtocolTests(FixtureCase):
    def responder(self, handler):
        state = self.fixture.state
        stop = threading.Event()

        def loop():
            while not stop.is_set():
                if os.path.exists(state["runnerRequest"]):
                    try:
                        request = PHASE.read_json(state["runnerRequest"])
                    except (OSError, ValueError):
                        time.sleep(0.02)
                        continue
                    result = handler(request)
                    if result is not None:
                        PHASE.atomic_json(state["runnerResult"], result)
                    os.unlink(state["runnerRequest"])
                time.sleep(0.02)

        thread = threading.Thread(target=loop, daemon=True)
        thread.start()
        self.addCleanup(stop.set)
        return thread

    def test_request_returns_the_matching_result(self):
        seen = []

        def handler(request):
            seen.append(request)
            return {"id": request["id"], "action": request["action"], "ok": True, "pid": 4242,
                    "binary": self.fixture.binary, "at": time.time()}

        self.responder(handler)
        result = PHASE.request_runner(self.fixture.state, "launch", seconds=5, extra={"log": "x.log"})
        self.assertEqual(4242, result["pid"])
        self.assertEqual("x.log", seen[0]["log"])
        self.assertFalse(os.path.exists(self.fixture.state["runnerResult"]))

    def test_result_for_another_request_is_ignored_until_timeout(self):
        self.responder(lambda request: {"id": "0" * 32, "action": "launch", "ok": True, "pid": 1})
        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.request_runner(self.fixture.state, "launch", seconds=1)
        self.assertIn("did not settle", str(caught.exception))

    def test_refusal_is_an_error_not_a_success(self):
        self.responder(lambda request: {"id": request["id"], "action": "stop", "ok": False,
                                        "error": "still alive after the KILL bound"})
        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.request_runner(self.fixture.state, "stop", seconds=5)
        self.assertIn("still alive", str(caught.exception))

    def test_only_stop_and_launch_can_be_requested(self):
        with self.assertRaises(PHASE.FixtureError):
            PHASE.request_runner(self.fixture.state, "rm -rf", seconds=1)

    def test_prepare_stops_seeds_launches_then_proves_readiness(self):
        self.fixture.launch()
        calls = []

        def runner(state, action, seconds=0, extra=None):
            calls.append(action)
            if action == "stop":
                self.assertFalse(os.path.exists(state["config"]), "seeding must wait for the stop")
                return {"ok": True}
            return {"ok": True, "pid": state["pid"] or self.fixture.process.pid,
                    "binary": self.fixture.binary, "log": "/log", "at": time.time(),
                    "deadlineAt": 123}

        def ready(state, panes):
            calls.append("ready:%d" % len(panes))
            return {"pid": state["pid"], "windows": [{"number": 1}], "at": time.time()}

        observation = PHASE.phase_prepare(self.fixture.state, self.fixture.state_path,
                                          "accessibility", None, runner=runner, ready=ready)
        self.assertEqual(["stop", "launch", "ready:1"], calls)
        state = PHASE.read_json(self.fixture.state_path)
        self.assertEqual(1, state["batches"])
        self.assertEqual("accessibility", state["scenario"]["scenario"])
        self.assertTrue(state["scenario"]["readiness"]["ok"])
        self.assertTrue(os.path.exists(observation["scenarioFile"]))
        self.assertTrue(PHASE.realpath_within(observation["scenarioFile"], self.fixture.evidence))
        self.assertEqual(123, state["deadlineAt"])

    def test_quit_refusal_locks_support_only_after_readiness(self):
        def runner(state, action, seconds=0, extra=None):
            self.assertEqual(0o700, stat.S_IMODE(os.stat(state["support"]).st_mode))
            return {"ok": True, "pid": self.fixture.launch(),
                    "binary": self.fixture.binary, "at": time.time()}

        def ready(state, panes):
            self.assertEqual(0o700, stat.S_IMODE(os.stat(state["support"]).st_mode))
            self.assertEqual(0o600, stat.S_IMODE(os.stat(state["session"]).st_mode))
            return {"pid": state["pid"], "at": time.time()}

        PHASE.phase_prepare(self.fixture.state, self.fixture.state_path,
                            "recovery", "quit-save-refused", runner=runner, ready=ready)
        self.assertEqual(0o500, stat.S_IMODE(os.stat(self.fixture.support).st_mode))
        self.assertEqual(0o400, stat.S_IMODE(os.stat(self.fixture.state["session"]).st_mode))

    def test_prepare_without_a_launched_app_skips_the_stop(self):
        calls = []

        def runner(state, action, seconds=0, extra=None):
            calls.append(action)
            return {"ok": True, "pid": self.fixture.launch(), "binary": self.fixture.binary,
                    "at": time.time()}

        PHASE.phase_prepare(self.fixture.state, self.fixture.state_path, "recovery", "malformed",
                            runner=runner, ready=lambda *_: self.fail("no pane to await"))
        self.assertEqual(["launch"], calls)
        state = PHASE.read_json(self.fixture.state_path)
        self.assertEqual([], state["scenario"]["panes"])
        self.assertIn("recovery dialog", state["scenario"]["readiness"]["note"])

    def test_prepare_marks_a_scenario_that_never_became_ready(self):
        def runner(state, action, seconds=0, extra=None):
            return {"ok": True, "pid": self.fixture.launch(), "binary": self.fixture.binary,
                    "at": time.time()}

        def ready(state, panes):
            raise PHASE.FixtureError("visible window did not settle within 1 seconds")

        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.phase_prepare(self.fixture.state, self.fixture.state_path, "input", None,
                                runner=runner, ready=ready)
        self.assertIn("not ready", str(caught.exception))
        state = PHASE.read_json(self.fixture.state_path)
        self.assertFalse(state["scenario"]["readiness"]["ok"])
        self.assertFalse(list(pathlib.Path(self.fixture.evidence).glob("scenarios/*.json")))

    def test_await_quit_announces_then_observes_the_exact_pid_ending(self):
        pid = self.fixture.launch()
        self.fixture.prepared()
        calls = []

        def runner(state, action, seconds=0, extra=None):
            calls.append(action)
            threading.Timer(0.3, self.fixture.process.kill).start()
            return {"ok": True, "pid": pid}

        observation = PHASE.phase_await_quit(self.fixture.state, self.fixture.state_path, 5, runner=runner)
        self.assertEqual(["expect-quit"], calls)
        self.assertTrue(observation["quitObserved"])
        state = PHASE.read_json(self.fixture.state_path)
        self.assertIsNone(state["pid"])
        self.assertEqual(pid, state["lastPid"])
        self.assertIsNone(state["awaitingQuit"])

    def test_await_quit_times_out_when_the_app_keeps_running(self):
        self.fixture.launch()
        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.phase_await_quit(self.fixture.state, self.fixture.state_path, 0.5,
                                   runner=lambda *a, **k: {"ok": True})
        self.assertIn("expected quit", str(caught.exception))
        state = PHASE.read_json(self.fixture.state_path)
        self.assertEqual(self.fixture.process.pid, state["pid"])
        self.assertIsNotNone(state["awaitingQuit"])

    def test_await_quit_without_a_live_app_is_refused(self):
        with self.assertRaises(PHASE.FixtureError):
            PHASE.phase_await_quit(self.fixture.state, self.fixture.state_path, 1,
                                   runner=lambda *a, **k: self.fail("must not reach the runner"))

    def test_relaunch_reuses_the_session_the_app_wrote_without_reseeding(self):
        self.fixture.launch()
        self.fixture.prepared()
        # The app rewrote its session with its own pane ids before quitting.
        PHASE.atomic_json(self.fixture.state["session"], PHASE.session_document(
            [{"id": "G", "tabs": [PHASE.leaf_tab("T", "PANE-RESTORED")], "selectedTab": "T"}],
            "G", [PHASE.pane_state("PANE-RESTORED", self.fixture.scratch)]))
        session_hash = PHASE.sha256_of(self.fixture.state["session"])
        self.fixture.process.kill()
        self.fixture.process.wait()
        self.fixture.state["pid"] = None
        self.fixture.save()
        calls = []

        def runner(state, action, seconds=0, extra=None):
            calls.append((action, extra))
            return {"ok": True, "pid": self.fixture.launch(), "binary": self.fixture.binary,
                    "at": time.time(), "deadlineAt": 7}

        def ready(state):
            calls.append(("ready",))
            return {"pid": state["pid"], "windows": [{"number": 2}], "at": time.time()}

        observation = PHASE.phase_relaunch(self.fixture.state, self.fixture.state_path,
                                           runner=runner, ready=ready)
        self.assertEqual("launch", calls[0][0])
        self.assertIn("relaunch-1", calls[0][1]["log"])
        self.assertEqual(("ready",), calls[1])
        self.assertEqual(session_hash, PHASE.sha256_of(self.fixture.state["session"]), "no reseeding")
        state = PHASE.read_json(self.fixture.state_path)
        self.assertEqual(1, state["relaunches"])
        self.assertEqual(self.fixture.process.pid, state["pid"])
        self.assertTrue(state["scenario"]["relaunchReadiness"]["ok"])
        self.assertEqual(["PANE-RESTORED"], observation["sessionPanes"])

    def test_relaunch_requires_no_capabilities_before_native_tab_activation(self):
        self.fixture.prepared(scenario="windows")
        groups = [
            {"id": "G1", "tabs": [
                PHASE.leaf_tab("T1", "P1"), PHASE.leaf_tab("T2", "P2")],
             "selectedTab": "T2"},
            {"id": "G2", "tabs": [
                PHASE.leaf_tab("T3", "P3"), PHASE.leaf_tab("T4", "P4")],
             "selectedTab": "T3"},
        ]
        PHASE.atomic_json(self.fixture.state["session"], PHASE.session_document(
            groups, "G1", [PHASE.pane_state(pane, self.fixture.scratch)
                            for pane in ("P1", "P2", "P3", "P4")]))
        calls = []

        def runner(state, action, seconds=0, extra=None):
            return {"ok": True, "pid": self.fixture.launch(), "binary": self.fixture.binary,
                    "at": time.time()}

        def ready(state):
            calls.append("process-window")
            return {"pid": state["pid"], "windows": [{"number": 2}], "at": time.time()}

        observation = PHASE.phase_relaunch(self.fixture.state, self.fixture.state_path,
                                           runner=runner, ready=ready)
        self.assertEqual(["process-window"], calls)
        self.assertEqual(["P1", "P2", "P3", "P4"], observation["sessionPanes"])
        self.assertEqual(["P2", "P3"], observation["selectedSessionPanes"])
        self.assertEqual({"P1", "P2", "P3", "P4"},
                         set(observation["pendingPaneVerification"]))
        self.assertIn("native activation", observation["pendingPaneVerification"]["P2"])
        self.assertNotIn("whoami", observation["readiness"])

    def test_selected_session_panes_rejects_unknown_selected_tab(self):
        document = PHASE.session_document(
            [{"id": "G", "tabs": [PHASE.leaf_tab("T", "P")], "selectedTab": "MISSING"}],
            "G", [PHASE.pane_state("P", self.fixture.scratch)])
        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.selected_session_panes(document)
        self.assertIn("selectedTab", str(caught.exception))

    def test_selected_session_panes_rejects_selected_tab_without_focused_pane(self):
        document = PHASE.session_document(
            [{"id": "G", "tabs": [{"id": "T", "tree": {}}], "selectedTab": "T"}],
            "G", [PHASE.pane_state("P", self.fixture.scratch)])
        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.selected_session_panes(document)
        self.assertIn("focusedPane", str(caught.exception))

    def test_relaunch_scope_rejects_any_unregistered_focused_pane(self):
        document = PHASE.session_document(
            [{"id": "G", "tabs": [PHASE.leaf_tab("T1", "P1"),
                                      PHASE.leaf_tab("T2", "MISSING")], "selectedTab": "T1"}],
            "G", [PHASE.pane_state("P1", self.fixture.scratch)])
        PHASE.atomic_json(self.fixture.state["session"], document)
        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.relaunch_session_scope(self.fixture.state)
        self.assertIn("focusedPane", str(caught.exception))

    def test_relaunch_is_refused_while_the_app_still_runs(self):
        self.fixture.launch()
        self.fixture.prepared()
        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.phase_relaunch(self.fixture.state, self.fixture.state_path,
                                 runner=lambda *a, **k: self.fail("must not launch"))
        self.assertIn("still running", str(caught.exception))

    def test_relaunch_without_a_scenario_is_refused(self):
        with self.assertRaises(PHASE.FixtureError):
            PHASE.phase_relaunch(self.fixture.state, self.fixture.state_path,
                                 runner=lambda *a, **k: self.fail("must not launch"))

    def test_prepare_refuses_a_launch_of_another_binary(self):
        def runner(state, action, seconds=0, extra=None):
            return {"ok": True, "pid": 4242, "binary": "/bin/cat", "at": time.time()}

        with self.assertRaises(PHASE.FixtureError) as caught:
            PHASE.phase_prepare(self.fixture.state, self.fixture.state_path, "input", None,
                                runner=runner, ready=lambda *_: None)
        self.assertIn("different binary", str(caught.exception))


def settled_termios(fd):
    """tcgetattr without PENDIN, the transient flag the kernel raises on the
    raw-to-canonical transition. It is not part of the saved mode."""
    attributes = termios.tcgetattr(fd)
    attributes[3] &= ~termios.PENDIN
    return attributes


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="baia-recorder-test.")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.out = os.path.join(self.root, "rec")
        self.master, self.slave = pty.openpty()
        self.addCleanup(self.close_pty)
        self.before = settled_termios(self.slave)
        self.process = None

    def close_pty(self):
        if self.process is not None and self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass

    def start(self, seconds="30"):
        env = dict(os.environ, BAIA_PANE="PANE-TEST", PYTHONDONTWRITEBYTECODE="1")
        self.process = subprocess.Popen(
            [PYTHON, str(RECORDER), "--out", self.out, "--seconds", seconds, "--label", "unit"],
            stdin=self.slave, stdout=self.slave, stderr=subprocess.PIPE, env=env)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if os.path.exists(os.path.join(self.out, "bytes.jsonl")):
                mode = termios.tcgetattr(self.slave)
                if not mode[3] & termios.ICANON:
                    return
            time.sleep(0.02)
        self.fail("recorder did not enter raw mode")

    def finish(self):
        _out, err = self.process.communicate(timeout=10)
        return err.decode("utf-8", "replace")

    def read_lines(self):
        with open(os.path.join(self.out, "bytes.jsonl"), encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def test_records_cr_esc_and_marker_then_restores_termios(self):
        self.start()
        os.write(self.master, b"\r")
        time.sleep(0.1)
        os.write(self.master, b"\x1b")
        time.sleep(0.1)
        os.write(self.master, b"MARKER-7")
        time.sleep(0.3)
        pathlib.Path(self.out, "stop").touch()
        err = self.finish()
        self.assertEqual(0, self.process.returncode, err)
        joined = bytes.fromhex("".join(line["hex"] for line in self.read_lines()))
        self.assertEqual(b"\r\x1bMARKER-7", joined)
        summary = json.load(open(os.path.join(self.out, "summary.json")))
        self.assertEqual({"cr": 1, "esc": 1, "bytes": 10}, {k: summary[k] for k in ("cr", "esc", "bytes")})
        self.assertEqual("stop-file", summary["reason"])
        self.assertTrue(summary["termiosRestored"])
        self.assertEqual("PANE-TEST", summary["pane"])
        self.assertEqual(self.before, settled_termios(self.slave))
        meta = json.load(open(os.path.join(self.out, "meta.json")))
        self.assertEqual(self.process.pid, meta["pid"])
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o700)
        echoed = os.read(self.master, 4096)
        self.assertIn(b"<0D><1B>MARKER-7", echoed)

    def test_raw_mode_does_not_turn_cr_into_newline_or_esc_into_a_sequence(self):
        self.start()
        os.write(self.master, b"\r\n\x1b[A\x03")
        time.sleep(0.3)
        pathlib.Path(self.out, "stop").touch()
        self.finish()
        joined = bytes.fromhex("".join(line["hex"] for line in self.read_lines()))
        self.assertEqual(b"\r\n\x1b[A\x03", joined)
        self.assertEqual(0, self.process.returncode)

    def test_sigterm_restores_termios_and_writes_the_summary(self):
        self.start()
        os.write(self.master, b"x")
        time.sleep(0.2)
        self.process.send_signal(signal.SIGTERM)
        self.finish()
        summary = json.load(open(os.path.join(self.out, "summary.json")))
        self.assertEqual("signal-%d" % signal.SIGTERM, summary["reason"])
        self.assertTrue(summary["termiosRestored"])
        self.assertEqual(self.before, settled_termios(self.slave))

    def test_three_ctrl_d_bytes_stop_the_recorder(self):
        self.start()
        os.write(self.master, b"\x04\x04\x04")
        self.finish()
        summary = json.load(open(os.path.join(self.out, "summary.json")))
        self.assertEqual("ctrl-d-x3", summary["reason"])
        self.assertEqual(self.before, settled_termios(self.slave))

    def test_deadline_stops_the_recorder(self):
        self.start(seconds="0.5")
        self.finish()
        summary = json.load(open(os.path.join(self.out, "summary.json")))
        self.assertEqual("deadline", summary["reason"])

    def test_refuses_an_existing_output_directory_and_non_tty(self):
        os.mkdir(self.out)
        process = subprocess.run([PYTHON, str(RECORDER), "--out", self.out],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True)
        self.assertEqual(2, process.returncode)
        self.assertIn("must not exist", process.stderr)
        fresh = os.path.join(self.root, "fresh")
        process = subprocess.run([PYTHON, str(RECORDER), "--out", fresh],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True)
        self.assertNotEqual(0, process.returncode)
        self.assertIn("needs a terminal", process.stderr)


if __name__ == "__main__":
    unittest.main()
