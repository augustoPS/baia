#!/bin/bash
# Builds and runs the pane-glass-blur spike, then measures its captures.
#
#   ./run.sh [output-directory]
#
# Captures and metrics land in the output directory (default: a scratch
# directory under TMPDIR). Nothing is written into the repo.
#
# The binary never activates, never makes a window key, and never touches the
# running baia app. `NSApplication.setActivationPolicy(.accessory)` plus
# `orderFrontRegardless()` is the `SAFE_PROBES` standard `glass-backdrop`
# meets, and this probe copies its arrangement exactly: windows appear over
# whatever is in front for roughly twenty seconds, take no focus, and are
# ordered out again.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-${TMPDIR:-/tmp}/baia-pane-glass-blur}
BUILD="$OUT/build"
LIB="$BUILD/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

# Links `PaneChrome` so the blur radius is `windowBlurRadius(...)` evaluated at
# run time against the shipped defaults, not a transcribed 20 that could go
# stale. -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION.
swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/blurtest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/blurtest.swift"

echo "=== captures: reference, four arms, and the wallpaper pair ==="
"$BUILD/blurtest" "$OUT"
echo

# --- measurement -------------------------------------------------------------
#
# Two bands, in window fractions, matching the constants in blurtest.swift:
#   bare   x 0.02-0.11  y 0.60-0.80   transparent window region left of the
#                                     glass plane: the compositor blur alone
#   glass  x 0.35-0.85  y 0.60-0.80   inside the plane, inside the text-free
#                                     gap, so no glyph contaminates the numbers
#
# hgrad is the detail-retention number (mean |horizontal neighbour luminance
# difference|); mean is the brightness-shift number. All within-run only: -R
# captures carry the display's brightness and EDR tone response at capture
# time.
echo "=== band metrics (within-run comparisons only) ===" | tee "$OUT/metrics.txt"
for capture in backdrop-reference \
               arm-a-blur-off-glass arm-b-blur-on-glass \
               arm-c-blur-on-noglass arm-d-blur-off-noglass \
               wallpaper-reference wallpaper-blur-off-glass wallpaper-blur-on-glass; do
  file="$OUT/$capture.png"
  if [ ! -f "$file" ]; then
    echo "MISSING $capture.png" | tee -a "$OUT/metrics.txt"
    continue
  fi
  bare=$(python3 "$HERE/analyze.py" "$file" 0.02 0.60 0.11 0.80)
  glass=$(python3 "$HERE/analyze.py" "$file" 0.35 0.60 0.85 0.80)
  printf "%-28s bare[%s]  glass[%s]\n" "$capture" "$bare" "$glass" | tee -a "$OUT/metrics.txt"
done

# The side question: does the SPI change what glass itself samples? The
# -window.png companions are the windows' own backing stores; glass composites
# its sampled backdrop into its own buffer, so if these two differ in the glass
# band, the compositor blur feeds glass sampling.
echo | tee -a "$OUT/metrics.txt"
echo "=== glass backing store (-l route): does the SPI feed glass sampling? ===" | tee -a "$OUT/metrics.txt"
for capture in arm-a-blur-off-glass arm-b-blur-on-glass; do
  file="$OUT/$capture-window.png"
  if [ ! -f "$file" ]; then
    echo "MISSING $capture-window.png" | tee -a "$OUT/metrics.txt"
    continue
  fi
  glass=$(python3 "$HERE/analyze.py" "$file" 0.35 0.60 0.85 0.80)
  printf "%-28s glass[%s]\n" "$capture" "$glass" | tee -a "$OUT/metrics.txt"
done

echo
echo "captures and metrics: $OUT"
echo "The verdict is in this probe's README.md; these files are what it cites."
