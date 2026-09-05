#!/usr/bin/python3
"""Drive isolated baia processes and grade session bytes across their lifetime."""

import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

import session_oracle

BINARY, SUPPORT, CONFIG, ZDOT, SCRATCH, EVIDENCE = sys.argv[1:]
support = pathlib.Path(SUPPORT)
session = support / "session.json"
scratch = pathlib.Path(SCRATCH)
evidence = pathlib.Path(EVIDENCE)
pid_file = scratch / "app.pid"


checks = 0
failures = []


def interrupted(_signum, _frame):
    # The shell trap sends TERM if it is interrupted while waiting. Ignore the
    # second signal so it cannot interrupt the exact-PID graceful quit below.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)

def check(condition, message):
    global checks
    checks += 1
    if condition:
        print("PASS " + message)
    else:
        print("FAIL " + message)
        failures.append(message)


def reset_support():
    support.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(support, 0o700)
    for child in support.iterdir():
        if child.name == ".baia-isolated-run":
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def record_process(process):
    # The shared isolation owner validates both fields before signalling this
    # exact child during interrupted or failed runs.
    pid_file.write_text("%d\n%s\n" % (process.pid, BINARY))


def wait_for_autosave(original, expect_change):
    deadline = time.time() + 8
    while time.time() < deadline:
        if session.exists():
            current = session.read_bytes()
            if expect_change and current != original:
                grade = session_oracle.grade_current_session(current, expected_panes=2)
                if (grade.valid_json and grade.current_schema
                        and grade.current_shape and grade.expected_pane_count):
                    return current
        time.sleep(0.2)
    return session.read_bytes() if session.exists() else None


