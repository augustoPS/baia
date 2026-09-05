"""Current, legacy, and future session fixtures plus durable-output grading."""

from dataclasses import dataclass
import json


CURRENT_SCHEMA = 2
FUTURE_SCHEMA = CURRENT_SCHEMA + 1

PANE = "BA1AC0DE-0000-4000-8000-000000000001"
TAB = "BA1AC0DE-0000-4000-8000-0000000000AA"
GROUP = "BA1AC0DE-0000-4000-8000-0000000000BB"


@dataclass(frozen=True)
class SessionGrade:
    valid_json: bool
    current_schema: bool
    current_shape: bool
    expected_pane_count: bool


def _tab():
    return {
        "id": TAB,
        "focusedPane": {"rawValue": PANE},
        "tree": {"leaf": {"_0": {"rawValue": PANE}}},
    }


def _panes(root):
    return [{"id": {"rawValue": PANE}, "workingDirectory": str(root)}]


def current_session(root):
    return json.dumps(
        {
            "schemaVersion": CURRENT_SCHEMA,
            "groups": [
                {
                    "id": GROUP,
                    "tabs": [_tab()],
                    "selectedTab": TAB,
                }
            ],
            "activeGroup": GROUP,
            "panes": _panes(root),
        },
        separators=(",", ":"),
    ).encode()


def legacy_v1_session(root):
    return json.dumps(
        {
            "schemaVersion": 1,
            "workspace": {"tabs": [_tab()], "focusedTabIndex": 0},
            "panes": _panes(root),
        },
        separators=(",", ":"),
    ).encode()


def future_session(root):
    document = json.loads(current_session(root))
    document["schemaVersion"] = FUTURE_SCHEMA
    return json.dumps(document, separators=(",", ":")).encode()


def grade_current_session(payload, expected_panes=None):
    try:
        document = json.loads(payload)
    except (TypeError, ValueError, UnicodeDecodeError):
        document = None

    valid_json = isinstance(document, dict)
    current_schema = valid_json and document.get("schemaVersion") == CURRENT_SCHEMA
    groups = document.get("groups") if valid_json else None
    current_shape = (
        isinstance(groups, list)
        and bool(groups)
        and "workspace" not in document
        and all(_is_group(group) for group in groups)
    )
    panes = document.get("panes") if valid_json else None
    expected_pane_count = (
        expected_panes is None
        or isinstance(panes, list) and len(panes) == expected_panes
    )
    return SessionGrade(valid_json, current_schema, current_shape, expected_pane_count)


def _is_group(group):
    if not isinstance(group, dict):
        return False
    tabs = group.get("tabs")
    return (
        isinstance(group.get("id"), str)
        and isinstance(group.get("selectedTab"), str)
        and isinstance(tabs, list)
        and all(isinstance(tab, dict) for tab in tabs)
    )
