#!/usr/bin/env python3
"""No-app oracle checks for the notification permission phase driver."""

import copy
import importlib.util
import pathlib
import tempfile
import unittest


HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("notification_phase", HERE / "phase.py")
PHASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PHASE)


class NotificationPhaseOracleTests(unittest.TestCase):
    def test_notification_setting_keeps_unrelated_disposable_keys(self):
        original = {
            "notificationsEnabled": True,
            "controlChannelEnabled": True,
            "controlAllowRead": True,
            "projectRoots": ["/private/fixture"],
            "backgroundOpacity": 0.77,
        }

        disabled = PHASE.settings_document(original, enabled=False)

        self.assertFalse(disabled["notificationsEnabled"])
        self.assertFalse(disabled["controlChannelEnabled"])
        self.assertEqual(["/private/fixture"], disabled["projectRoots"])
        self.assertEqual(0.77, disabled["backgroundOpacity"])
        self.assertEqual(True, original["notificationsEnabled"])

    def test_enabled_setting_uses_the_control_channel_as_reload_fence(self):
        enabled = PHASE.settings_document(
            {"notificationsEnabled": False, "controlChannelEnabled": False},
            enabled=True,
        )

        self.assertTrue(enabled["notificationsEnabled"])
        self.assertTrue(enabled["controlChannelEnabled"])

        reopened = PHASE.settings_document(enabled, enabled=False, channel_enabled=True)
        self.assertFalse(reopened["notificationsEnabled"])
        self.assertTrue(reopened["controlChannelEnabled"])

    def test_attention_observation_records_wire_and_effective_state_not_delivery(self):
        response = {"ok": True, "result": {"accepted": True}}
        record = {"pane": "PANE", "attention": "asking", "project": "R12-live"}
        explanation = {
            "pane": "PANE",
            "attention": "asking",
            "attentionDecidedBy": "report",
            "report": {"live": True, "seq": 7, "state": "blocked"},
        }

        observed = PHASE.attention_observation(response, record, explanation)

        self.assertEqual(response, observed["wireResponse"])
        self.assertEqual("asking", observed["effectiveAttention"])
        self.assertEqual("report", observed["attentionDecidedBy"])
        self.assertTrue(observed["report"]["live"])
        self.assertNotIn("delivered", observed)
        self.assertNotIn("notificationDelivered", repr(observed))

    def test_evidence_contract_reserves_delivery_for_external_observation(self):
        state = {
            "runId": "RUN",
            "pid": 123,
            "bundleId": "pasqualotto.baia.notification-permission.RUN",
            "projectName": "R12-notification-RUN",
        }

        report = PHASE.new_report(copy.deepcopy(state))

        self.assertEqual("external-verification-required", report["deliveryClaim"])
        self.assertEqual([], report["phases"])
        self.assertEqual(123, report["pid"])
        self.assertNotIn("delivered", report)

    def test_report_sequence_is_monotonic_across_phase_processes(self):
        state = {"nextSequence": 3}

        sequence = PHASE.take_sequence(state)

        self.assertEqual(3, sequence)
        self.assertEqual(4, state["nextSequence"])

    def test_spent_sequence_is_durable_before_an_uncertain_wire_outcome(self):
        state = {"nextSequence": 9}
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "fixture.json"

            sequence = PHASE.spend_sequence(state, path)

            self.assertEqual(9, sequence)
            self.assertEqual(10, PHASE.read_json(path)["nextSequence"])

    def test_delivery_notifications_keep_only_own_identifier_body_and_date(self):
        observed = PHASE.sanitize_delivery_notifications({
            "pid": 99,
            "session": "/secret/session.json",
            "notifications": [
                {
                    "identifier": "baia.attention.R12-live",
                    "body": "enabled-again",
                    "date": 12.5,
                    "title": "should-not-leak",
                    "userInfo": {"token": "no"},
                },
                {"identifier": "other.banner", "body": "nope", "date": 1},
                "ignored",
            ],
        })

        self.assertEqual(
            [{
                "identifier": "baia.attention.R12-live",
                "body": "enabled-again",
                "date": 12.5,
            }],
            observed,
        )
        self.assertNotIn("session", repr(observed))
        self.assertNotIn("token", repr(observed))
        self.assertNotIn("title", repr(observed))

    def test_owned_delivery_path_rejects_files_outside_scratch(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = pathlib.Path(directory) / "baia-notification-permission.abc"
            scratch.mkdir()
            outsider = pathlib.Path(directory) / "delivery-command.json"
            outsider.write_text("{}\n", encoding="utf-8")

            with self.assertRaises(RuntimeError):
                PHASE.require_owned_delivery_path(
                    str(outsider), str(scratch), "delivery-command.json"
                )

    def test_owned_delivery_path_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = pathlib.Path(directory) / "baia-notification-permission.abc"
            scratch.mkdir()
            outside = pathlib.Path(directory) / "escaped.json"
            outside.write_text("{}\n", encoding="utf-8")
            link = scratch / "delivery-command.json"
            link.symlink_to(outside)

            with self.assertRaises(RuntimeError):
                PHASE.require_owned_delivery_path(
                    str(link), str(scratch), "delivery-command.json"
                )

    def test_owned_delivery_path_rejects_the_wrong_basename(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = pathlib.Path(directory) / "baia-notification-permission.abc"
            scratch.mkdir()
            config = scratch / "config.json"
            config.write_text("{}\n", encoding="utf-8")

            with self.assertRaises(RuntimeError):
                PHASE.require_owned_delivery_path(
                    str(config), str(scratch), "delivery-command.json"
                )

    def test_delivery_state_requires_config_and_distinct_command_result(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = pathlib.Path(directory) / "baia-notification-permission.abc"
            scratch.mkdir()
            config = scratch / "config.json"
            command = scratch / "delivery-command.json"
            config.write_text("{}\n", encoding="utf-8")

            with self.assertRaises(RuntimeError):
                PHASE.require_delivery_state({
                    "scratch": str(scratch),
                    "config": str(config),
                    "deliveryCommand": str(command),
                    "deliveryResult": str(command),
                })

            accepted = PHASE.require_delivery_state({
                "scratch": str(scratch),
                "config": str(config),
                "deliveryCommand": str(command),
                "deliveryResult": str(scratch / "delivery-result.json"),
            })
            self.assertTrue(accepted[0].endswith("delivery-command.json"))
            self.assertTrue(accepted[1].endswith("delivery-result.json"))

    def test_delivery_wait_times_out_when_the_result_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "delivery-result.json"
            with self.assertRaises(RuntimeError):
                PHASE.await_delivery_result(str(path), "missing-id", seconds=0.3)

    def test_delivery_wait_ignores_a_result_for_another_command(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "delivery-result.json"
            PHASE.atomic_json(path, {"id": "other", "pid": 1, "notifications": []})
            with self.assertRaises(RuntimeError):
                PHASE.await_delivery_result(str(path), "wanted-id", seconds=0.3)

    def test_same_process_rejects_a_pid_that_is_not_the_copied_binary(self):
        with self.assertRaises(RuntimeError):
            PHASE.require_same_process({"pid": 1, "binary": "/not/the/copied/binary"})

    def test_evidence_contract_still_reserves_banner_delivery(self):
        report = PHASE.new_report({
            "runId": "RUN",
            "pid": 123,
            "bundleId": "pasqualotto.baia.notification-permission.RUN",
            "projectName": "R12-notification-RUN",
        })
        self.assertEqual("external-verification-required", report["deliveryClaim"])


if __name__ == "__main__":
    unittest.main()
