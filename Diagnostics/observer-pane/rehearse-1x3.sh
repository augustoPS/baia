#!/usr/bin/env bash
# Exercises spawn-1x3.sh end to end without spending three agent sessions.
#
#   ./Diagnostics/observer-pane/rehearse-1x3.sh
#
# Run from inside a baia pane, which becomes the left column.
#
# **The geometry is the thing under test, and no agent is needed to test it.**
# `spawn-1x3.sh` does three splits and two moves and asserts three direct
# children; none of that depends on what runs inside a pane. So this points it at
# three scratch directories with `SPAWN_1X3_REHEARSE` set, which swaps the agent
# for an echo, and then checks the arrangement it produced.
#
# **The assertion is `layout export`, not the eye.** The document names an axis, a
# ratio and a `cwd` per pane, so the exact 1|3 shape is checkable and so is which
# directory landed in which row. A screenshot proves neither: the first live run
# of `pane-move/live.sh` looked correct in a screenshot while the probe's own
# description of it was wrong.
#
# What it does not rehearse: an agent's startup, a brief being read, and the trust
# and settings seeding that `run.sh` does around this. Those have their own checks.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRATCH=${TMPDIR:-/tmp}/baia-rehearse-1x3

[ -n "${BAIA_SOCK:-}" ] || { echo "no BAIA_SOCK: run this from inside a baia pane" >&2; exit 2; }
[ -n "${BAIA_PANE:-}" ] || { echo "no BAIA_PANE: run this from inside a baia pane" >&2; exit 2; }

# `close` closes only the calling pane, so nothing here can tidy up after itself
# and a second run would spawn into a window still holding the first run's three.
# The child-count assertion would then read six and fail for a reason that has
# nothing to do with the code, so it is refused up front with the real remedy.
existing=$(baia list --json | python3 -c '
import json, os, sys
me = os.environ["BAIA_PANE"]
print(sum(1 for p in (json.load(sys.stdin).get("panes") or []) if p.get("createdBy") == me))
')
if [ "$existing" != "0" ]; then
  echo "this pane already has $existing child pane(s), probably a previous rehearsal." >&2
  echo "Close them by hand (Command-W in each) and run this again. The close verb" >&2
  echo "only ever closes the pane that calls it, so nothing here can do it for you." >&2
  exit 2
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"/one "$SCRATCH"/two "$SCRATCH"/three
for n in one two three; do
  # A brief that is never read, because the rehearsal swaps the agent out. It
  # exists because spawn-1x3.sh checks for it, and rehearsing the checks is part
  # of rehearsing the script.
  printf '# rehearsal %s\nNothing reads this.\n' "$n" > "$SCRATCH/$n/brief.md"
done
echo "  scratch at $SCRATCH"

SPAWN_1X3_REHEARSE=1 "$HERE/spawn-1x3.sh" "$SCRATCH/run" \
  "$SCRATCH/one"   "$SCRATCH/one/brief.md"   rehearsal \
  "$SCRATCH/two"   "$SCRATCH/two/brief.md"   rehearsal \
  "$SCRATCH/three" "$SCRATCH/three/brief.md" rehearsal || {
  echo "spawn-1x3.sh failed; leaving the panes for inspection" >&2
  exit 1
}

echo
echo "checking the arrangement"
baia layout export | python3 - "$SCRATCH" <<'PY'
import json, sys

scratch = sys.argv[1]
doc = json.load(sys.stdin)
tabs = doc.get("tabs") or []
if len(tabs) != 1:
    print("  FAIL  expected one tab, got %d" % len(tabs)); raise SystemExit(1)

def kind(node):
    return "split" if "split" in node else "pane"

def cwd(node):
    return (node.get("pane") or {}).get("cwd")

# The shape spawn-1x3.sh promises, read outside in:
#   h( A , v( one , v( two , three ) ) )
root = tabs[0]
problems = []

if kind(root) != "split" or root["split"]["axis"] != "horizontal":
    problems.append("root is not a horizontal split: %s" % kind(root))
else:
    left, right = root["split"]["first"], root["split"]["second"]
    if kind(left) != "pane":
        problems.append("the left column is not a single pane, it is a %s" % kind(left))
    if kind(right) != "split" or right["split"]["axis"] != "vertical":
        problems.append("the right column is not a vertical split")
    else:
        first = right["split"]["first"]
        rest = right["split"]["second"]
        if kind(rest) != "split" or rest["split"]["axis"] != "vertical":
            problems.append("the right column is not three panes deep")
        else:
            rows = [first, rest["split"]["first"], rest["split"]["second"]]
            for n, row in enumerate(rows):
                if kind(row) != "pane":
                    problems.append("row %d of the right column is a %s" % (n + 1, kind(row)))
            got = [cwd(r) for r in rows if kind(r) == "pane"]
            want = [scratch + "/" + n for n in ("one", "two", "three")]
            # Trailing slashes and /private are the app's spelling, not a defect.
            norm = lambda p: (p or "").rstrip("/").replace("/private/", "/", 1)
            if [norm(g) for g in got] != [norm(w) for w in want]:
                problems.append("the rows are in the wrong order:\n      got  %s\n      want %s"
                                % (got, want))

if problems:
    for p in problems:
        print("  FAIL  " + p)
    raise SystemExit(1)
print("  ok    the root is one pane beside a column of three")
print("  ok    the three rows are the three worktrees, in spawn order")
PY
verdict=$?

echo
if [ "$verdict" -eq 0 ]; then
  echo "  the layout is what spawn-1x3.sh promises."
else
  echo "  the layout is NOT what spawn-1x3.sh promises. Panes left for inspection."
fi
echo "  Close the three rehearsal panes by hand (⌘W in each) before running again."
exit "$verdict"
