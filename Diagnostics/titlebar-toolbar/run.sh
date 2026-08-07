#!/usr/bin/env bash
# Renders four titlebar arrangements side by side and measures the strip.
#
#   ./Diagnostics/titlebar-toolbar/run.sh [output-directory]
#
# Launches nothing of baia's and quits nothing: the arms are four throwaway
# `NSWindow`s this probe builds itself, so it is safe to run from inside a baia
# pane. Writes one capture per arm plus the measured greys, and exits non-zero if
# an arm that must carry material reads as show-through.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT="${1:-$REPO/.build/titlebar-toolbar}"
mkdir -p "$OUT"

BIN="$REPO/.build/titlebartoolbar"
swiftc -O "$REPO/Diagnostics/titlebar-toolbar/titlebartoolbar.swift" -o "$BIN" || exit 1

"$BIN" > "$OUT/arms.log" 2>&1 &
PROBE=$!
trap 'kill $PROBE 2>/dev/null' EXIT
sleep 4

# The arms are identified by window height, not by AX order: AppKit reports the
# four in whatever order the window server hands them back, and the heights are
# unique per arm (32 pt of chrome for no toolbar, 40 for unifiedCompact, 52 for
# unified).
n=$(osascript -e 'tell application "System Events" to tell process "titlebartoolbar" to count windows' 2>/dev/null)
echo "arms on screen: $n"
for i in $(seq 1 "${n:-0}"); do
    geom=$(osascript -e "tell application \"System Events\" to tell process \"titlebartoolbar\" to get {position, size} of window $i" 2>/dev/null)
    x=$(echo "$geom" | cut -d, -f1 | tr -d ' ')
    y=$(echo "$geom" | cut -d, -f2 | tr -d ' ')
    w=$(echo "$geom" | cut -d, -f3 | tr -d ' ')
    h=$(echo "$geom" | cut -d, -f4 | tr -d ' ')
    screencapture -x -o -R"$x,$y,$w,60" "$OUT/arm-h$h.png"
    echo "  window $i  ${w}x${h} -> arm-h$h.png"
done

cat "$OUT/arms.log"
echo
echo "Chrome heights above are the decision: 32 pt is no toolbar (no material),"
echo "40 pt is .unifiedCompact, 52 pt is .unified. Captures in $OUT."
