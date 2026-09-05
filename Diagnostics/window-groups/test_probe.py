#!/usr/bin/python3
"""Regression tests for the fixture's durable-session oracle."""

import copy
import importlib.util
import pathlib
import unittest


HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("window_group_probe", HERE / "probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


A = "BA1AC0DE-0000-4000-8000-0000000000A1"
B = "BA1AC0DE-0000-4000-8000-0000000000B2"
C = "BA1AC0DE-0000-4000-8000-0000000000C3"
D = "BA1AC0DE-0000-4000-8000-0000000000D4"


def group(identifier, tabs, selected, frame, sidebar):
    return {
        "id": identifier,
        "tabs": [{"id": tab} for tab in tabs],
        "selectedTab": selected,
        "frame": frame,
        "sidebar": sidebar,
    }


class DurableSessionOracleTests(unittest.TestCase):
    def setUp(self):
        self.document = {
            "schemaVersion": 2,
            "groups": [
                group("11111111-1111-4111-8111-111111111111", [B, A], A,
                      {"x": 40, "y": 60, "width": 620, "height": 520},
                      {"width": 286, "splitHeight": 174}),
                group("22222222-2222-4222-8222-222222222222", [D, C], D,
                      {"x": 720, "y": 90, "width": 650, "height": 540},
                      {"width": 374, "splitHeight": 238}),
            ],
            "activeGroup": "22222222-2222-4222-8222-222222222222",
            "panes": [],
        }
        self.expected = [
            probe.ExpectedGroup((B, A), A, 286, 174),
            probe.ExpectedGroup((D, C), D, 374, 238),
        ]

    def test_accepts_two_ordered_groups_with_distinct_geometry(self):
        self.assertEqual([], probe.schema2_failures(self.document, self.expected, active_tabs=(D, C)))

    def test_accepts_the_same_groups_in_a_different_outer_order(self):
        swapped = copy.deepcopy(self.document)
        swapped["groups"].reverse()
        self.assertEqual([], probe.schema2_failures(swapped, self.expected, active_tabs=(D, C)))

    def test_rejects_a_flattened_capture(self):
        broken = copy.deepcopy(self.document)
        broken["groups"] = [group(
            "11111111-1111-4111-8111-111111111111", [B, A, D, C], A,
            broken["groups"][0]["frame"], broken["groups"][0]["sidebar"]
        )]
        self.assertTrue(any("group membership" in failure for failure in
                            probe.schema2_failures(broken, self.expected, active_tabs=(D, C))))

    def test_rejects_wrong_tab_order_inside_a_group(self):
        broken = copy.deepcopy(self.document)
        broken["groups"][0]["tabs"].reverse()
        self.assertTrue(any("tab order" in failure for failure in
                            probe.schema2_failures(broken, self.expected, active_tabs=(D, C))))

    def test_rejects_the_wrong_selected_tab(self):
        broken = copy.deepcopy(self.document)
        broken["groups"][1]["selectedTab"] = C
        self.assertTrue(any("selected tab" in failure for failure in
                            probe.schema2_failures(broken, self.expected, active_tabs=(D, C))))

    def test_rejects_shared_frames_and_sidebar_geometry(self):
        broken = copy.deepcopy(self.document)
        broken["groups"][1]["frame"] = copy.deepcopy(broken["groups"][0]["frame"])
        broken["groups"][1]["sidebar"] = copy.deepcopy(broken["groups"][0]["sidebar"])
        failures = probe.schema2_failures(broken, self.expected, active_tabs=(D, C))
        self.assertTrue(any("distinct frames" in failure for failure in failures))
        self.assertTrue(any("sidebar" in failure for failure in failures))

    def test_accepts_missing_directory_repair_to_one_group(self):
        repaired = {
            "schemaVersion": 2,
            "groups": [group(
                "11111111-1111-4111-8111-111111111111", [A], A,
                {"x": 40, "y": 60, "width": 620, "height": 520},
                {"width": 286, "splitHeight": 174},
            )],
            "activeGroup": "11111111-1111-4111-8111-111111111111",
            "panes": [],
        }
        expected = [probe.ExpectedGroup((A,), A, 286, 174)]
        self.assertEqual([], probe.schema2_failures(repaired, expected, active_tabs=(A,),
                                                     require_distinct_frames=False))


if __name__ == "__main__":
    unittest.main()
