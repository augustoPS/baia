#!/usr/bin/env python3
"""Checks an exported layout is the 1|3 arrangement spawn-1x3.sh promises.

    baia layout export | check-1x3-layout.py <scratch-root>

Exits 0 when the document is `h(observer, v(one, v(two, three)))` with the three
rows carrying the three scratch directories in spawn order, and 1 otherwise with
the reasons on stdout.

A file of its own rather than a heredoc in `rehearse-1x3.sh`, and that is not a
style preference. The first version was `baia layout export | python3 - <<'PY'`,
which cannot work: `python3 -` reads its program from stdin and the heredoc is
stdin, so the pipe was consumed by the interpreter and `json.load(sys.stdin)` got
an empty stream. It failed with a `JSONDecodeError` at char 0 against a layout
that was in fact correct, which is the worst way for a check to be wrong.

`path-picker` recorded the same lesson from the other direction: a heredoc holding
python inside a script is one nesting level too many. `read-prompt.py`,
`check-bindings.py` and `bind-panes.py` are all files for that reason.
"""

import json
import re
import sys


def kind(node):
    return "split" if "split" in node else "pane"


def cwd(node):
    return (node.get("pane") or {}).get("cwd")


def normalised(path):
    """One spelling of a path, so a comparison is about the path and not the typing.

    Three differences are the app's spelling or the shell's rather than a defect,
    and all three were met on the way here:

    - a `/private` prefix, which macOS resolves `/var` and `/tmp` through
    - a trailing slash, which `URL(directoryHint: .isDirectory)` appends
    - a doubled inner slash, because `$TMPDIR` already ends in one, so
      `${TMPDIR}/x` is `/var/.../T//x` while the app answers `/var/.../T/x`

    The third failed a run on 2026-08-02 against a layout that was correct in both
    shape and order, which is the second time in one evening this check has been
    the broken half.
    """
    text = re.sub(r"/{2,}", "/", path or "")
    if text.startswith("/private/"):
        text = text[len("/private"):]
    return text.rstrip("/")


def main() -> int:
    if len(sys.argv) != 2:
        print("  FAIL  usage: check-1x3-layout.py <scratch-root>")
        return 1
    scratch = sys.argv[1]

    raw = sys.stdin.read()
    if not raw.strip():
        print("  FAIL  `baia layout export` printed nothing.")
        print("        Run it on its own to see why; a refusal goes to stderr and")
        print("        would not reach this check through a pipe.")
        return 1
    try:
        doc = json.loads(raw)
    except ValueError as error:
        print("  FAIL  `baia layout export` did not print JSON: %s" % error)
        print("        first 200 characters: %r" % raw[:200])
        return 1

    tabs = doc.get("tabs") or []
    if len(tabs) != 1:
        print("  FAIL  expected one tab, got %d" % len(tabs))
        return 1

    root = tabs[0]
    problems = []

    if kind(root) != "split" or root["split"]["axis"] != "horizontal":
        problems.append("the root is not a horizontal split, it is a %s" % kind(root))
    else:
        left = root["split"]["first"]
        right = root["split"]["second"]
        if kind(left) != "pane":
            problems.append("the left column is not a single pane, it is a %s" % kind(left))
        if kind(right) != "split" or right["split"]["axis"] != "vertical":
            problems.append("the right column is not a vertical split")
        else:
            rest = right["split"]["second"]
            if kind(rest) != "split" or rest["split"]["axis"] != "vertical":
                problems.append("the right column is not three panes deep")
            else:
                rows = [right["split"]["first"], rest["split"]["first"], rest["split"]["second"]]
                for index, row in enumerate(rows):
                    if kind(row) != "pane":
                        problems.append("row %d of the right column is a %s"
                                        % (index + 1, kind(row)))
                got = [normalised(cwd(r)) for r in rows if kind(r) == "pane"]
                want = [normalised("%s/%s" % (scratch, name))
                        for name in ("one", "two", "three")]
                # Order and membership are separate answers, because they send a
                # reader to different places. A run on 2026-08-02 reported "wrong
                # order" for three rows that were in the right order and spelled
                # with one extra slash, and the message cost the trip it was
                # supposed to save.
                if got != want:
                    if sorted(got) == sorted(want):
                        problems.append("the three directories are all there, in the wrong order")
                    else:
                        problems.append("the rows are not the three directories")
                    problems.append("  got  %s" % got)
                    problems.append("  want %s" % want)

    if problems:
        for problem in problems:
            print("  FAIL  " + problem if not problem.startswith("  ") else "      " + problem)
        return 1

    print("  ok    the root is one pane beside a column of three")
    print("  ok    the three rows are the three directories, in spawn order")
    return 0


if __name__ == "__main__":
    sys.exit(main())
