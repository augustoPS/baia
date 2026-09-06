#!/usr/bin/env python3
"""Drive one live notification fixture without deciding whether macOS delivered.

The optional `delivered` phase reads UN delivered history from the same copied
process. Banner presentation remains coordinator-owned.
"""

import argparse
import copy
import fcntl
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import uuid


SETTLE_SECONDS = 15.0
POLL_SECONDS = 0.1


def settings_document(document, enabled, channel_enabled=None):
    """Return the disposable settings snapshot used for one reload fence."""
    updated = copy.deepcopy(document)
    updated["notificationsEnabled"] = bool(enabled)
    updated["controlChannelEnabled"] = (
        bool(enabled) if channel_enabled is None else bool(channel_enabled)
    )
    return updated


def attention_observation(response, record, explanation):
    """Record what baia accepted and what its pane actually presents.

    Notification Center is deliberately absent. A banner, list entry, or
    duplicate count is evidence the coordinator records outside this process.
    """
    explanation = explanation if isinstance(explanation, dict) else {}
    return {
        "wireResponse": response,
        "paneRecord": record,
        "explanation": explanation,
        "effectiveAttention": (record or {}).get("attention"),
        "attentionDecidedBy": explanation.get("attentionDecidedBy"),
        "report": explanation.get("report"),
    }


def new_report(state):
    return {
        "version": 1,
        "runId": state["runId"],
        "pid": state["pid"],
        "bundleId": state["bundleId"],
        "projectName": state["projectName"],
        "deliveryClaim": "external-verification-required",
        "deliveryNote": (
            "This fixture records control responses and effective pane attention only; "
            "the coordinator observes macOS delivery and duplicate counts."
        ),
        "phases": [],
    }


def take_sequence(state):
    sequence = int(state.get("nextSequence", 1))
    state["nextSequence"] = sequence + 1
    return sequence


def spend_sequence(state, state_path=None):
    sequence = take_sequence(state)
    if state_path is not None:
        atomic_json(state_path, state)
    return sequence


def atomic_json(path, document):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def monotonic_wait(read, accepts, seconds=SETTLE_SECONDS):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = read()
        if accepts(last):
            return last
        time.sleep(POLL_SECONDS)
    raise RuntimeError("condition did not settle within %.0f seconds; last=%r" % (seconds, last))


