#!/usr/bin/env python3
"""Binds each executor pane to its item by reading its screen, and writes the prompt.

    bind-panes.py <orchestrator-template.md> <output.md>

Run from the pane that spawned the executors. Exits 0 having written the output,
or 2 with the reason on stderr and nothing written.

**Why not the working directory.** The obvious key is the `--cwd` each pane was
split with, and it is not in `list`: `PaneRecord.workingDirectory` comes from the
per-pane anchor tracker, which polls only the pane that has focus. Measured
2026-08-01 during a live wave, where the observer's own pane carried a working
directory, an anchor and a branch, and all three executors carried none of them.

**Why not the order.** The children come back in an order that looks like the
order they were spawned in, and binding on that would be a guess dressed as a
fact. A wrong binding is the one failure that makes every verdict meaningless
while the run looks healthy, which is the whole reason this step was by hand.

**So the screen.** Every executor works in a worktree named `baia--<item>` on a
branch named `observer/<item>`, and both spellings appear in its own output. That
is evidence about the pane rather than an inference about the list, and it is the
same `read` verb the observer itself judges with.

Refuses on anything less than an exact one-to-one match: a pane matching two
items, a pane matching none, an item claimed twice, or an item nobody claims. A
partial answer here is worse than no answer, because the run would start.
"""

import json
import os
import re
import socket
import sys

CONNECT_TIMEOUT = 5
READ_LINES = 300

# The placeholder each item fills in the template.
ITEMS = {
    "activity-rules": "$PANE_ACTIVITY",
    "control-scope": "$PANE_CONTROL",
    "layout-translation": "$PANE_LAYOUT",
}

# What each item looks like on a screen, in two tiers with the first winning.
#
# Tier A is the worktree and the branch. Those name the pane rather than describe
# its work, so a hit is decisive.
#
# **Tier B is a hint that often fails, and it is kept honest rather than made
# clever.** Every brief in this wave runs `make build`, which compiles the whole
# app target, so any pane's screen can show any file or type in the project. A
# type name is therefore evidence of nothing. What survives that are private
# function names one brief asks for and no other touches, and even those refuse
# rather than guess when two items match. Measured on 2026-08-01: a first version
# of this list included the package name `PaneActivity` and matched two items on
# one screen, which is exactly the coin toss it was written to avoid.
#
# When tier B refuses, `--show` and `--manual` are the answer. A human reading
# three screens is slower than a regex and is the only thing here that cannot be
# confidently wrong.
MARKERS = {
    "activity-rules": (
        ("baia--activity-rules", "observer/activity-rules"),
        ("shellPid", "isWorkingAgent"),
    ),
    "control-scope": (
        ("baia--control-scope", "observer/control-scope"),
        ("isReadAllowed", "isRunAllowed"),
    ),
    "layout-translation": (
        ("baia--layout-translation", "observer/layout-translation"),
        ("ControlLayoutNode", "existingDirectory"),
    ),
}


def call(verb: str, args: dict) -> dict | None:
    """One control frame, spoken to the socket directly.

    Not through the `baia` CLI: this runs before the observer does and should not
    also be testing whether a PATH lookup and a shell rewrite behave.
    """
    token = os.environ.get("BAIA_TOKEN")
    sock_path = os.environ.get("BAIA_SOCK")
    if not token or not sock_path:
        return None
    frame = json.dumps({"v": 1, "token": token, "verb": verb, "args": args}) + "\n"
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(CONNECT_TIMEOUT)
        connection.connect(sock_path)
        connection.sendall(frame.encode())
        buffered = b""
        while b"\n" not in buffered:
            chunk = connection.recv(1 << 20)
            if not chunk:
                break
            buffered += chunk
        connection.close()
        answer = json.loads(buffered.split(b"\n")[0].decode())
    except (OSError, ValueError):
        return None
    return answer if answer.get("ok") else None


