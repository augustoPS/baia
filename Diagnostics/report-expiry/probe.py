#!/usr/bin/python3
"""Exercise report expiry through an isolated app's real control socket."""

import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import time


SOCKET, TOKENS, SESSION, CONFIG, SCRATCH, EVIDENCE, APP_PID, CONTROL_PROBE, BINARY = sys.argv[1:]
ALPHA = "BA1AC0DE-0000-4000-8000-000000000001"
BRAVO = "BA1AC0DE-0000-4000-8000-000000000002"
scratch = pathlib.Path(SCRATCH)
evidence = pathlib.Path(EVIDENCE)
checks = 0
failures = []
observations = {}


def check(condition, message, observed=None):
    global checks
    checks += 1
    if condition:
        print("PASS " + message)
        return True
    print("FAIL " + message)
    if observed is not None:
        print("     observed: %r" % (observed,))
    failures.append(message)
    return False


def wait_until(read, accepts, limit=12):
    deadline = time.time() + limit
    last = None
    while time.time() < deadline:
        last = read()
        if accepts(last):
            return last
        time.sleep(0.1)
    return last


def record(probe, token, pane):
    return probe.record_of(probe.request(token, "list"), pane)


def explanation(probe, token):
    return (probe.request(token, "explain").get("result") or {}).get("explanation")


def event_kinds(probe, token, cursor, pane):
    response = probe.request(token, "subscribe", {"from": cursor})
    return [
        event.get("kind")
        for event in probe.events(response) or []
        if event.get("pane") == pane
    ]


def sequence(probe, token):
    return probe.sequence(probe.request(token, "list"))


def wait_for_attention(probe, token, pane, wanted, limit=12):
    return wait_until(
        lambda: record(probe, token, pane),
        lambda value: isinstance(value, dict) and value.get("attention") == wanted,
        limit,
    )


def wait_for_activity(probe, token, pane, wanted, limit=12):
    return wait_until(
        lambda: record(probe, token, pane),
        lambda value: isinstance(value, dict) and value.get("activity") == wanted,
        limit,
    )


def app_is_running():
    try:
        os.kill(int(APP_PID), 0)
        return True
    except (OSError, ValueError):
        return False


def set_activity_poll(seconds):
    path = pathlib.Path(CONFIG)
    document = json.loads(path.read_text())
    document["activityPollSeconds"] = seconds
    path.write_text(json.dumps(document, indent=2) + "\n")


# Loading the shared wire client must not leave an __pycache__ in the checkout.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("control_probe", CONTROL_PROBE)
control_probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control_probe)
probe = control_probe.Probe(SOCKET, TOKENS, "", SESSION, TOKENS, SCRATCH)

