#!/usr/bin/python3
"""Build session fixtures and grade the real app's durable output."""

import argparse
import hashlib
import json
import pathlib
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class ExpectedGroup:
    tabs: tuple
    selected: str
    sidebar_width: float
    sidebar_split_height: float


def schema2_failures(document, expected_groups, active_tabs, require_distinct_frames=True):
    """Return every mismatch between a durable document and the required groups."""
    failures = []
    if not isinstance(document, dict):
        return ["session is not a JSON object"]
    if document.get("schemaVersion") != 2:
        failures.append("schemaVersion is not 2")
    groups = document.get("groups")
    if not isinstance(groups, list):
        return failures + ["groups is not an array"]

    actual_orders = []
    for item in groups:
        tabs = item.get("tabs") if isinstance(item, dict) else None
        if not isinstance(tabs, list):
            actual_orders.append(())
            continue
        actual_orders.append(tuple(tab.get("id") for tab in tabs if isinstance(tab, dict)))
    expected_orders = [tuple(group.tabs) for group in expected_groups]
    actual_by_members = {frozenset(order): (order, item) for order, item in zip(actual_orders, groups)}
    expected_by_members = {frozenset(group.tabs): group for group in expected_groups}
    if len(actual_orders) != len(expected_orders) or set(actual_by_members) != set(expected_by_members):
        failures.append("group membership differs: %r" % (actual_orders,))

    for index, expected in enumerate(expected_groups):
        matched = actual_by_members.get(frozenset(expected.tabs))
        if matched is None:
            continue
        actual_order, actual = matched
        if actual_order != tuple(expected.tabs):
            failures.append("group %d tab order differs: %r" % (index + 1, actual_order))
        if actual.get("selectedTab") != expected.selected:
            failures.append("group %d selected tab differs" % (index + 1))
        sidebar = actual.get("sidebar")
        if not isinstance(sidebar, dict):
            failures.append("group %d sidebar is missing" % (index + 1))
        else:
            width = sidebar.get("width")
            split = sidebar.get("splitHeight")
            if not isinstance(width, (int, float)) or abs(width - expected.sidebar_width) > 0.5:
                failures.append("group %d sidebar width differs" % (index + 1))
            if not isinstance(split, (int, float)) or abs(split - expected.sidebar_split_height) > 0.5:
                failures.append("group %d sidebar split height differs" % (index + 1))
        frame = actual.get("frame")
        if not isinstance(frame, dict) or not all(
                isinstance(frame.get(key), (int, float)) for key in ("x", "y", "width", "height")):
            failures.append("group %d frame is missing or malformed" % (index + 1))

    if require_distinct_frames and len(groups) > 1:
        frames = [group.get("frame") for group in groups if isinstance(group, dict)]
        if len(frames) != len(groups) or len({json.dumps(frame, sort_keys=True) for frame in frames}) != len(frames):
            failures.append("groups do not have distinct frames")

    identifiers = [group.get("id") for group in groups if isinstance(group, dict)]
    if len(identifiers) != len(set(identifiers)):
        failures.append("group identifiers are not unique")
    active = document.get("activeGroup")
    try:
        active_index = identifiers.index(active)
    except ValueError:
        failures.append("active group does not name a saved group")
    else:
        if active_index >= len(actual_orders) or actual_orders[active_index] != tuple(active_tabs):
            failures.append("active group names the wrong tab group")
    return failures


A = "BA1AC0DE-0000-4000-8000-0000000000A1"
B = "BA1AC0DE-0000-4000-8000-0000000000B2"
C = "BA1AC0DE-0000-4000-8000-0000000000C3"
D = "BA1AC0DE-0000-4000-8000-0000000000D4"
PANE_A = "BA1AC0DE-0000-4000-8000-000000000001"
PANE_B = "BA1AC0DE-0000-4000-8000-000000000002"
PANE_C = "BA1AC0DE-0000-4000-8000-000000000003"
PANE_D = "BA1AC0DE-0000-4000-8000-000000000004"
PANE_A2 = "BA1AC0DE-0000-4000-8000-000000000005"
GROUP_ONE = "BA1AC0DE-1000-4000-8000-000000000001"
GROUP_TWO = "BA1AC0DE-2000-4000-8000-000000000002"


def leaf_tab(tab, pane):
    return {
        "id": tab,
        "focusedPane": {"rawValue": pane},
        "tree": {"leaf": {"_0": {"rawValue": pane}}},
    }


def split_tab(tab, first, second):
    return {
        "id": tab,
        "focusedPane": {"rawValue": second},
        "tree": {
            "split": {
                "axis": "horizontal",
                "ratio": 0.37,
                "first": {"leaf": {"_0": {"rawValue": first}}},
                "second": {"leaf": {"_0": {"rawValue": second}}},
            }
        },
    }


def pane(identifier, directory):
    return {"id": {"rawValue": identifier}, "workingDirectory": str(directory)}


def write_json(path, document):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((json.dumps(document, indent=2, sort_keys=True) + "\n").encode())


