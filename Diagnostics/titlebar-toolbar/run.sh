#!/usr/bin/env bash
# Renders thirteen titlebar arrangements and measures what each band carries:
# nothing, the system material slab, or glass.
#
#   ./Diagnostics/titlebar-toolbar/run.sh [output-directory]
#
# **Activates and takes the keyboard, so it must run from OUTSIDE a baia pane.**
# It launches nothing of baia's and quits nothing, which is true and is not the
# hazard: the probe calls `setActivationPolicy(.regular)` and
# `makeKeyAndOrderFront`, so it steals focus from whatever is frontmost, and an
# agent driving it from inside a pane loses the keyboard mid-run. That is what
# `SAFE_PROBES` in `guard-baia-alive.sh` guards, and the guard correctly blocks
# this probe from a pane. The earlier version of this comment reasoned from
# "launches nothing of baia's" to "safe from inside a pane", which does not
# follow.
#
# The probe shows one arm at a time at a fixed position and captures each alone,
# so no arm's chrome is ever inside another's measured band. This script reads
# those captures: the titlebar band, the well below it, and the same desktop
# with no window over it.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT="${1:-$REPO/.build/titlebar-toolbar}"
PIXEL="$REPO/Diagnostics/lib/pixel.py"
rm -rf "$OUT"
mkdir -p "$OUT"

BIN="$REPO/.build/titlebartoolbar"
swiftc -O "$REPO/Diagnostics/titlebar-toolbar/titlebartoolbar.swift" -o "$BIN" || exit 1

# The arms all stand at the same place, so one capture of that rectangle with no
# window over it is the baseline every band is read against. Taken first, while
# the screen is still bare.
screencapture -x -o -R"200,280,620,350" "$OUT/baseline.png"

PROBE_OUT="$OUT" "$BIN" > "$OUT/arms.log" 2>&1
echo

# The verdict metric, and the one the original probe already reasoned in:
# luminance spread down the band. Material reads ONE value all the way down, so
# a materialed band spreads ~0; a bare band tracks whatever is behind the window
# and spreads with the wallpaper. A mean alone cannot tell those apart — a dark
# wallpaper and a dark material average to the same grey — which is why the
# verdict is the spread and the mean is only reported alongside.
python3 "$REPO/Diagnostics/titlebar-toolbar/spread.py" "$OUT" || exit 1

echo
cat "$OUT/arms.log"
echo
echo "Captures in $OUT."
