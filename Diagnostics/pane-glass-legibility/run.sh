#!/bin/bash
# The pane-wash opacity sweep. One binary, one curve.
#
#   ./run.sh [output-directory]
#
# Captures land in the output directory (default: a scratch directory under
# TMPDIR). Nothing is written into the repo. `measure.py` then reads them and
# prints the α → contrast table, which is also written to `results.txt` beside
# the captures.
#
# The binary never activates, never makes a window key, and never quits or
# launches baia. `NSApplication.setActivationPolicy(.accessory)` plus
# `orderFrontRegardless()` is the `SAFE_PROBES` standard (the criterion is
# focus, not invisibility — see guard-baia-alive.sh). Like glass-backdrop, it
# does put windows on screen for the capture session (roughly 35 seconds for
# the calibration strip, the fourteen-value sweep, and two wallpaper shots) and
# never takes the keyboard. Note: this probe is not yet on guard-baia-alive.sh's
# SAFE_PROBES list; it meets the list's criterion and adding it is the guard
# owner's call.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-${TMPDIR:-/tmp}/baia-pane-glass-legibility}
BUILD="$OUT/build"
LIB="$BUILD/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh`, not here — see that
# file for why every probe sources it rather than carrying its own copy.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

# Links `PaneChrome` so the theme values (`PaneTheme.darkPastel` background and
# foreground) are read off the package at run time rather than transcribed.
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION.
swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/washsweep" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/washsweep.swift"

echo "=== captures: the wash-opacity sweep over the controlled backdrop ==="
"$BUILD/washsweep" "$OUT"
echo

echo "=== measurement ==="
python3 "$HERE/measure.py" "$OUT" | tee "$OUT/results.txt"

echo
echo "captures and results: $OUT"
echo "The verdict is in this probe's README.md; these files are what it cites."
