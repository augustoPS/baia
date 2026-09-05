#!/usr/bin/env python3
"""Regression tests for session-recovery fixtures and durable-output grading."""

import json
import pathlib
import unittest

import session_oracle


class SessionOracleTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path("/tmp/session-recovery-oracle")

    def test_current_fixture_is_schema_2_with_current_shape(self):
        payload = session_oracle.current_session(self.root)
        document = json.loads(payload)
        grade = session_oracle.grade_current_session(payload, expected_panes=1)

        self.assertEqual(2, document["schemaVersion"])
        self.assertIn("groups", document)
        self.assertNotIn("workspace", document)
        self.assertTrue(grade.valid_json)
        self.assertTrue(grade.current_schema)
        self.assertTrue(grade.current_shape)
        self.assertTrue(grade.expected_pane_count)

    def test_legacy_v1_fixture_stays_separate(self):
        document = json.loads(session_oracle.legacy_v1_session(self.root))

        self.assertEqual(1, document["schemaVersion"])
        self.assertIn("workspace", document)
        self.assertNotIn("groups", document)

    def test_future_fixture_is_genuinely_newer_than_current(self):
        payload = session_oracle.future_session(self.root)
        document = json.loads(payload)
        grade = session_oracle.grade_current_session(payload, expected_panes=1)

        self.assertEqual(3, document["schemaVersion"])
        self.assertFalse(grade.current_schema)
        self.assertTrue(grade.current_shape)

    def test_rejects_v1_shape_mislabeled_as_schema_2(self):
        document = json.loads(session_oracle.legacy_v1_session(self.root))
        document["schemaVersion"] = 2
        grade = session_oracle.grade_current_session(
            json.dumps(document).encode(), expected_panes=1
        )

        self.assertTrue(grade.current_schema)
        self.assertFalse(grade.current_shape)

    def test_rejects_missing_created_pane(self):
        grade = session_oracle.grade_current_session(
            session_oracle.current_session(self.root), expected_panes=2
        )

        self.assertFalse(grade.expected_pane_count)

    def test_rejects_a_current_document_without_a_window_group(self):
        document = json.loads(session_oracle.current_session(self.root))
        document["groups"] = []
        grade = session_oracle.grade_current_session(json.dumps(document).encode())

        self.assertFalse(grade.current_shape)

    def test_rejects_malformed_json(self):
        grade = session_oracle.grade_current_session(b"{broken", expected_panes=1)

        self.assertFalse(grade.valid_json)
        self.assertFalse(grade.current_schema)
        self.assertFalse(grade.current_shape)
        self.assertFalse(grade.expected_pane_count)


if __name__ == "__main__":
    unittest.main()
