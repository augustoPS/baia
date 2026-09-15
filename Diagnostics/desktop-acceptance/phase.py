#!/usr/bin/env python3
"""Phase helper for the desktop-acceptance fixture.

Prepares named scratch scenarios, reports the fixture's safe identity, imports
reviewed case observations into the ledger, validates evidence references, and
writes the owned stop marker. It implements no desktop input: every click,
key press, VoiceOver action, and screenshot belongs to the coordinator's
desktop tools. It never signals a process; the runner owns the copied app and
takes stop/launch requests through an owned request file.

Runs on the system /usr/bin/python3 (3.9) with the standard library only.
"""

import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import uuid

STATE_VERSION = 1
LEDGER_VERSION = 1
RESULT_VERSION = 1

SETTLE_SECONDS = 15.0
READY_SECONDS = 45.0
RUNNER_SECONDS = 60.0
POLL_SECONDS = 0.1

SCENARIOS = (
    "accessibility", "recovery", "settings", "commands", "windows",
    "busy-close", "input",
)
ARMS = {
    "accessibility": ("default", "feedback"),
    "recovery": ("malformed", "malformed-write-refused", "quit-save-refused"),
    "settings": ("default", "wrong-type", "long-root"),
    "commands": ("default", "empty-root"),
    "windows": ("default",),
    "busy-close": ("busy", "idle"),
    "input": ("default",),
}
RESULTS = ("PASS", "FAIL", "BLOCKED")
EVIDENCE_KINDS = (
    "screenshot", "video", "frames", "ax", "caption", "wire", "terminal",
    "hash", "log", "file",
)
VISUAL_KINDS = ("screenshot", "video", "frames")
# A record whose only basis is one of these words inferred its outcome from
# the fact that input was delivered or an API call returned. That is not an
# observation of the product.
NON_OBSERVATIONS = ("input-delivered", "api-success", "ax-press-returned")
OBSERVATIONS = (
    "ui-readback", "persisted-value", "wire-result", "pixels", "caption",
    "terminal-bytes", "process-state", "file-bytes",
)
SECRET_KEYS = ("token", "capability", "secret", "baia_token")

MALFORMED_SESSION = b"{ broken session, preserve me"
STOP_MARKER_NAME = "coordinator-stop"
REQUEST_NAME = "runner-request.json"
RESULT_NAME = "runner-result.json"
LEDGER_NAME = "ledger.json"
SCRATCH_KEYS = (
    "config", "zdot", "tokenDir", "stopMarker", "runnerRequest",
    "runnerResult", "app", "projectsDir", "jobsDir",
)

WINDOW_CENSUS_JS = """
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = parseInt(argv[0], 10);
  const ref = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0);
  const array = ObjC.deepUnwrap(ObjC.castRefToObject(ref)) || [];
  const mine = array.filter(w => w.kCGWindowOwnerPID === pid).map(w => ({
    number: w.kCGWindowNumber, layer: w.kCGWindowLayer,
    name: w.kCGWindowName || '', onscreen: !!w.kCGWindowIsOnscreen,
    bounds: w.kCGWindowBounds}));
  return JSON.stringify(mine);
}
"""


class FixtureError(RuntimeError):
    """A refused operation. The message names the exact rule that refused."""


# MARK: files


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


def write_private(path, data):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        data = data.encode("utf-8")
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def monotonic_wait(read, accepts, seconds=SETTLE_SECONDS, what="condition"):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = read()
        if accepts(last):
            return last
        time.sleep(POLL_SECONDS)
    raise FixtureError("%s did not settle within %.0f seconds; last=%r" % (what, seconds, last))


# MARK: ownership


def realpath_within(path, root):
    """True when path resolves strictly inside root after symlink collapse."""
    if not path or not root:
        return False
    resolved = os.path.realpath(path)
    base = os.path.realpath(root)
    prefix = base if base.endswith(os.sep) else base + os.sep
    return resolved.startswith(prefix) and resolved != base


def require_within(path, root, what):
    if not path or not os.path.isabs(str(path)):
        raise FixtureError("%s must be an absolute path" % what)
    if not realpath_within(path, root):
        raise FixtureError("%s is not inside its owner: %s" % (what, path))
    return os.path.realpath(path)


def require_basename(path, name, what):
    if os.path.basename(path) != name or os.path.basename(os.path.realpath(path)) != name:
        raise FixtureError("%s must be named %s" % (what, name))


def require_state_ownership(state, state_path):
    """Refuse a state document whose paths point outside what this run owns.

    Every mutable path (session, config, markers, request files) must live in
    the scratch or support directory that the runner created, the evidence
    directory must live under the acceptance evidence root, and the state file
    itself must live in that evidence directory. A document that fails any of
    these is not this fixture's, whatever its run id says.
    """
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise FixtureError("state document is not a desktop-acceptance fixture")
    for key in ("runId", "scratch", "support", "evidence", "evidenceRoot", "repoRoot", "session"):
        if not isinstance(state.get(key), str) or not state[key]:
            raise FixtureError("state is missing %s" % key)
    scratch = state["scratch"]
    support = state["support"]
    for key in ("scratch", "support", "evidence", "evidenceRoot", "repoRoot"):
        if not os.path.isabs(state[key]):
            raise FixtureError("state %s must be absolute" % key)
    if os.path.basename(support) in ("baia", "baia-dev"):
        raise FixtureError("state support directory names a product support directory")
    require_within(state["evidence"], state["evidenceRoot"], "evidence directory")
    require_within(str(state_path), state["evidence"], "state file")
    require_within(state["session"], support, "session path")
    require_basename(state["session"], "session.json", "session path")
    for key in SCRATCH_KEYS:
        if state.get(key):
            require_within(state[key], scratch, key)
    require_basename(state["stopMarker"], STOP_MARKER_NAME, "stop marker")
    require_basename(state["runnerRequest"], REQUEST_NAME, "runner request")
    require_basename(state["runnerResult"], RESULT_NAME, "runner result")
    if state.get("binary"):
        require_within(state["binary"], state["app"], "copied binary")
    if state.get("socket"):
        require_within(state["socket"], support, "socket path")
    pid = state.get("pid")
    if pid is not None and (not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1):
        raise FixtureError("state pid is not a process id")
    return state