try:
    live = probe.tokens()
    check(app_is_running(), "disposable app survived launch")
    check(ALPHA in live and BRAVO in live, "both real panes reported their capabilities", sorted(live))
    if ALPHA not in live or BRAVO not in live:
        raise RuntimeError("pane capabilities unavailable")

    alpha_token = live[ALPHA]
    bravo_token = live[BRAVO]

    # Q04: establish that Bravo was idle, remove its view by zooming Alpha, then
    # start and finish a real foreground child in the hidden pane.
    idle = wait_for_activity(probe, bravo_token, BRAVO, None)
    check((idle or {}).get("activity") is None, "Bravo begins idle before it is hidden", idle)
    zoomed = probe.request(alpha_token, "zoom", {"on": True})
    check(
        probe.code(zoomed) == "ok" and (zoomed.get("result") or {}).get("zoomed") is True,
        "Alpha zooms and detaches Bravo's view",
        zoomed,
    )
    (scratch / "run-hidden").touch()
    running = wait_for_activity(probe, bravo_token, BRAVO, "sleep", 14)
    check((running or {}).get("activity") == "sleep", "hidden Bravo publishes its running child", running)
    stopped = wait_for_activity(probe, bravo_token, BRAVO, None, 14)
    check((stopped or {}).get("activity") is None, "hidden Bravo publishes the child's exit", stopped)

    # Hold one foreground process unchanged throughout every report arm. Once
    # its arrival is published, move activity polling out to thirty seconds and
    # wait for the watched config to apply. Every report TTL below is shorter.
    (scratch / "run-stable").touch()
    stable = wait_for_activity(probe, bravo_token, BRAVO, "sleep", 14)
    check((stable or {}).get("activity") == "sleep", "hidden Bravo publishes the stable foreground job", stable)
    set_activity_poll(30)
    time.sleep(2)
    observations["activityPollSecondsDuringExpiry"] = 30

    # No focus, process or view transition accompanies this deadline. All three
    # readers must move anyway, even if a foreground process read is unavailable.
    expiry_from = sequence(probe, bravo_token)
    accepted = probe.request(
        bravo_token,
        "report",
        {"state": "blocked", "text": "expiry fixture", "seq": 1, "ttl": 1},
    )
    check(probe.code(accepted) == "ok", "a one-second blocked report is accepted", accepted)
    asking = wait_for_attention(probe, bravo_token, BRAVO, "asking")
    immediate_explain = explanation(probe, bravo_token)
    check((asking or {}).get("attention") == "asking", "list publishes the report immediately", asking)
    check(
        (immediate_explain or {}).get("attention") == "asking"
        and ((immediate_explain or {}).get("report") or {}).get("live") is True,
        "explain agrees that the report is live and asking",
        immediate_explain,
    )
    expired = wait_for_attention(probe, bravo_token, BRAVO, None)
    expired_explain = explanation(probe, bravo_token)
    expiry_events = event_kinds(probe, bravo_token, expiry_from, BRAVO)
    check((expired or {}).get("attention") is None, "list clears at TTL without another pane event", expired)
    check(
        (expired_explain or {}).get("attention") is None
        and (expired_explain or {}).get("attentionDecidedBy") == "none"
        and ((expired_explain or {}).get("report") or {}).get("live") is False,
        "explain returns authority to the pollers on the same revision",
        expired_explain,
    )
    check(
        expiry_events == ["attentionRaised", "attentionCleared"],
        "the subscription contains exactly one raise and one expiry clear",
        expiry_events,
    )
    observations["primaryExpiry"] = {
        "immediate": immediate_explain,
        "expired": expired_explain,
        "events": expiry_events,
    }

    # Renewal must replace the physical deadline. Wait past the first report's
    # TTL and require the renewed report to remain the single authority.
    renewal_from = sequence(probe, bravo_token)
    probe.request(bravo_token, "report", {"state": "blocked", "seq": 2, "ttl": 2})
    wait_for_attention(probe, bravo_token, BRAVO, "asking")
    time.sleep(1)
    probe.request(bravo_token, "report", {"state": "blocked", "seq": 3, "ttl": 4})
    time.sleep(1.5)
    renewed_record = record(probe, bravo_token, BRAVO)
    renewed_explain = explanation(probe, bravo_token)
    renewal_mid_events = event_kinds(probe, bravo_token, renewal_from, BRAVO)
    check((renewed_record or {}).get("attention") == "asking", "renewal survives the replaced deadline", renewed_record)
    check(
        ((renewed_explain or {}).get("report") or {}).get("seq") == 3
        and ((renewed_explain or {}).get("report") or {}).get("live") is True,
        "explain names the renewal as the live authority",
        renewed_explain,
    )
    check(renewal_mid_events == ["attentionRaised"], "the replaced deadline emitted no stale clear", renewal_mid_events)
    wait_for_attention(probe, bravo_token, BRAVO, None, 8)
    renewal_events = event_kinds(probe, bravo_token, renewal_from, BRAVO)
    check(
        renewal_events == ["attentionRaised", "attentionCleared"],
        "the renewal's own deadline emits one clear",
        renewal_events,
    )

    # A lower sequence cannot install its shorter TTL or change the report.
    stale_from = sequence(probe, bravo_token)
    probe.request(bravo_token, "report", {"state": "blocked", "seq": 5, "ttl": 4})
    wait_for_attention(probe, bravo_token, BRAVO, "asking")
    time.sleep(0.4)
    stale = probe.request(bravo_token, "report", {"state": "working", "seq": 4, "ttl": 1})
    time.sleep(1.2)
    stale_record = record(probe, bravo_token, BRAVO)
    stale_explain = explanation(probe, bravo_token)
    check(probe.code(stale) == "ok", "a superseded sequence remains a successful no-op", stale)
    check((stale_record or {}).get("attention") == "asking", "its shorter TTL cannot clear the accepted report", stale_record)
    check(
        ((stale_explain or {}).get("report") or {}).get("seq") == 5
        and ((stale_explain or {}).get("report") or {}).get("live") is True,
        "the accepted report and deadline remain authoritative",
        stale_explain,
    )
    wait_for_attention(probe, bravo_token, BRAVO, None, 8)
    stale_events = event_kinds(probe, bravo_token, stale_from, BRAVO)
    check(
        stale_events == ["attentionRaised", "attentionCleared"],
        "supersession still produces one clear at the accepted deadline",
        stale_events,
    )

    # Release clears now and invalidates the later timer, so waiting beyond its
    # old TTL cannot produce a second transition.
    probe.request(bravo_token, "report", {"state": "blocked", "seq": 6, "ttl": 2})
    wait_for_attention(probe, bravo_token, BRAVO, "asking")
    released = probe.request(bravo_token, "report", {"release": True})
    released_record = wait_for_attention(probe, bravo_token, BRAVO, None)
    released_from = sequence(probe, bravo_token)
    time.sleep(2.5)
    release_events = event_kinds(probe, bravo_token, released_from, BRAVO)
    check(probe.code(released) == "ok", "release is accepted", released)
    check((released_record or {}).get("attention") is None, "release clears immediately", released_record)
    check(release_events == [], "the cancelled release deadline emits nothing later", release_events)

    # Teardown is last. A live deadline must not keep the pane/controller alive
    # or call back into dead state after the pane has closed.
    probe.request(bravo_token, "report", {"state": "blocked", "seq": 7, "ttl": 2})
    wait_for_attention(probe, bravo_token, BRAVO, "asking")
    closed = probe.request(bravo_token, "close")
    check(probe.code(closed) == "ok", "a pane with a pending deadline closes", closed)
    unavailable = wait_until(
        lambda: probe.code(probe.request(bravo_token, "whoami")),
        lambda code: code == "badToken",
    )
    check(unavailable == "badToken", "the closed pane's capability is revoked", unavailable)
    time.sleep(2.5)
    check(app_is_running(), "the obsolete teardown deadline does not crash the app")
    check(
        probe.code(probe.request(alpha_token, "whoami")) == "ok",
        "the remaining pane still answers after that deadline",
    )

except Exception as error:
    print("FAIL fixture could not complete: %s" % error)
    failures.append("fixture could not complete: %s" % error)

binary_hash = hashlib.sha256(pathlib.Path(BINARY).read_bytes()).hexdigest()
report = {
    "checks": checks,
    "failures": failures,
    "observations": observations,
    "bundle": BINARY,
    "binarySHA256": binary_hash,
}
(evidence / "report.json").write_text(json.dumps(report, indent=2) + "\n")

if failures:
    print("FAIL %d check(s) failed out of %d" % (len(failures), checks))
    sys.exit(1)
print("PASS all %d report-expiry checks" % checks)
