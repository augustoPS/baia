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
# `${TMPDIR%/}` because $TMPDIR already ends in a slash on macOS, and `$TMPDIR/x`
# is then `/var/.../T//x`. The app answers with the collapsed spelling, so the
# doubled one failed a comparison against a layout that was correct.
SCRATCH=${TMPDIR:-/tmp}
SCRATCH=${SCRATCH%/}/baia-rehearse-1x3

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
# Piped into a file rather than into `python3 -` with a heredoc. The first
# version did the latter, which cannot work: `python3 -` reads its program from
# stdin and the heredoc is stdin, so the pipe never reached `json.load` and the
# check failed at char 0 against a layout that was correct.
#
# stderr is folded in, because a refused `layout export` writes there and prints
# nothing to stdout, and "printed nothing" is the one answer that needs its reason.
baia layout export 2>&1 | python3 "$HERE/check-1x3-layout.py" "$SCRATCH"
verdict=$?

echo
if [ "$verdict" -eq 0 ]; then
  echo "  the layout is what spawn-1x3.sh promises."
else
  echo "  the layout is NOT what spawn-1x3.sh promises. Panes left for inspection."
fi
echo "  Close the three rehearsal panes by hand (⌘W in each) before running again."
exit "$verdict"