def seed_v1(args):
    root = pathlib.Path(args.root)
    directories = [root / "projects" / name for name in ("alpha", "bravo", "charlie", "delta")]
    for directory in directories:
        directory.mkdir(parents=True, exist_ok=True)
    tabs = [split_tab(A, PANE_A, PANE_A2), leaf_tab(B, PANE_B),
            leaf_tab(C, PANE_C), leaf_tab(D, PANE_D)]
    document = {
        "schemaVersion": 1,
        "workspace": {"tabs": tabs, "focusedTabIndex": 1},
        "panes": [
            pane(PANE_A, directories[0]),
            pane(PANE_A2, directories[0]),
            pane(PANE_B, directories[1]),
            pane(PANE_C, directories[2]),
            pane(PANE_D, directories[3]),
        ],
        "windowFrame": {"x": 80, "y": 80, "width": 920, "height": 620},
        "sidebar": {"width": 260, "splitHeight": 220},
    }
    write_json(args.source, document)
    pathlib.Path(args.session).write_bytes(pathlib.Path(args.source).read_bytes())


def seed_missing(args):
    root = pathlib.Path(args.root)
    existing = root / "projects" / "alpha"
    existing.mkdir(parents=True, exist_ok=True)
    missing_one = root / "missing" / "bravo"
    missing_two = root / "missing" / "charlie"
    document = {
        "schemaVersion": 2,
        "groups": [
            {
                "id": GROUP_ONE,
                "tabs": [leaf_tab(A, PANE_A), leaf_tab(B, PANE_B)],
                "selectedTab": B,
                "frame": {"x": 80, "y": 80, "width": 620, "height": 520},
                "sidebar": {"width": 286, "splitHeight": 174},
            },
            {
                "id": GROUP_TWO,
                "tabs": [leaf_tab(C, PANE_C)],
                "selectedTab": C,
                "frame": {"x": 740, "y": 110, "width": 650, "height": 540},
                "sidebar": {"width": 374, "splitHeight": 238},
            },
        ],
        "activeGroup": GROUP_TWO,
        "panes": [
            pane(PANE_A, existing),
            pane(PANE_B, missing_one),
            pane(PANE_C, missing_two),
        ],
    }
    write_json(args.session, document)


EXPECTATIONS = {
    "arranged": (
        [ExpectedGroup((B, A), A, 286, 174), ExpectedGroup((D, C), D, 374, 238)],
        (D, C), True,
    ),
    "mutated": (
        [ExpectedGroup((A, D), D, 302, 188), ExpectedGroup((C, B), B, 358, 226)],
        (A, D), True,
    ),
    "restored": (
        [ExpectedGroup((A, D), D, 302, 188), ExpectedGroup((C, B), B, 358, 226)],
        (A, D), True,
    ),
    "missing": (
        [ExpectedGroup((A,), A, 286, 174)],
        (A,), False,
    ),
}


def grade(args):
    failures = []
    try:
        document = json.loads(pathlib.Path(args.session).read_text())
    except (OSError, ValueError) as error:
        document = None
        failures.append("session could not be decoded: %s" % error)
    expected, active, distinct = EXPECTATIONS[args.phase]
    if document is not None:
        failures.extend(schema2_failures(document, expected, active, distinct))

    event_path = pathlib.Path(args.events)
    events = event_path.read_text() if event_path.exists() else ""
    if "self-check failures=0" not in events:
        failures.append("in-process self-check did not report zero failures")
    if args.phase == "arranged":
        source = pathlib.Path(args.source).read_bytes()
        backup = pathlib.Path(args.backup)
        if not backup.exists() or backup.read_bytes() != source:
            failures.append("version 1 migration backup is absent or not byte-identical")

    record = {"phase": args.phase, "checksPassed": not failures, "failures": failures}
    evidence = pathlib.Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    if document is not None:
        write_json(evidence / (args.phase + "-session.json"), document)
    with (evidence / "grades.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
    if failures:
        for failure in failures:
            print("FAIL %s: %s" % (args.phase, failure))
        return 1
    print("PASS %s: durable schema and native self-check agree" % args.phase)
    return 0


def finalize(args):
    binary = pathlib.Path(args.binary)
    grades_path = pathlib.Path(args.evidence) / "grades.jsonl"
    grades = [json.loads(line) for line in grades_path.read_text().splitlines()] if grades_path.exists() else []
    report = {
        "binary": str(binary),
        "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "phases": grades,
        "passed": len(grades) == 4 and all(grade.get("checksPassed") for grade in grades),
    }
    write_json(pathlib.Path(args.evidence) / "report.json", report)
    return 0 if report["passed"] else 1


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    seed = commands.add_parser("seed-v1")
    seed.add_argument("--session", required=True)
    seed.add_argument("--source", required=True)
    seed.add_argument("--root", required=True)
    seed.set_defaults(action=seed_v1)
    missing = commands.add_parser("seed-missing")
    missing.add_argument("--session", required=True)
    missing.add_argument("--root", required=True)
    missing.set_defaults(action=seed_missing)
    check = commands.add_parser("grade")
    check.add_argument("--phase", choices=sorted(EXPECTATIONS), required=True)
    check.add_argument("--session", required=True)
    check.add_argument("--events", required=True)
    check.add_argument("--evidence", required=True)
    check.add_argument("--source")
    check.add_argument("--backup")
    check.set_defaults(action=grade)
    finish = commands.add_parser("finalize")
    finish.add_argument("--binary", required=True)
    finish.add_argument("--evidence", required=True)
    finish.set_defaults(action=finalize)
    return root


if __name__ == "__main__":
    arguments = parser().parse_args()
    sys.exit(arguments.action(arguments) or 0)
