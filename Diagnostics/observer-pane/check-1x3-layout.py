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
import sys


def kind(node):
    return "split" if "split" in node else "pane"


def cwd(node):
    return (node.get("pane") or {}).get("cwd")


def normalised(path):
    """Trailing slashes and a `/private` prefix are the app's spelling, not a defect."""
    text = (path or "").rstrip("/")
    if text.startswith("/private/"):
        text = text[len("/private"):]
    return text


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
                got = [cwd(r) for r in rows if kind(r) == "pane"]
                want = ["%s/%s" % (scratch, name) for name in ("one", "two", "three")]
                if [normalised(g) for g in got] != [normalised(w) for w in want]:
                    problems.append("the rows are in the wrong order")
                    problems.append("  got  %s" % [normalised(g) for g in got])
                    problems.append("  want %s" % [normalised(w) for w in want])

    if problems:
        for problem in problems:
            print("  FAIL  " + problem if not problem.startswith("  ") else "      " + problem)
        return 1

    print("  ok    the root is one pane beside a column of three")
    print("  ok    the three rows are the three directories, in spawn order")
    return 0


if __name__ == "__main__":
    sys.exit(main())