def load_control_probe(path):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("notification_control_probe", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def process_command(pid):
    try:
        return subprocess.check_output(
            ["/bin/ps", "-p", str(pid), "-o", "command="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return None


def realpath_within(path, root):
    """True when path resolves inside root after symlink collapse."""
    resolved = os.path.realpath(path)
    base = os.path.realpath(root)
    if not resolved or not base:
        return False
    prefix = base if base.endswith(os.sep) else base + os.sep
    return resolved.startswith(prefix) and resolved != base


def require_owned_delivery_path(path, scratch, name):
    """Accept only an absolute fixture-scratch file with a fixed basename."""
    if not path or not scratch:
        raise RuntimeError("delivery path is missing")
    if not os.path.isabs(path) or not os.path.isabs(scratch):
        raise RuntimeError("delivery path must be absolute")
    if os.path.basename(path) != name:
        raise RuntimeError("delivery path must be named %s" % name)
    resolved = os.path.realpath(path)
    if os.path.basename(resolved) != name:
        raise RuntimeError("delivery path escaped owned filename")
    if not realpath_within(resolved, scratch):
        raise RuntimeError("delivery path is not inside the fixture scratch")
    return resolved


def require_delivery_state(state):
    scratch = state.get("scratch")
    config = state.get("config")
    command = state.get("deliveryCommand")
    result = state.get("deliveryResult")
    require_owned_delivery_path(config, scratch, "config.json")
    command_path = require_owned_delivery_path(
        command, scratch, "delivery-command.json"
    )
    result_path = require_owned_delivery_path(
        result, scratch, "delivery-result.json"
    )
    if command_path == result_path:
        raise RuntimeError("delivery command and result must be distinct")
    return command_path, result_path


def sanitize_delivery_notifications(document):
    """Keep identifier, body, and date for this copy's attention notifications."""
    items = []
    for item in document.get("notifications") or []:
        if not isinstance(item, dict):
            continue
        identifier = item.get("identifier")
        if not isinstance(identifier, str) or not identifier.startswith("baia.attention."):
            continue
        body = item.get("body")
        date = item.get("date")
        items.append({
            "identifier": identifier,
            "body": body if isinstance(body, str) else "",
            "date": date if isinstance(date, (int, float)) else None,
        })
    return items


def await_delivery_result(path, command_id, seconds=SETTLE_SECONDS):
    def read():
        if not os.path.exists(path):
            return None
        try:
            document = read_json(path)
        except (OSError, json.JSONDecodeError, ValueError):
            return None
        if not isinstance(document, dict) or document.get("id") != command_id:
            return None
        return document

    return monotonic_wait(read, lambda value: value is not None, seconds=seconds)


def require_same_process(state):
    pid = int(state["pid"])
    command = process_command(pid)
    if command != state["binary"]:
        raise RuntimeError(
            "fixture pid %d is not the recorded copied binary; command=%r" % (pid, command)
        )
    return pid


def frontmost_pid():
    script = (
        'ObjC.import("AppKit"); '
        '$.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier'
    )
    output = subprocess.check_output(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
        text=True,
        stderr=subprocess.STDOUT,
        timeout=5,
    ).strip()
    try:
        return int(output.splitlines()[-1])
    except (IndexError, ValueError):
        raise RuntimeError("could not read frontmost pid from osascript: %r" % output)


def require_background(state):
    pid = require_same_process(state)
    active = frontmost_pid() == pid
    if active:
        raise RuntimeError(
            "copied baia is frontmost; background it before raising attention"
        )
    return active


def probe_and_token(state, wait=False):
    control = load_control_probe(state["controlProbe"])
    probe = control.Probe(
        state["socket"], state["tokenDir"], state["config"], state["session"],
        state["tokenDir"], state["scratch"],
    )

    def find():
        if not os.path.exists(state["socket"]):
            return None
        return probe.tokens().get(state["pane"])

    token = monotonic_wait(find, bool, seconds=30.0) if wait else find()
    if not token:
        raise RuntimeError("the fixture pane has not privately reported its capability")
    return probe, token


def explanation_of(response):
    return (response.get("result") or {}).get("explanation")


def read_attention(probe, token, pane):
    listed = probe.request(token, "list")
    explained = probe.request(token, "explain")
    return {
        "listResponse": listed,
        "record": probe.record_of(listed, pane),
        "explainResponse": explained,
        "explanation": explanation_of(explained),
    }


def await_attention(probe, token, pane, wanted, sequence=None):
    def accepted(value):
        record = value.get("record") or {}
        explanation = value.get("explanation") or {}
        report = explanation.get("report") or {}
        if record.get("attention") != wanted:
            return False
        if sequence is None:
            return True
        return (
            explanation.get("attention") == wanted
            and explanation.get("attentionDecidedBy") == "report"
            and report.get("live") is True
            and report.get("seq") == sequence
        )

    return monotonic_wait(
        lambda: read_attention(probe, token, pane), accepted, seconds=SETTLE_SECONDS
    )


def observed_action(response, settled):
    observed = attention_observation(
        response, settled.get("record"), settled.get("explanation")
    )
    observed["listResponse"] = settled.get("listResponse")
    observed["explainResponse"] = settled.get("explainResponse")
    return observed


def phase_ready(state):
    pid = require_same_process(state)
    probe, token = probe_and_token(state, wait=True)
    response = probe.request(token, "whoami")
    if probe.code(response) != "ok":
        raise RuntimeError("readiness whoami failed: %r" % response)
    settled = read_attention(probe, token, state["pane"])
    if not isinstance(settled.get("record"), dict):
        raise RuntimeError("readiness list omitted fixture pane: %r" % settled)
    return {
        "action": "ready",
        "at": time.time(),
        "pid": pid,
        "wireResponse": response,
        "paneRecord": settled["record"],
        "effectiveAttention": settled["record"].get("attention"),
    }


def validate_label(label):
    if not label or len(label) > 120 or "\n" in label or "\r" in label:
        raise RuntimeError("phase label must be 1-120 characters on one line")
    return label


def send_report(state, label, state_path=None):
    validate_label(label)
    require_background(state)
    probe, token = probe_and_token(state)
    sequence = spend_sequence(state, state_path)
    # Spend the sequence before touching the wire. If the app accepts the frame
    # and the following observation times out, a retry must not reuse a sequence
    # whose outcome is now unknown.
    response = probe.request(
        token, "report",
        {"state": "blocked", "text": label, "seq": sequence, "ttl": 1800},
    )
    if probe.code(response) != "ok":
        raise RuntimeError("report was not accepted: %r" % response)
    settled = await_attention(probe, token, state["pane"], "asking", sequence)
    observed = observed_action(response, settled)
    observed.update({
        "action": "trigger",
        "at": time.time(),
        "pid": state["pid"],
        "appWasBackground": True,
        "label": label,
        "sequence": sequence,
    })
    return observed


def release_report(state):
    probe, token = probe_and_token(state)
    response = probe.request(token, "report", {"release": True})
    if probe.code(response) != "ok":
        raise RuntimeError("release was not accepted: %r" % response)
    settled = await_attention(probe, token, state["pane"], None)
    observed = observed_action(response, settled)
    observed.update({"action": "release", "at": time.time(), "pid": state["pid"]})
    return observed


def phase_release_new(state, label, state_path=None):
    require_same_process(state)
    released = release_report(state)
    raised = send_report(state, label, state_path)
    return {
        "action": "release-new",
        "at": time.time(),
        "pid": state["pid"],
        "release": released,
        "newReport": raised,
    }


def await_wire_code(probe, token, wanted):
    def read():
        response = probe.request(token, "whoami")
        return {"code": probe.code(response), "response": response}

    return monotonic_wait(read, lambda value: value["code"] == wanted)


def phase_notifications(state, enabled):
    require_same_process(state)
    probe, token = probe_and_token(state)
    config = read_json(state["config"])

    # The channel gate is a visible fence for the same settings snapshot the
    # notifier receives. Reopen it immediately with notifications unchanged so
    # later phases can continue over the same socket and process.
    closed = settings_document(config, enabled=enabled, channel_enabled=False)
    atomic_json(state["config"], closed)
    disabled = await_wire_code(probe, token, "disabled")

    reopened = settings_document(closed, enabled=enabled, channel_enabled=True)
    atomic_json(state["config"], reopened)
    ready = await_wire_code(probe, token, "ok")
    settled = read_attention(probe, token, state["pane"])
    return {
        "action": "notifications",
        "at": time.time(),
        "pid": state["pid"],
        "notificationsEnabled": enabled,
        "propagationFence": {
            "closedCode": disabled["code"],
            "closedResponse": disabled["response"],
            "reopenedCode": ready["code"],
            "reopenedResponse": ready["response"],
        },
        "effectiveAttention": (settled.get("record") or {}).get("attention"),
        "paneRecord": settled.get("record"),
    }


def phase_delivered(state, label):
    validate_label(label)
    pid = require_same_process(state)
    command_path, result_path = require_delivery_state(state)
    command_id = uuid.uuid4().hex
    if os.path.exists(result_path):
        os.unlink(result_path)
    atomic_json(command_path, {"action": "delivered", "id": command_id})
    document = await_delivery_result(result_path, command_id)
    if document.get("error"):
        raise RuntimeError("delivery observer returned error: %s" % document["error"])
    try:
        observer_pid = int(document["pid"])
    except (KeyError, TypeError, ValueError):
        raise RuntimeError("delivery observer omitted pid")
    if observer_pid != pid:
        raise RuntimeError(
            "delivery observer pid %s is not the fixture pid %s" % (observer_pid, pid)
        )
    try:
        os.unlink(result_path)
    except FileNotFoundError:
        pass
    return {
        "action": "delivered",
        "at": time.time(),
        "pid": pid,
        "label": label,
        "observerPid": observer_pid,
        "notifications": sanitize_delivery_notifications(document),
    }


def phase_snapshot(state, label):
    require_same_process(state)
    probe, token = probe_and_token(state)
    settled = read_attention(probe, token, state["pane"])
    observed = observed_action(settled["listResponse"], settled)
    observed.update({
        "action": "snapshot", "at": time.time(), "pid": state["pid"], "label": label,
    })
    return observed


def append_observation(state, observation):
    path = pathlib.Path(state["report"])
    report = read_json(path) if path.exists() else new_report(state)
    report["phases"].append(observation)
    atomic_json(path, report)


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, help="fixture.json printed by run.sh")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("ready")
    trigger = subparsers.add_parser("trigger")
    trigger.add_argument("--label", required=True)
    release_new = subparsers.add_parser("release-new")
    release_new.add_argument("--label", required=True)
    notifications = subparsers.add_parser("notifications")
    notifications.add_argument("value", choices=("off", "on"))
    snapshot = subparsers.add_parser("snapshot")
    snapshot.add_argument("--label", required=True)
    delivered = subparsers.add_parser("delivered")
    delivered.add_argument("--label", required=True)
    subparsers.add_parser("report")
    subparsers.add_parser("stop")
    return parser.parse_args()


def run_locked(arguments):
    state_path = pathlib.Path(arguments.state).resolve()
    state = read_json(state_path)
    lock_path = pathlib.Path(state["evidence"]) / ".phase.lock"
    lock_path.touch(mode=0o600, exist_ok=True)
    with open(lock_path, "r+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_json(state_path)

        if arguments.command == "report":
            print(json.dumps(read_json(state["report"]), indent=2, sort_keys=True))
            return
        if arguments.command == "stop":
            pathlib.Path(state["stopMarker"]).touch(mode=0o600, exist_ok=True)
            observation = {
                "action": "stop", "at": time.time(), "pid": state["pid"],
                "sameProcessAtStop": process_command(state["pid"]) == state["binary"],
            }
        elif arguments.command == "ready":
            observation = phase_ready(state)
        elif arguments.command == "trigger":
            observation = send_report(state, arguments.label, state_path)
        elif arguments.command == "release-new":
            observation = phase_release_new(state, arguments.label, state_path)
        elif arguments.command == "notifications":
            observation = phase_notifications(state, arguments.value == "on")
        elif arguments.command == "snapshot":
            observation = phase_snapshot(state, arguments.label)
        elif arguments.command == "delivered":
            observation = phase_delivered(state, arguments.label)
        else:
            raise RuntimeError("unsupported phase %s" % arguments.command)

        append_observation(state, observation)
        atomic_json(state_path, state)
        print(json.dumps(observation, indent=2, sort_keys=True))


def main():
    arguments = parse_arguments()
    try:
        run_locked(arguments)
    except Exception as error:
        print("notification-permission phase failed: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
