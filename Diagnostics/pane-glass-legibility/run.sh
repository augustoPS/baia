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
# does put windows on screen for the capture session (measured 24 seconds with
# no settle retries, 25-40 in practice, for the calibration strip, the
# fourteen-value sweep, the shipped-default arm and its control, and two
# wallpaper shots) and
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

# The SHIPPED-DEFAULT arm's assertions, enforced here rather than left for a
# reader. `measure.py` prints machine-readable verdict lines; this reads them.
#
# Two things have to hold:
#
#   1. the arm passes — the wash at `ChromeMaterials.PaneWash.floor` clears
#      4.5:1 on the bright half of this run;
#   2. the negative control has teeth — removing the wash layer must break
#      something. The absolute form (control fails 4.5:1) is the strong one and
#      is what holds on a bright tone-response day. On a dark one bare glass can
#      clear 4.5:1 by itself (the sweep's own α = 0.00 row did, on the run of
#      record), which makes the absolute control vacuous rather than violated;
#      the honest fallback is then the relative form, and it must pass. A run
#      where the absolute control is vacuous AND the relative control fails is a
#      run with no working control, and it fails loudly here.
echo
echo "=== shipped-default arm: assertions ==="
# The **last** line with the prefix, not the first: the relative control prints
# its working (the model, the constants, the measured band) under the same
# prefix before it prints its verdict, and a `-m1` here read the header line and
# reported a passing control as toothless.
verdict() { grep "^$1:" "$OUT/results.txt" | tail -1; }

arm=$(verdict SHIPPED-ARM)
absolute=$(verdict SHIPPED-CONTROL-ABSOLUTE)
relative=$(verdict SHIPPED-CONTROL-RELATIVE)
[ -n "$arm" ] && echo "  $arm"
[ -n "$absolute" ] && echo "  $absolute"
[ -n "$relative" ] && echo "  $relative"

bad=0
case "$arm" in
  *PASS*) ;;
  *) echo "  FAILED: the shipped default did not clear 4.5:1 on this run"; bad=1 ;;
esac

case "$absolute" in
  *FAIL-AS-REQUIRED*)
    echo "  control: absolute form held (wash removed fails AA) — the strong form"
    ;;
  *VACUOUS*)
    case "$relative" in
      *PASS*)
        echo "  control: absolute form vacuous on this tone response; relative form held"
        ;;
      *)
        echo "  FAILED: the negative control has no teeth on this run — removing the wash"
        echo "          neither dropped the contrast below 4.5:1 nor darkened the band by"
        echo "          the linear model's prediction. Nothing here is testing the feature."
        bad=1
        ;;
    esac
    ;;
  *)
    echo "  FAILED: no absolute-control verdict in results.txt (arm did not run?)"
    bad=1
    ;;
esac

echo
echo "captures and results: $OUT"
echo "The verdict is in this probe's README.md; these files are what it cites."

if [ "$bad" -ne 0 ]; then
  echo
  echo "FAILED: shipped-default arm assertions did not hold. See above."
  exit 1
fi