def main() -> int:
    argv = sys.argv[1:]
    show = "--show" in argv
    if show:
        argv.remove("--show")
    manual = []
    if "--manual" in argv:
        cut = argv.index("--manual")
        manual = argv[cut + 1:]
        argv = argv[:cut]
        if len(manual) != len(ITEMS):
            print("usage: --manual <%s>"
                  % "> <".join(ITEMS), file=sys.stderr)
            return 2
    if show:
        template_path = output_path = None
    elif len(argv) != 2:
        print("usage: bind-panes.py [--show] <template.md> <output.md> "
              "[--manual <activity> <control> <layout>]", file=sys.stderr)
        return 2
    else:
        template_path, output_path = argv

    me = os.environ.get("BAIA_PANE")
    if not me:
        print("refusing: no $BAIA_PANE. Run this from the pane that spawned the "
              "executors.", file=sys.stderr)
        return 2

    listing = call("list", {})
    if listing is None:
        print("refusing: the channel did not answer `list`. Run this from inside a "
              "baia pane.", file=sys.stderr)
        return 2
    result = listing.get("result") or {}
    records = result.get("panes") or []
    seq = result.get("seq")
    if seq is None:
        print("refusing: `list` returned no seq, so the observer has no starting "
              "point.", file=sys.stderr)
        return 2

    children = [r["pane"] for r in records if r.get("createdBy") == me]
    if len(children) != len(ITEMS):
        print("refusing: this pane created %d pane(s), expected %d. Spawn the wave "
              "first, and from this pane." % (len(children), len(ITEMS)),
              file=sys.stderr)
        return 2

    screens: dict[str, str] = {}
    for pane in children:
        answer = call("read", {"peer": pane, "lines": READ_LINES})
        screens[pane] = "\n".join(
            (answer.get("result") or {}).get("lines") or []) if answer else ""

    if show:
        # Twenty-five lines rather than six: enough to see what a pane is doing,
        # short enough to read three of them at once.
        for pane, screen in screens.items():
            print("\n=== %s ===" % pane)
            for line in [l for l in screen.splitlines() if l.strip()][-25:]:
                print("  " + line[:110])
        print("\nRe-run with --manual <activity> <control> <layout> once you can "
              "see which is which.")
        return 0

    if manual:
        if len(set(manual)) != len(manual):
            print("refusing: the same pane id was given twice.", file=sys.stderr)
            return 2
        stray = [p for p in manual if p not in screens]
        if stray:
            print("refusing: not a pane this one created: %s" % ", ".join(stray),
                  file=sys.stderr)
            return 2
        bound = {item: (pane, "by hand")
                 for item, pane in zip(ITEMS, manual)}
        return write(template_path, output_path, bound, seq)

    bound: dict[str, str] = {}
    unmatched: list[str] = []
    for pane, screen in screens.items():
        # Tier A decides on its own. Tier B is consulted only when tier A is silent
        # for every item, and only when exactly one item's tokens appear, so a
        # screen showing two items' symbols refuses rather than picking the longer
        # list.
        hits = sorted(item for item, (tier_a, _) in MARKERS.items()
                      if any(token in screen for token in tier_a))
        tier = "worktree"
        if not hits:
            hits = sorted(item for item, (_, tier_b) in MARKERS.items()
                          if any(token in screen for token in tier_b))
            tier = "symbols"

        if len(hits) == 1:
            if hits[0] in bound:
                print("refusing: %s is claimed by two panes, %s and %s."
                      % (hits[0], bound[hits[0]][0], pane), file=sys.stderr)
                return 2
            bound[hits[0]] = (pane, tier)
        elif not hits:
            unmatched.append(pane)
        else:
            print("refusing: pane %s shows %s for more than one item: %s"
                  % (pane, tier, ", ".join(hits)), file=sys.stderr)
            return 2

    if unmatched:
        print("refusing: %d pane(s) show nothing that names one item:"
              % len(unmatched), file=sys.stderr)
        for pane in unmatched:
            tail = [line for line in screens[pane].splitlines() if line.strip()][-6:]
            print("\n  %s, last non-empty lines on its screen:" % pane, file=sys.stderr)
            for line in tail:
                print("      " + line[:100], file=sys.stderr)
        print("\nRead which item each is working on from the lines above and "
              "substitute by hand. Do not type into an executor pane to find out: "
              "two of them sit at a permission prompt and a stray line answers it.",
              file=sys.stderr)
        return 2


    return write(template_path, output_path, bound, seq)


def write(template_path: str, output_path: str, bound: dict, seq: int) -> int:
    try:
        text = open(template_path, encoding="utf-8").read()
    except OSError as error:
        print("refusing: cannot read the template: %s" % error, file=sys.stderr)
        return 2

    for item, placeholder in ITEMS.items():
        text = text.replace(placeholder, bound[item][0])
    text = text.replace("$START_SEQ", str(seq))
    left = re.findall(r"\$(?:PANE_[A-Z]+|START_SEQ)", text)
    if left:
        print("refusing: the template still holds %s after substitution, so its "
              "placeholders and this script disagree."
              % ", ".join(sorted(set(left))), file=sys.stderr)
        return 2

    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(text)

    print("  one pane per item:")
    for item in ITEMS:
        pane, tier = bound[item]
        print("    %-20s %s  (%s)" % (item, pane, tier))
    print("    %-20s %s" % ("start seq", seq))
    print("  wrote %s" % output_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