def process_command(pid):
    try:
        return subprocess.check_output(
            ["/bin/ps", "-p", str(pid), "-o", "command="],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return None


def same_process(state):
    pid = state.get("pid")
    if not pid:
        return False
    return process_command(pid) == state.get("binary")


def require_same_process(state):
    pid = state.get("pid")
    if not pid:
        raise FixtureError("no copied app is launched; prepare a scenario first")
    command = process_command(pid)
    if command != state["binary"]:
        raise FixtureError(
            "fixture pid %s is not the recorded copied binary; command=%r" % (pid, command)
        )
    return pid


# MARK: normal-state fingerprints


def fingerprint_lines(paths):
    lines = []
    for path in paths:
        if os.path.isfile(path):
            lines.append("%s\tpresent\t%s" % (path, sha256_of(path)))
        else:
            lines.append("%s\tabsent\t" % path)
    return lines


def read_fingerprints(path):
    with open(path, encoding="utf-8") as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


def fingerprint_comparison(state):
    """Compare the runner's saved normal-state fingerprints with the present."""
    saved_path = state.get("fingerprintsBefore")
    if not saved_path or not os.path.isfile(saved_path):
        return {"available": False, "unchanged": None, "changed": []}
    saved = read_fingerprints(saved_path)
    paths = [line.split("\t", 1)[0] for line in saved]
    now = fingerprint_lines(paths)
    changed = [line.split("\t", 1)[0] for line, current in zip(saved, now) if line != current]
    return {"available": True, "unchanged": not changed, "changed": changed}


# MARK: runner protocol


def request_runner(state, action, seconds=RUNNER_SECONDS, extra=None):
    """Ask the runner (the process owner) to stop or launch the copied app.

    The request is a file in the scratch directory with a fresh id. The runner
    answers in the result file with the same id. Any result carrying another id
    is ignored, and no answer within the bound is a failure, never a success.
    """
    if action not in ("stop", "launch", "expect-quit"):
        raise FixtureError("runner action must be stop, launch, or expect-quit")
    request_path = state["runnerRequest"]
    result_path = state["runnerResult"]
    request_id = uuid.uuid4().hex
    if os.path.exists(result_path):
        os.unlink(result_path)
    document = {"id": request_id, "action": action, "at": time.time()}
    if extra:
        document.update(extra)
    atomic_json(request_path, document)

    def read():
        if not os.path.exists(result_path):
            return None
        try:
            result = read_json(result_path)
        except (OSError, ValueError):
            return None
        if not isinstance(result, dict) or result.get("id") != request_id:
            return None
        return result

    result = monotonic_wait(read, lambda value: value is not None, seconds=seconds,
                            what="runner %s" % action)
    try:
        os.unlink(result_path)
    except FileNotFoundError:
        pass
    if result.get("ok") is not True:
        raise FixtureError("runner refused %s: %s" % (action, result.get("error")))
    return result


# MARK: readiness


def window_census(pid):
    """Windows owned by pid from the window server. Takes no focus."""
    try:
        output = subprocess.check_output(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", WINDOW_CENSUS_JS, str(pid)],
            text=True, stderr=subprocess.STDOUT, timeout=10,
        ).strip()
        return json.loads(output.splitlines()[-1])
    except (subprocess.SubprocessError, ValueError, IndexError) as error:
        return {"error": str(error)}


def visible_windows(census):
    if not isinstance(census, list):
        return []
    return [
        window for window in census
        if window.get("onscreen") and window.get("layer") == 0
        and (window.get("bounds") or {}).get("Height", 0) > 100
    ]


def load_control_probe(path):
    import importlib.util
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("desktop_acceptance_control_probe", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_probe(state):
    control = load_control_probe(state["controlProbe"])
    return control.Probe(
        state["socket"], state["tokenDir"], state["config"], state["session"],
        state["tokenDir"], state["scratch"],
    )


def await_ready(state, panes, seconds=READY_SECONDS):
    """Prove fresh readiness: live pid, socket, every seeded pane's private
    capability reported, whoami ok, list naming every pane, one visible window.

    Capabilities are read by the control probe from the scratch token directory
    and are never copied into the returned document.
    """
    pid = require_same_process(state)
    probe = make_probe(state)

    def tokens():
        if not os.path.exists(state["socket"]):
            return {}
        return probe.tokens()

    found = monotonic_wait(
        tokens, lambda value: all(pane in value for pane in panes),
        seconds=seconds, what="pane capability reports",
    )
    whoami, listed_panes = {}, set()
    # Restored siblings have independent scopes. Prove each pane through its
    # own capability instead of expecting one token to disclose every sibling.
    for pane in panes:
        token = found[pane]
        whoami[pane] = monotonic_wait(
            lambda: probe.request(token, "whoami"),
            lambda value: probe.code(value) == "ok"
            and pane in (probe.named_panes(value) or []),
            seconds=seconds, what="whoami for " + pane,
        )
        listed = monotonic_wait(
            lambda: probe.request(token, "list"),
            lambda value: probe.code(value) == "ok"
            and pane in (probe.named_panes(value) or []),
            seconds=seconds, what="list for " + pane,
        )
        listed_panes.update(probe.named_panes(listed))
    windows = monotonic_wait(
        lambda: window_census(pid), lambda value: len(visible_windows(value)) >= 1,
        seconds=seconds, what="visible window",
    )
    if process_command(pid) != state["binary"]:
        raise FixtureError("copied app pid %s changed identity during readiness" % pid)
    return {
        "pid": pid,
        "socket": state["socket"],
        "panesReported": sorted(found.keys()),
        "whoami": whoami,
        "listedPanes": sorted(listed_panes),
        "windows": visible_windows(windows),
        "at": time.time(),
    }


def await_process_window_ready(state, seconds=READY_SECONDS):
    """Prove only exact process identity and at least one visible window.

    This is the relaunch boundary. Restored panes do not publish fresh
    capabilities until each native tab is activated, including a saved
    selected tab.
    """
    pid = require_same_process(state)
    windows = monotonic_wait(
        lambda: window_census(pid), lambda value: len(visible_windows(value)) >= 1,
        seconds=seconds, what="visible window",
    )
    if process_command(pid) != state["binary"]:
        raise FixtureError("copied app pid %s changed identity during readiness" % pid)
    return {"pid": pid, "windows": visible_windows(windows), "at": time.time()}


# MARK: scenarios


def leaf_tab(tab, pane):
    return {
        "id": tab,
        "focusedPane": {"rawValue": pane},
        "tree": {"leaf": {"_0": {"rawValue": pane}}},
    }


def split_tab(tab, first, second):
    return {
        "id": tab,
        "focusedPane": {"rawValue": first},
        "tree": {
            "split": {
                "axis": "horizontal",
                "ratio": 0.5,
                "first": {"leaf": {"_0": {"rawValue": first}}},
                "second": {"leaf": {"_0": {"rawValue": second}}},
            }
        },
    }


def pane_state(identifier, directory):
    return {"id": {"rawValue": identifier}, "workingDirectory": str(directory)}


def session_document(groups, active, panes):
    return {
        "schemaVersion": 2,
        "groups": groups,
        "activeGroup": active,
        "panes": panes,
    }


def new_id():
    return str(uuid.uuid4()).upper()


def config_document(project_roots, sidebar="off", **overrides):
    document = {
        "notificationsEnabled": False,
        "restoreSession": True,
        "controlChannelEnabled": True,
        "controlAllowRun": False,
        "controlAllowRead": True,
        "sidebar": sidebar,
        "projectRoots": [str(root) for root in project_roots],
        "backgroundHex": "#141414",
        "backgroundOpacity": 0.42,
        "windowPadding": 8,
    }
    document.update(overrides)
    return document


def zshenv_text(token_dir):
    return (
        "umask 077\n"
        "printf 'pane=%%s\\ntoken=%%s\\n' \"$BAIA_PANE\" \"$BAIA_TOKEN\" > \"%s/pane-$BAIA_PANE.env\"\n"
        "chmod 600 \"%s/pane-$BAIA_PANE.env\"\n"
        "export HISTFILE=/dev/null\n"
    ) % (token_dir, token_dir)


def busy_zshrc_text(scratch, jobs_dir):
    """The foreground job hook. It records the job's pid with the start time
    ps reported at that moment, which is the identity the runner checks before
    it ever signals that pid."""
    return (
        "if [ -e \"%s/arm-busy\" ]; then\n"
        "  sleep 300 &\n"
        "  printf 'pid=%%s\\nstarted=%%s\\nshell=%%s\\npane=%%s\\n' \"$!\" "
        "\"$(/bin/ps -p $! -o lstart=)\" \"$$\" \"$BAIA_PANE\" > \"%s/sleep-$$.job\"\n"
        "  fg %%1 > /dev/null 2>&1\n"
        "fi\n"
    ) % (scratch, jobs_dir)


def parse_job_record(text):
    fields = {}
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key:
            fields[key.strip()] = value.strip()
    return fields


def process_start(pid):
    try:
        return subprocess.check_output(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return None


def build_scenario(state, scenario, arm):
    """Return the scratch documents for one scenario without writing anything.

    Everything lands in the run's scratch, support, or evidence directories.
    The result names each pane, project, and file the coordinator will drive.
    """
    if scenario not in SCENARIOS:
        raise FixtureError("unknown scenario %s" % scenario)
    arm = arm or ARMS[scenario][0]
    if arm not in ARMS[scenario]:
        raise FixtureError("scenario %s has no arm %s" % (scenario, arm))
    scratch = state["scratch"]
    projects = pathlib.Path(state["projectsDir"])
    jobs = state["jobsDir"]
    prepared = {
        "scenario": scenario,
        "arm": arm,
        "panes": [],
        "projects": [],
        "files": {},
        "session": None,
        "sessionBytes": None,
        "config": None,
        "zshrc": None,
        "armBusy": False,
        "support": {"mode": None, "sessionMode": None},
        "notes": [],
    }

    def project(name, files=None):
        root = projects / name
        prepared["projects"].append(str(root))
        for relative, text in (files or {}).items():
            prepared["files"][str(root / relative)] = text
        return root

    if scenario == "accessibility":
        root = project("A01-files", {"alpha.txt": "alpha\n", "folder/beta.txt": "beta\n"})
        if arm == "feedback":
            prepared["files"][str(root / "refuse\x01.txt")] = "control-character refusal fixture\n"
        pane, tab, group = new_id(), new_id(), new_id()
        prepared["panes"] = [pane]
        prepared["session"] = session_document(
            [{"id": group, "tabs": [leaf_tab(tab, pane)], "selectedTab": tab}],
            group, [pane_state(pane, root)])
        prepared["config"] = config_document([root], sidebar="files")
        prepared["notes"].append(
            "A02 needs the raw stdin recorder running in the pane before any card action; "
            "see state.recorder.")
    elif scenario == "recovery":
        root = project("A03-recovery", {"README.txt": "recovery scratch\n"})
        pane, tab, group = new_id(), new_id(), new_id()
        prepared["panes"] = [pane]
        prepared["config"] = config_document([root])
        valid = session_document(
            [{"id": group, "tabs": [leaf_tab(tab, pane)], "selectedTab": tab}],
            group, [pane_state(pane, root)])
        if arm == "quit-save-refused":
            prepared["session"] = valid
            prepared["support"] = {"mode": 0o500, "sessionMode": 0o400}
            prepared["notes"].append(
                "session.json and the support directory are read-only; the quit save "
                "must fail until `repair` restores them.")
        else:
            prepared["sessionBytes"] = MALFORMED_SESSION
            prepared["panes"] = []
            if arm == "malformed-write-refused":
                prepared["support"] = {"mode": 0o500, "sessionMode": 0o400}
                prepared["notes"].append(
                    "backup/write of the malformed session is refused until `repair`.")
    elif scenario == "settings":
        name = "S03-long-root-" + ("x" * 160) if arm == "long-root" else "S01-settings"
        root = project(name, {"sample.txt": "settings scratch\n"})
        pane, tab, group = new_id(), new_id(), new_id()
        prepared["panes"] = [pane]
        prepared["session"] = session_document(
            [{"id": group, "tabs": [leaf_tab(tab, pane)], "selectedTab": tab}],
            group, [pane_state(pane, root)])
        if arm == "wrong-type":
            prepared["config"] = config_document([root], fontSize="big", windowPadding=24)
            prepared["notes"].append(
                "fontSize is a string on purpose; windowPadding 24 is the valid sibling.")
        else:
            prepared["config"] = config_document([root])
    elif scenario == "commands":
        if arm == "empty-root":
            pane, tab, group = new_id(), new_id(), new_id()
            prepared["panes"] = [pane]
            prepared["session"] = session_document(
                [{"id": group, "tabs": [leaf_tab(tab, pane)], "selectedTab": tab}],
                group, [pane_state(pane, scratch)])
            prepared["config"] = config_document([])
        else:
            first = project("C01-first", {"terminal-text.txt": "terminal marker one\n"})
            second = project("C01-second", {"settings-text.txt": "settings marker two\n"})
            pane_a, pane_b = new_id(), new_id()
            tab_a, tab_b = new_id(), new_id()
            group_a, group_b = new_id(), new_id()
            prepared["panes"] = [pane_a, pane_b]
            prepared["session"] = session_document(
                [
                    {"id": group_a, "tabs": [leaf_tab(tab_a, pane_a)], "selectedTab": tab_a},
                    {"id": group_b, "tabs": [leaf_tab(tab_b, pane_b)], "selectedTab": tab_b},
                ],
                group_a, [pane_state(pane_a, first), pane_state(pane_b, second)])
            prepared["config"] = config_document([first, second])
    elif scenario == "windows":
        root = project("C02-windows", {"one.txt": "one\n"})
        panes = [new_id() for _ in range(4)]
        tabs = [new_id() for _ in range(4)]
        groups = [new_id(), new_id()]
        prepared["panes"] = panes
        prepared["session"] = session_document(
            [
                {"id": groups[0], "tabs": [leaf_tab(tabs[0], panes[0]), leaf_tab(tabs[1], panes[1])],
                 "selectedTab": tabs[0]},
                {"id": groups[1], "tabs": [leaf_tab(tabs[2], panes[2]), leaf_tab(tabs[3], panes[3])],
                 "selectedTab": tabs[2]},
            ],
            groups[0], [pane_state(pane, root) for pane in panes])
        prepared["config"] = config_document([root])
        prepared["logical"] = {"groups": groups, "tabs": tabs}
    elif scenario == "busy-close":
        root = project("C03-busy-close", {"job.txt": "busy scratch\n"})
        panes = [new_id() for _ in range(3)]
        tab_a, tab_b, group = new_id(), new_id(), new_id()
        prepared["panes"] = panes
        prepared["session"] = session_document(
            [{"id": group, "tabs": [leaf_tab(tab_a, panes[0]), split_tab(tab_b, panes[1], panes[2])],
              "selectedTab": tab_a}],
            group, [pane_state(pane, root) for pane in panes])
        prepared["config"] = config_document([root], restoreSession=True)
        prepared["zshrc"] = busy_zshrc_text(scratch, jobs)
        prepared["armBusy"] = arm == "busy"
        prepared["notes"].append(
            "every new shell runs a foreground `sleep 300` while arm-busy exists; "
            "`report` lists the recorded job pids and whether each is alive.")
    elif scenario == "input":
        root = project("I01-input", {"paste-source.txt": "line one\nline two\necho MARKER-NOT-RUN\n"})
        pane, tab, group = new_id(), new_id(), new_id()
        prepared["panes"] = [pane]
        prepared["session"] = session_document(
            [{"id": group, "tabs": [leaf_tab(tab, pane)], "selectedTab": tab}],
            group, [pane_state(pane, root)])
        prepared["config"] = config_document([root], optionAsAlt=True)
        prepared["notes"].append(
            "run the raw stdin recorder in the pane before sending key events; "
            "see state.recorder.")
    return prepared


def repair_permissions(state):
    """Undo a refused-write arm: writable support directory and session file."""
    support = state["support"]
    session = state["session"]
    repaired = []
    if os.path.isdir(support):
        os.chmod(support, 0o700)
        repaired.append(support)
    if os.path.exists(session):
        os.chmod(session, 0o600)
        repaired.append(session)
    return repaired


def seed_scenario(state, prepared):
    """Write the prepared documents. Only scratch/support paths are touched."""
    scratch = state["scratch"]
    support = state["support"]
    repair_permissions(state)
    for path in prepared["projects"]:
        require_within(path, scratch, "project root")
        pathlib.Path(path).mkdir(parents=True, exist_ok=True)
    for path, text in prepared["files"].items():
        require_within(path, scratch, "seeded file")
        write_private(path, text)
    if prepared["scenario"] == "accessibility":
        for root in prepared["projects"]:
            result = subprocess.run(["git", "-C", root, "init", "--quiet"],
                                    capture_output=True, text=True)
            if result.returncode:
                raise FixtureError("could not initialize the scratch accessibility repository")
    session = require_within(state["session"], support, "session")
    if prepared["sessionBytes"] is not None:
        write_private(session, prepared["sessionBytes"])
    elif prepared["session"] is not None:
        atomic_json(session, prepared["session"])
    elif os.path.exists(session):
        os.unlink(session)
    config = require_within(state["config"], scratch, "config")
    atomic_json(config, prepared["config"])
    zdot = require_within(state["zdot"], scratch, "zdot")
    write_private(os.path.join(zdot, ".zshenv"), zshenv_text(state["tokenDir"]))
    zshrc = os.path.join(zdot, ".zshrc")
    if prepared["zshrc"]:
        write_private(zshrc, prepared["zshrc"])
    elif os.path.exists(zshrc):
        os.unlink(zshrc)
    arm_busy = os.path.join(scratch, "arm-busy")
    if prepared["armBusy"]:
        write_private(arm_busy, "")
    elif os.path.exists(arm_busy):
        os.unlink(arm_busy)
    jobs = pathlib.Path(require_within(state["jobsDir"], scratch, "jobs"))
    jobs.mkdir(parents=True, exist_ok=True)
    for stale in jobs.glob("*.job"):
        stale.unlink()
    tokens = pathlib.Path(require_within(state["tokenDir"], scratch, "tokens"))
    tokens.mkdir(parents=True, exist_ok=True)
    os.chmod(str(tokens), 0o700)
    for stale in tokens.glob("pane-*.env"):
        stale.unlink()
    hashes = {}
    if os.path.exists(session):
        hashes["session"] = sha256_of(session)
    hashes["config"] = sha256_of(config)
    if prepared["arm"] == "quit-save-refused":
        return hashes  # Keep startup writable until the control socket is ready.
    if prepared["support"]["sessionMode"] is not None and os.path.exists(session):
        os.chmod(session, prepared["support"]["sessionMode"])
    if prepared["support"]["mode"] is not None:
        os.chmod(support, prepared["support"]["mode"])
    return hashes


def scenario_summary(prepared, hashes):
    summary = {key: value for key, value in prepared.items() if key not in ("session", "config")}
    summary["files"] = sorted(prepared["files"].keys())
    summary["sessionBytesHex"] = (
        prepared["sessionBytes"].hex() if prepared["sessionBytes"] is not None else None
    )
    summary["sessionBytes"] = None
    summary["configKeys"] = sorted(prepared["config"].keys())
    summary["hashes"] = hashes
    summary["support"] = {
        key: (oct(value) if isinstance(value, int) else value)
        for key, value in prepared["support"].items()
    }
    return summary


def phase_prepare(state, state_path, scenario, arm, runner=request_runner, ready=await_ready):
    """End the previous owned app, seed the scenario, relaunch, prove readiness."""
    prepared = build_scenario(state, scenario, arm)
    batch = int(state.get("batches", 0)) + 1
    started = time.time()
    if state.get("pid"):
        runner(state, "stop")
        state["pid"] = None
        state["stoppedAt"] = time.time()
    hashes = seed_scenario(state, prepared)
    log_name = "app-%02d-%s-%s.log" % (batch, scenario, prepared["arm"])
    launched = runner(state, "launch", extra={"log": log_name})
    pid = launched.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        raise FixtureError("runner launch answered without a pid: %r" % launched)
    if launched.get("binary") != state["binary"]:
        raise FixtureError("runner launched a different binary: %r" % launched.get("binary"))
    state["pid"] = pid
    state["batches"] = batch
    state["launchedAt"] = launched.get("at", time.time())
    state["appLog"] = launched.get("log")
    state["scenario"] = None
    state["deadlineAt"] = launched.get("deadlineAt")
    atomic_json(state_path, state)
    summary = scenario_summary(prepared, hashes)
    summary.update({"batch": batch, "pid": pid, "startedAt": started})
    try:
        readiness = ready(state, prepared["panes"]) if prepared["panes"] else {
            "pid": require_same_process(state),
            "note": "no pane seeded (malformed session); readiness is the recovery dialog, "
                    "which the coordinator observes",
            "windows": None,
            "at": time.time(),
        }
    except FixtureError as error:
        summary["readiness"] = {"ok": False, "error": str(error), "at": time.time()}
        state["scenario"] = summary
        atomic_json(state_path, state)
        raise FixtureError("scenario %s prepared but not ready: %s" % (scenario, error))
    if prepared["arm"] == "quit-save-refused":
        os.chmod(state["session"], prepared["support"]["sessionMode"])
        os.chmod(state["support"], prepared["support"]["mode"])
    summary["readiness"] = dict(readiness, ok=True)
    state["scenario"] = summary
    atomic_json(state_path, state)
    scenario_path = pathlib.Path(state["evidence"]) / "scenarios" / (
        "%02d-%s-%s.json" % (batch, scenario, prepared["arm"]))
    atomic_json(scenario_path, summary)
    return {
        "action": "prepare", "at": time.time(), "pid": pid, "scenario": scenario,
        "arm": prepared["arm"], "batch": batch, "panes": prepared["panes"],
        "projects": prepared["projects"], "files": summary["files"],
        "readiness": summary["readiness"], "scenarioFile": str(scenario_path),
        "notes": prepared["notes"],
    }


def session_panes(state):
    """Pane ids in the session file the app itself last wrote, or []."""
    try:
        document = read_json(state["session"])
    except (OSError, ValueError):
        return []
    panes = []
    for pane in (document.get("panes") or []) if isinstance(document, dict) else []:
        identifier = (pane.get("id") or {}).get("rawValue") if isinstance(pane, dict) else None
        if isinstance(identifier, str):
            panes.append(identifier)
    return panes


def selected_session_panes(document):
    """Focused pane of the selected tab in every schema-2 session group.

    Relaunch cannot probe hidden tabs until the operator activates them, but a
    malformed selection is not evidence of readiness and must be refused.
    """
    if not isinstance(document, dict) or document.get("schemaVersion") != 2:
        raise FixtureError("relaunch requires a schema-2 session document")
    groups = document.get("groups")
    if not isinstance(groups, list) or not groups:
        raise FixtureError("schema-2 session has no groups")
    selected_panes = []
    for index, group in enumerate(groups):
        if not isinstance(group, dict):
            raise FixtureError("session group %d is malformed" % index)
        selected = group.get("selectedTab")
        tabs = group.get("tabs")
        if not isinstance(selected, str) or not isinstance(tabs, list):
            raise FixtureError("session group %d has malformed selectedTab or tabs" % index)
        matches = [tab for tab in tabs if isinstance(tab, dict) and tab.get("id") == selected]
        if len(matches) != 1:
            raise FixtureError("session group %d selectedTab does not name exactly one tab" % index)
        focused = matches[0].get("focusedPane")
        pane = focused.get("rawValue") if isinstance(focused, dict) else None
        if not isinstance(pane, str) or not pane:
            raise FixtureError("session group %d selected tab has no focusedPane" % index)
        selected_panes.append(pane)
    return selected_panes


def relaunch_session_scope(state):
    try:
        document = read_json(state["session"])
    except (OSError, ValueError) as error:
        raise FixtureError("relaunch session is missing or unreadable: %s" % error)
    if not isinstance(document, dict) or document.get("schemaVersion") != 2:
        raise FixtureError("relaunch requires a schema-2 session document")
    pane_records = document.get("panes")
    if not isinstance(pane_records, list) or not pane_records:
        raise FixtureError("schema-2 session has no pane registrations")
    panes = []
    for index, record in enumerate(pane_records):
        identifier = (record.get("id") or {}).get("rawValue") if isinstance(record, dict) else None
        if not isinstance(identifier, str) or not identifier:
            raise FixtureError("session pane registration %d is malformed" % index)
        if identifier in panes:
            raise FixtureError("session pane registration %s is duplicated" % identifier)
        panes.append(identifier)
    selected = selected_session_panes(document)
    registered = set(panes)
    groups = document["groups"]
    group_ids = [group.get("id") for group in groups if isinstance(group, dict)]
    active_group = document.get("activeGroup")
    if not isinstance(active_group, str) or group_ids.count(active_group) != 1:
        raise FixtureError("session activeGroup does not name exactly one group")
    for group_index, group in enumerate(groups):
        for tab_index, tab in enumerate(group["tabs"]):
            focused = tab.get("focusedPane") if isinstance(tab, dict) else None
            pane = focused.get("rawValue") if isinstance(focused, dict) else None
            if not isinstance(pane, str) or not pane:
                raise FixtureError("session group %d tab %d has no focusedPane" %
                                   (group_index, tab_index))
            if pane not in registered:
                raise FixtureError("session focusedPane %s is absent from pane registrations" % pane)
    selected_set = set(selected)
    return panes, selected, [pane for pane in panes if pane not in selected_set]


def phase_await_quit(state, state_path, seconds, runner=request_runner):
    """Announce an expected quit (A03 Retry, C02 quit) and wait for the exact
    pid to end. The runner keeps the fixture alive instead of failing."""
    pid = require_same_process(state)
    runner(state, "expect-quit")
    state["awaitingQuit"] = {"pid": pid, "since": time.time()}
    atomic_json(state_path, state)
    monotonic_wait(
        lambda: process_command(pid), lambda value: value != state["binary"],
        seconds=seconds, what="expected quit of pid %d" % pid,
    )
    state["pid"] = None
    state["lastPid"] = pid
    state["awaitingQuit"] = None
    state["quitObservedAt"] = time.time()
    atomic_json(state_path, state)
    return {"action": "await-quit", "at": time.time(), "pid": pid, "quitObserved": True,
            "scenario": (state.get("scenario") or {}).get("scenario")}


def phase_relaunch(state, state_path, runner=request_runner, ready=await_process_window_ready):
    """Launch the same copy again on the session it wrote itself. No reseeding:
    session, config, and scratch files stay as the previous instance left them."""
    if state.get("pid") and same_process(state):
        raise FixtureError("the copied app is still running; await-quit or prepare first")
    scenario = state.get("scenario") or {}
    if not scenario:
        raise FixtureError("nothing to relaunch; prepare a scenario first")
    relaunches = int(state.get("relaunches", 0)) + 1
    log_name = "app-%02d-%s-relaunch-%d.log" % (
        scenario.get("batch", 0), scenario.get("scenario"), relaunches)
    launched = runner(state, "launch", extra={"log": log_name})
    pid = launched.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        raise FixtureError("runner launch answered without a pid: %r" % launched)
    if launched.get("binary") != state["binary"]:
        raise FixtureError("runner launched a different binary: %r" % launched.get("binary"))
    state["pid"] = pid
    state["relaunches"] = relaunches
    state["launchedAt"] = launched.get("at", time.time())
    state["appLog"] = launched.get("log")
    state["deadlineAt"] = launched.get("deadlineAt")
    atomic_json(state_path, state)
    try:
        panes, selected_panes, hidden_panes = relaunch_session_scope(state)
        readiness = ready(state)
    except FixtureError as error:
        scenario["relaunchReadiness"] = {"ok": False, "error": str(error), "at": time.time()}
        state["scenario"] = scenario
        atomic_json(state_path, state)
        raise FixtureError("relaunched but not ready: %s" % error)
    pending = {
        pane: "pending native activation, then per-pane capability and exact whoami verification"
        for pane in panes
    }
    scenario["relaunchReadiness"] = dict(
        readiness,
        ok=True,
        relaunch=relaunches,
        selectedSessionPanes=selected_panes,
        hiddenSessionPanes=hidden_panes,
        pendingPaneVerification=pending,
    )
    state["scenario"] = scenario
    atomic_json(state_path, state)
    return {"action": "relaunch", "at": time.time(), "pid": pid, "relaunch": relaunches,
            "sessionPanes": panes, "selectedSessionPanes": selected_panes,
            "hiddenSessionPanes": hidden_panes, "pendingPaneVerification": pending,
            "readiness": scenario["relaunchReadiness"],
            "scenario": scenario.get("scenario")}


# MARK: attention through the wire


def take_sequence(state):
    sequence = int(state.get("nextSequence", 1))
    state["nextSequence"] = sequence + 1
    return sequence


def spend_sequence(state, state_path=None):
    sequence = take_sequence(state)
    if state_path is not None:
        atomic_json(state_path, state)
    return sequence


def validate_label(label):
    if not label or len(label) > 120 or "\n" in label or "\r" in label:
        raise FixtureError("label must be 1-120 characters on one line")
    return label


def scenario_panes(state):
    scenario = state.get("scenario") or {}
    return list(scenario.get("panes") or [])


def pane_token(state, probe, pane):
    token = probe.tokens().get(pane)
    if not token:
        raise FixtureError("pane %s has not privately reported its capability" % pane)
    return token


def read_attention(probe, token, pane):
    listed = probe.request(token, "list")
    explained = probe.request(token, "explain")
    return {
        "listResponse": listed,
        "record": probe.record_of(listed, pane),
        "explanation": (explained.get("result") or {}).get("explanation"),
    }


def phase_attention(state, state_path, pane, reported, label, release):
    pid = require_same_process(state)
    panes = scenario_panes(state)
    if pane is None:
        if not panes:
            raise FixtureError("the current scenario seeded no pane")
        pane = panes[0]
    elif pane not in panes:
        raise FixtureError("pane %s is not one this scenario seeded" % pane)
    probe = make_probe(state)
    token = pane_token(state, probe, pane)
    if release:
        response = probe.request(token, "report", {"release": True})
        if probe.code(response) != "ok":
            raise FixtureError("release was not accepted: %r" % response)
        settled = monotonic_wait(
            lambda: read_attention(probe, token, pane),
            lambda value: (value.get("record") or {}).get("attention") is None,
            what="attention release",
        )
        return {
            "action": "attention", "at": time.time(), "pid": pid, "pane": pane,
            "release": True, "wireResponse": response, "paneRecord": settled["record"],
        }
    validate_label(label)
    sequence = spend_sequence(state, state_path)
    response = probe.request(
        token, "report", {"state": reported, "text": label, "seq": sequence, "ttl": 1800},
    )
    if probe.code(response) != "ok":
        raise FixtureError("report was not accepted: %r" % response)

    def accepted_attention(value):
        explanation = value.get("explanation") or {}
        if reported == "blocked":
            wanted = "asking"
        elif reported == "idle":
            wanted = None if explanation.get("seen") else "done"
        else:
            wanted = None
        return (value.get("record") or {}).get("attention") == wanted \
            and (wanted is None and reported == "working"
                 or (explanation.get("report") or {}).get("seq") == sequence)

    settled = monotonic_wait(
        lambda: read_attention(probe, token, pane),
        accepted_attention,
        what="attention %s" % reported,
    )
    return {
        "action": "attention", "at": time.time(), "pid": pid, "pane": pane,
        "state": reported, "label": label, "sequence": sequence,
        "wireResponse": response, "paneRecord": settled["record"],
        "effectiveAttention": (settled["record"] or {}).get("attention"),
        "explanation": settled["explanation"],
    }


# MARK: ledger and records


def new_ledger(state):
    return {
        "version": LEDGER_VERSION,
        "evidence": state["evidence"],
        "fixtureRuns": [],
        "cases": {},
        "events": [],
    }


def read_ledger(state):
    path = pathlib.Path(state["ledger"])
    ledger = read_json(path) if path.exists() else new_ledger(state)
    if ledger.get("version") != LEDGER_VERSION:
        raise FixtureError("ledger version is not %d" % LEDGER_VERSION)
    runs = ledger.setdefault("fixtureRuns", [])
    if not any(run.get("runId") == state["runId"] for run in runs):
        runs.append({
            "runId": state["runId"], "registeredAt": time.time(),
            "gitRevision": state.get("gitRevision"), "gitDirty": state.get("gitDirty"),
            "binarySha256": state.get("binarySha256"),
            "sourceBinarySha256": state.get("sourceBinarySha256"),
            "bundleId": state.get("bundleId"),
        })
    return ledger


def write_ledger(state, ledger):
    atomic_json(state["ledger"], ledger)


def contains_secret_key(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if str(key).lower() in SECRET_KEYS or contains_secret_key(item):
                return True
    elif isinstance(value, list):
        return any(contains_secret_key(item) for item in value)
    return False


def require_case_id(case):
    import re
    if not isinstance(case, str) or not re.match(r"^[A-Z]\d{2}(-[a-z0-9]+)*$", case):
        raise FixtureError("case id must look like A01 or S04-cell-name")
    return case


def validate_evidence_entry(entry, evidence_root, result):
    if not isinstance(entry, dict):
        raise FixtureError("evidence entries must be objects")
    path = entry.get("path")
    if not isinstance(path, str):
        raise FixtureError("evidence entry has no path")
    resolved = require_within(path, evidence_root, "evidence path")
    if not os.path.isfile(resolved):
        raise FixtureError("evidence path is not a regular file: %s" % path)
    if os.path.getsize(resolved) == 0:
        raise FixtureError("evidence file is empty: %s" % path)
    if os.path.basename(resolved) == LEDGER_NAME:
        raise FixtureError("the ledger is not evidence")
    kind = entry.get("kind")
    if kind not in EVIDENCE_KINDS:
        raise FixtureError("evidence kind must be one of %s" % ", ".join(EVIDENCE_KINDS))
    judgment = entry.get("judgment")
    if kind in VISUAL_KINDS and (not isinstance(judgment, str) or not judgment.strip()):
        raise FixtureError("a %s needs an explicit semantic judgment, a filename is not proof" % kind)
    return {
        "path": resolved, "kind": kind, "sha256": sha256_of(resolved),
        "bytes": os.path.getsize(resolved), "judgment": judgment,
    }


def validate_result(document, case, state, result_path):
    """Grade one reviewed observation against the fixture identity and the
    evidence contract. Returns the sanitized record or raises."""
    if not isinstance(document, dict):
        raise FixtureError("result file must hold a JSON object")
    if contains_secret_key(document):
        raise FixtureError("result contains a capability-like key; tokens never enter the ledger")
    if document.get("version") != RESULT_VERSION:
        raise FixtureError("result version must be %d" % RESULT_VERSION)
    if document.get("case") != case:
        raise FixtureError("result case %r does not match --case %s" % (document.get("case"), case))
    result = document.get("result")
    if result not in RESULTS:
        raise FixtureError("result must be PASS, FAIL, or BLOCKED")
    if document.get("fixtureRunId") != state["runId"]:
        raise FixtureError("result names another fixture run id")
    if document.get("pid") != state.get("pid") or not state.get("pid"):
        raise FixtureError("result pid %r is not the live fixture pid %r" % (document.get("pid"), state.get("pid")))
    if document.get("binarySha256") != state.get("binarySha256"):
        raise FixtureError("result binary SHA-256 is not the tested copied binary")
    if document.get("gitRevision") != state.get("gitRevision"):
        raise FixtureError("result git revision is not the tested revision")
    scenario = state.get("scenario") or {}
    if document.get("scenario") != scenario.get("scenario"):
        raise FixtureError("result scenario %r is not the prepared scenario %r" % (
            document.get("scenario"), scenario.get("scenario")))
    for key in ("setup", "expected", "observed"):
        if not isinstance(document.get(key), str) or not document[key].strip():
            raise FixtureError("result needs a non-empty %s" % key)
    actions = document.get("actions")
    if not isinstance(actions, list) or not actions:
        raise FixtureError("result needs a timestamped action list")
    for action in actions:
        if not isinstance(action, dict) or not isinstance(action.get("at"), (int, float)) \
                or not isinstance(action.get("action"), str) or not action["action"].strip():
            raise FixtureError("every action needs a numeric `at` and a description")
    verified_by = document.get("verifiedBy")
    if not isinstance(verified_by, list) or not all(isinstance(item, str) for item in verified_by):
        raise FixtureError("verifiedBy must be a list of strings")
    unknown = [item for item in verified_by if item not in OBSERVATIONS + NON_OBSERVATIONS]
    if unknown:
        raise FixtureError("unknown verifiedBy values: %s" % ", ".join(unknown))
    observations = [item for item in verified_by if item in OBSERVATIONS]
    evidence_entries = document.get("evidence")
    if not isinstance(evidence_entries, list):
        raise FixtureError("evidence must be a list")
    evidence = [validate_evidence_entry(entry, state["evidence"], result) for entry in evidence_entries]
    restoration = document.get("restoration")
    if not isinstance(restoration, dict) or not isinstance(restoration.get("required"), bool):
        raise FixtureError("restoration must state whether restoration was required")
    cleanup = document.get("cleanup")
    if not isinstance(cleanup, str) or not cleanup.strip():
        raise FixtureError("result needs a cleanup statement")
    fingerprints = fingerprint_comparison(state)
    if result == "PASS":
        if not evidence:
            raise FixtureError("a PASS needs at least one evidence file")
        if not observations:
            raise FixtureError(
                "a PASS must be verified by an observation of the product, not only by "
                "input delivery or a returned API call")
        if restoration["required"] and restoration.get("verified") is not True:
            raise FixtureError("a PASS with required restoration must record verified restoration")
        if restoration["required"] and not isinstance(restoration.get("readback"), str):
            raise FixtureError("verified restoration needs its UI readback described")
        if fingerprints["available"] and not fingerprints["unchanged"]:
            raise FixtureError("normal state changed during this run: %s" % ", ".join(fingerprints["changed"]))
        if not same_process(state):
            raise FixtureError("the fixture process is not the recorded copied binary at record time")
    if result == "BLOCKED":
        missing = document.get("missingCapability")
        if not isinstance(missing, str) or not missing.strip():
            raise FixtureError("a BLOCKED result must name the exact missing capability")
    record = {
        "case": case,
        "result": result,
        "recordedAt": time.time(),
        "fixtureRunId": state["runId"],
        "batch": scenario.get("batch"),
        "scenario": scenario.get("scenario"),
        "arm": scenario.get("arm"),
        "pid": state.get("pid"),
        "bundleId": state.get("bundleId"),
        "binarySha256": state.get("binarySha256"),
        "gitRevision": state.get("gitRevision"),
        "gitDirty": state.get("gitDirty"),
        "windows": document.get("windows"),
        "setup": document["setup"],
        "expected": document["expected"],
        "observed": document["observed"],
        "actions": actions,
        "verifiedBy": verified_by,
        "evidence": evidence,
        "restoration": restoration,
        "cleanup": cleanup,
        "missingCapability": document.get("missingCapability"),
        "normalState": fingerprints,
        "resultFile": result_path,
        "resultFileSha256": sha256_of(result_path),
        "evidenceClass": document.get("evidenceClass", "real-app"),
    }
    return record


def phase_record(state, case, result_file):
    require_case_id(case)
    result_path = require_within(result_file, state["evidence"], "result file")
    if os.path.basename(result_path) == LEDGER_NAME:
        raise FixtureError("the ledger cannot be imported as a result")
    try:
        document = read_json(result_path)
    except (OSError, ValueError) as error:
        raise FixtureError("result file is not readable JSON: %s" % error)
    record = validate_result(document, case, state, result_path)
    ledger = read_ledger(state)
    entry = ledger["cases"].setdefault(case, {"latest": None, "history": []})
    entry["history"].append(record)
    entry["latest"] = record
    write_ledger(state, ledger)
    return {"action": "record", "at": record["recordedAt"], "case": case, "result": record["result"],
            "evidenceCount": len(record["evidence"]), "ledger": state["ledger"]}


# MARK: report, repair, stop


def jobs_census(state):
    """Recorded foreground jobs: alive only when the live start time still
    matches the recorded one, so a reused pid is reported as gone."""
    jobs = pathlib.Path(state.get("jobsDir") or "")
    found = []
    if not jobs.is_dir():
        return found
    for path in sorted(jobs.glob("*.job")):
        try:
            record = parse_job_record(path.read_text(encoding="utf-8"))
            pid = int(record.get("pid", ""))
        except (OSError, ValueError):
            continue
        command = process_command(pid)
        started = process_start(pid)
        same_start = bool(started) and started == record.get("started")
        found.append({
            "file": path.name, "pid": pid, "shell": record.get("shell"),
            "pane": record.get("pane"), "recordedStart": record.get("started"),
            "alive": command is not None and same_start, "command": command,
        })
    return found


def phase_report(state):
    """Safe identity and ledger summary. Never reads or prints capabilities."""
    ledger = read_ledger(state)
    cases = {}
    for case, entry in sorted(ledger["cases"].items()):
        latest = entry.get("latest") or {}
        cases[case] = {
            "result": latest.get("result"),
            "recordedAt": latest.get("recordedAt"),
            "fixtureRunId": latest.get("fixtureRunId"),
            "evidenceCount": len(latest.get("evidence") or []),
            "historyCount": len(entry.get("history") or []),
        }
    pid = state.get("pid")
    scenario = state.get("scenario") or {}
    return {
        "action": "report",
        "at": time.time(),
        "runId": state["runId"],
        "repoRoot": state["repoRoot"],
        "gitRevision": state.get("gitRevision"),
        "gitDirty": state.get("gitDirty"),
        "bundleId": state.get("bundleId"),
        "app": state.get("app"),
        "binary": state.get("binary"),
        "binarySha256": state.get("binarySha256"),
        "sourceBinarySha256": state.get("sourceBinarySha256"),
        "pid": pid,
        "sameProcess": same_process(state) if pid else None,
        "windows": visible_windows(window_census(pid)) if pid and same_process(state) else [],
        "scratch": state["scratch"],
        "support": state["support"],
        "session": state["session"],
        "config": state["config"],
        "socket": state.get("socket"),
        "evidence": state["evidence"],
        "ledger": state["ledger"],
        "recorder": state.get("recorder"),
        "batches": state.get("batches", 0),
        "relaunches": state.get("relaunches", 0),
        "awaitingQuit": state.get("awaitingQuit"),
        "lastPid": state.get("lastPid"),
        "deadlineAt": state.get("deadlineAt"),
        "scenario": {
            key: scenario.get(key)
            for key in ("scenario", "arm", "batch", "panes", "projects", "files", "hashes",
                        "sessionBytesHex", "support", "logical", "notes", "readiness",
                        "relaunchReadiness")
        } if scenario else None,
        "jobs": jobs_census(state),
        "normalState": fingerprint_comparison(state),
        "fixtureRuns": [run.get("runId") for run in ledger.get("fixtureRuns", [])],
        "cases": cases,
    }


def phase_repair(state):
    repaired = repair_permissions(state)
    return {"action": "repair", "at": time.time(), "repaired": repaired}


def phase_stop(state, reason):
    marker = require_within(state["stopMarker"], state["scratch"], "stop marker")
    require_basename(marker, STOP_MARKER_NAME, "stop marker")
    pathlib.Path(marker).touch(mode=0o600, exist_ok=True)
    return {
        "action": "stop", "at": time.time(), "pid": state.get("pid"),
        "sameProcessAtStop": same_process(state) if state.get("pid") else None,
        "reason": reason, "marker": marker,
    }


def append_event(state, observation):
    ledger = read_ledger(state)
    event = {key: value for key, value in observation.items()
             if key not in ("wireResponse", "explanation", "paneRecord", "readiness")}
    event["runId"] = state["runId"]
    ledger["events"].append(event)
    write_ledger(state, ledger)


# MARK: CLI


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, help="fixture.json printed by run.sh")
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare", help="seed a scratch scenario and relaunch")
    prepare.add_argument("scenario", choices=SCENARIOS)
    prepare.add_argument("--arm", default=None)
    attention = subparsers.add_parser("attention", help="send a pane report through the wire")
    attention.add_argument("--pane", default=None)
    attention.add_argument("--state-value", dest="reported", choices=("blocked", "working", "idle"),
                           default="blocked")
    attention.add_argument("--label", default=None)
    attention.add_argument("--release", action="store_true")
    await_quit = subparsers.add_parser("await-quit", help="announce an expected quit and wait for it")
    await_quit.add_argument("--seconds", type=float, default=60.0)
    subparsers.add_parser("relaunch", help="launch the same copy again without reseeding")
    record = subparsers.add_parser("record", help="import a reviewed observation")
    record.add_argument("--case", required=True)
    record.add_argument("--result-file", required=True)
    subparsers.add_parser("report")
    subparsers.add_parser("repair", help="restore write permissions after a refused-write arm")
    stop = subparsers.add_parser("stop")
    stop.add_argument("--reason", default="coordinator stop")
    return parser.parse_args(argv)


def run_locked(arguments):
    state_path = pathlib.Path(arguments.state).resolve()
    state = require_state_ownership(read_json(state_path), state_path)
    lock_path = pathlib.Path(state["evidence"]) / ".phase.lock"
    lock_path.touch(mode=0o600, exist_ok=True)
    with open(lock_path, "r+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = require_state_ownership(read_json(state_path), state_path)
        if arguments.command == "report":
            observation = phase_report(state)
            print(json.dumps(observation, indent=2, sort_keys=True))
            return
        if arguments.command == "prepare":
            observation = phase_prepare(state, state_path, arguments.scenario, arguments.arm)
        elif arguments.command == "attention":
            if not arguments.release and not arguments.label:
                raise FixtureError("attention needs --label unless --release")
            observation = phase_attention(
                state, state_path, arguments.pane, arguments.reported, arguments.label,
                arguments.release)
        elif arguments.command == "await-quit":
            if arguments.seconds <= 0 or arguments.seconds > 600:
                raise FixtureError("await-quit seconds must be above 0 and at most 600")
            observation = phase_await_quit(state, state_path, arguments.seconds)
        elif arguments.command == "relaunch":
            observation = phase_relaunch(state, state_path)
        elif arguments.command == "record":
            observation = phase_record(state, arguments.case, arguments.result_file)
        elif arguments.command == "repair":
            observation = phase_repair(state)
        elif arguments.command == "stop":
            observation = phase_stop(state, arguments.reason)
        else:
            raise FixtureError("unsupported phase %s" % arguments.command)
        append_event(state, observation)
        atomic_json(state_path, state)
        print(json.dumps(observation, indent=2, sort_keys=True))


def main(argv=None):
    arguments = parse_arguments(argv)
    try:
        run_locked(arguments)
    except Exception as error:  # noqa: BLE001 - the CLI reports every refusal
        print("desktop-acceptance phase failed: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