def run_case(name, original, should_preserve, restore_session=True, expect_migration=False):
    reset_support()
    if original is not None:
        session.write_bytes(original)

    pathlib.Path(CONFIG).write_text(
        json.dumps(
            {
                "controlChannelEnabled": True,
                "notificationsEnabled": False,
                "projectRoots": [str(scratch)],
                "restoreSession": restore_session,
            }
        )
    )

    env = os.environ.copy()
    env.update(
        BAIA_CONFIG_FILE=CONFIG,
        ZDOTDIR=ZDOT,
        PYTHONUNBUFFERED="1",
    )
    env["BAIA_SESSION_SELFCHECK_MODE"] = "keep-file" if should_preserve else "mutation"
    event_path = evidence / (name + "-events.log")
    env["BAIA_SESSION_SELFCHECK_OUTPUT"] = str(event_path)
    env.pop("BAIA_SETTINGS_SELFCHECK", None)
    with open(evidence / (name + "-app.log"), "wb") as log:
        process = subprocess.Popen(
            [BINARY],
            cwd=SCRATCH,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        record_process(process)
        print("INFO %s app pid %d" % (name, process.pid))
        try:
            time.sleep(0.5)
            check(process.poll() is None, name + ": app survived launch")
            deadline = time.time() + 15
            while time.time() < deadline:
                if event_path.exists() and "mutation split=true resize=true" in event_path.read_text():
                    break
                time.sleep(0.2)
            check(event_path.exists() and "mutation split=true resize=true" in event_path.read_text(),
                  name + ": real split and divider resize completed")
            autosaved = wait_for_autosave(original, expect_change=not should_preserve)
            if should_preserve:
                check(autosaved == original, name + ": source bytes survived launch and autosave")
            else:
                check(autosaved is not None, name + ": autosave created session bytes")
                grade = session_oracle.grade_current_session(autosaved, expected_panes=2)
                check(grade.valid_json, name + ": autosave wrote valid JSON")
                check(grade.current_schema, name + ": autosave wrote the current schema")
                check(grade.current_shape, name + ": autosave wrote the current grouped shape")
                check(grade.expected_pane_count, name + ": autosave contains the created pane")
        finally:
            # NSRunningApplication asks this exact process to terminate through
            # AppKit, which exercises applicationWillTerminate and its final save.
            # A name-based quit could reach the daily driver or another fixture.
            alive_before_quit = process.poll() is None
            check(alive_before_quit, name + ": app was alive before the graceful quit request")
            graceful_accepted = False
            if alive_before_quit:
                graceful = subprocess.run(
                    [
                        "/usr/bin/osascript",
                        "-l",
                        "JavaScript",
                        "-e",
                        "ObjC.import('AppKit');"
                        "const app=$.NSRunningApplication."
                        "runningApplicationWithProcessIdentifier(%d);"
                        "if (!app.js || !app.terminate) throw Error('no app');" % process.pid,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                graceful_accepted = graceful.returncode == 0
            check(graceful_accepted, name + ": exact-PID shutdown was requested")
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Failure cleanup still names the one process the case owns.
                timed_out = True
                process.kill()
                process.wait(timeout=5)
            else:
                timed_out = False
            check(not timed_out, name + ": exact-PID shutdown completed before the timeout")
            check(process.returncode == 0, name + ": graceful quit exited successfully")
            check(process.poll() is not None, name + ": exact app pid stopped")
            if pid_file.exists():
                pid_file.unlink()

    after_shutdown = session.read_bytes() if session.exists() else None
    if should_preserve:
        events = event_path.read_text().splitlines() if event_path.exists() else []
        check("keep-file" in events, name + ": real Keep File action completed")
        check("mutation split=true resize=true" in events,
              name + ": real split and divider resize completed")
        check(not any(line.startswith("failure ") for line in events),
              name + ": Keep File self-check reported no failure")
        check(after_shutdown == original, name + ": source bytes survived shutdown")
    else:
        grade = session_oracle.grade_current_session(after_shutdown)
        check(grade.valid_json, name + ": saved session survived shutdown")
        check(grade.current_schema, name + ": shutdown preserved the current schema")
        check(grade.current_shape, name + ": shutdown preserved the grouped shape")
        if expect_migration:
            backup = pathlib.Path(str(session) + ".v1-backup")
            check(backup.exists() and backup.read_bytes() == original,
                  name + ": migration backup matches the legacy v1 bytes")


def run_selfcheck(name, mode):
    reset_support()
    original = None if mode == "quit-save-failure" else ("{ rejected for %s\n" % name).encode()
    seed = session_oracle.current_session(scratch) if original is None else original
    session.write_bytes(seed)
    pathlib.Path(CONFIG).write_text(json.dumps({
        "controlChannelEnabled": False,
        "notificationsEnabled": False,
        "projectRoots": [str(scratch)],
        "restoreSession": True,
    }))
    events = evidence / (name + "-events.log")
    env = os.environ.copy()
    env.update(BAIA_CONFIG_FILE=CONFIG, ZDOTDIR=ZDOT,
               BAIA_SESSION_SELFCHECK_MODE=mode,
               BAIA_SESSION_SELFCHECK_OUTPUT=str(events))
    with open(evidence / (name + "-app.log"), "wb") as log:
        process = subprocess.Popen([BINARY], cwd=SCRATCH, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        record_process(process)
        try:
            try:
                process.wait(timeout=25)
                timed_out = False
            except subprocess.TimeoutExpired:
                timed_out = True
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if pid_file.exists():
                pid_file.unlink()
    check(not timed_out, name + ": self-check completed before timeout")
    check(process.returncode == 0, name + ": self-check exited successfully")
    text = events.read_text() if events.exists() else ""
    def has_buttons(prefix, expected):
        for line in text.splitlines():
            if line.startswith(prefix):
                return set(line[len(prefix):].split("|")) == set(expected)
        return False
    if mode == "recovery-success":
        backup = support / "session.json.rejected-backup"
        check(backup.exists() and backup.read_bytes() == original,
              name + ": backup matches rejected bytes")
        replacement = session_oracle.grade_current_session(session.read_bytes())
        check(replacement.valid_json and replacement.current_schema and replacement.current_shape,
              name + ": recovery replaced source with current grouped schema")
        lines = text.splitlines()
        check(not any(line.startswith("failure ") for line in lines),
              name + ": self-check reported no failure")
        check("launch-sheet Back Up and Replace|Keep File" in lines,
              name + ": launch sheet offered both choices")
        check("keep-file" in lines and "menu enabled=true" in lines,
              name + ": Keep File preserved later recovery access")
        check(any(line.startswith("recovery-success backup=true saved=true buttons=OK") for line in lines),
              name + ": real recovery action completed")
    elif mode == "recovery-refusal":
        check(session.read_bytes() == original, name + ": refused recovery preserved source")
        lines = text.splitlines()
        check(not any(line.startswith("failure ") for line in lines),
              name + ": self-check reported no failure")
        check(has_buttons("recovery-refused ", ["Retry", "Keep File"]),
              name + ": refusal presented both recovery choices")
    else:
        lines = text.splitlines()
        check(not any(line.startswith("failure ") for line in lines),
              name + ": self-check reported no failure")
        check(has_buttons("quit-alert ", ["Retry", "Cancel Quit"]),
              name + ": failed quit offered Retry and Cancel Quit")
        cancelled = next((line for line in lines if line.startswith("quit-cancelled windows=")), "")
        check(cancelled not in ("", "quit-cancelled windows=0"),
              name + ": Cancel Quit kept a workspace open")
        check(has_buttons("quit-retry-alert ", ["Retry", "Cancel Quit"]) and "quit-retry" in lines,
              name + ": Retry was clicked on the second quit alert")
        try:
            saved = session_oracle.grade_current_session(session.read_bytes())
        except FileNotFoundError:
            saved = session_oracle.grade_current_session(None)
        check(saved.valid_json and saved.current_schema and saved.current_shape,
              name + ": retry saved a current grouped session before quit")
        check(session.read_bytes() != seed,
              name + ": Retry replaced the seeded valid snapshot")


support.mkdir(parents=True, mode=0o700, exist_ok=True)
try:
    run_case("malformed", b'{ broken session, preserve me\n', should_preserve=True)
    run_case("future-schema", session_oracle.future_session(scratch), should_preserve=True)
    run_case(
        "malformed-restore-off",
        b'{ broken while restore is disabled\n',
        should_preserve=True,
        restore_session=False,
    )
    run_case("current-valid", session_oracle.current_session(scratch), should_preserve=False)
    run_case(
        "legacy-v1",
        session_oracle.legacy_v1_session(scratch),
        should_preserve=False,
        expect_migration=True,
    )
    run_case("absent", None, should_preserve=False)
    run_selfcheck("recovery-success", "recovery-success")
    run_selfcheck("recovery-refusal", "recovery-refusal")
    run_selfcheck("quit-save-failure", "quit-save-failure")
except KeyboardInterrupt:
    print("INFO interrupted after exact-PID app cleanup")
    sys.exit(130)

report = {
    "checks": checks,
    "failures": failures,
    "bundle": BINARY,
    "binarySHA256": hashlib.sha256(pathlib.Path(BINARY).read_bytes()).hexdigest(),
    "support": SUPPORT,
}
(evidence / "report.json").write_text(json.dumps(report, indent=2) + "\n")

if failures:
    print("FAIL %d of %d checks failed" % (len(failures), checks))
    sys.exit(1)
print("PASS all %d session recovery checks" % checks)
