#!/bin/bash
# Builds and runs the pane-glass-stacking spike, then measures the captures.
#
#   ./run.sh [output-directory]
#
# Captures land in the output directory (default: a scratch directory under
# TMPDIR). Nothing is written into the repo.
#
# The binary never activates, never makes a window key, and neither quits nor
# launches baia. `NSApplication.setActivationPolicy(.accessory)` plus
# `orderFrontRegardless()` is the `SAFE_PROBES` standard `glass-backdrop`
# already meets. Louder than glass-backdrop in one honest way: the controlled
# backdrop floats above normal windows (it must — see the README's method
# corrections), so the whole screen is a white/black field for ~20 seconds.
# No focus moves at any point.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-${TMPDIR:-/tmp}/baia-pane-glass-stacking}
BUILD="$OUT/build"
LIB="$BUILD/lib"
mkdir -p "$LIB"
cd "$ROOT"

# Dependency edges live in `lib/build-packages.sh`; see its header for why no
# probe carries its own module list.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

# Links `PaneChrome` only: the probe reads `PaneStatusBarMetrics` off the
# package at run time rather than transcribing it, the same rule glass-backdrop
# follows. -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION.
swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/stackingtest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/stackingtest.swift"

echo "=== captures: group portrait, then each arm solo ==="
"$BUILD/stackingtest" "$OUT"
echo

# --- measurement -------------------------------------------------------------
#
# The measured route is the solo `-R` file (`pane-<arm>-screen.png`, one arm on
# screen at a time): a pane-sized `NSGlassEffectView` composites at the
# window-server level, so its `-l` buffer is a flat unsampled slab however long
# the run settles — the same behaviour glass-backdrop's README documents for
# its 220 pt sidebar column. `-R` absolutes carry the display's tone response
# at capture time; every comparison below is within-run, cross-checked by the
# margin references, and no absolute transfers to another run or machine.
#
# Each `-R` file is the pane plus a 40 pt margin of raw controlled backdrop on
# every side. Bands, in pane points (pane 720x200, footer 22 pt at the bottom):
#
#   footer band   y 196.6-199.4  the bottom ~3 pt of the footer strip, below
#                                the glyph descenders (baseline is 15 pt into
#                                the 22 pt bar; no hairline is drawn)
#   surface band  y 150-175      glass-only rows above the footer (terminal
#                                text stops 70 pt short of the bottom)
#   white half    x 72-252       the seam is the pane's midline
#   black half    x 468-648
#   margin refs   the strips left of x=0 (raw white) and right of x=720 (raw
#                 black): equal across arms means the display held still
#                 between the solo grabs and the arm columns are comparable.
PIXEL="$ROOT/Diagnostics/lib/pixel.py"

echo "=== band means (solo -R route, within-run only) ==="
PIXEL_PY="$PIXEL" python3 - "$OUT" <<'EOF'
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location("pixel", os.environ["PIXEL_PY"])
px = importlib.util.module_from_spec(spec); spec.loader.exec_module(px)
out = sys.argv[1]
MARGIN, PANE_W, PANE_H = 40.0, 720.0, 200.0

def bands(path):
    w, h, bpp, rows = px.read_png(path)
    sx, sy = w / (PANE_W + 2 * MARGIN), h / (PANE_H + 2 * MARGIN)
    def mean(x0, y0, x1, y1):  # pane points; margin offset applied here
        X0, X1 = int((MARGIN + x0) * sx), int((MARGIN + x1) * sx)
        Y0, Y1 = int((MARGIN + y0) * sy), int((MARGIN + y1) * sy)
        r = g = b = n = 0
        for y in range(Y0, Y1):
            row = rows[y]
            for x in range(X0, X1):
                o = x * bpp
                r += row[o]; g += row[o + 1]; b += row[o + 2]; n += 1
        return "#%02x%02x%02x" % (r // n, g // n, b // n)
    return {
        "footer_w": mean(72, 196.6, 252, 199.4),
        "footer_b": mean(468, 196.6, 648, 199.4),
        "surface_w": mean(72, 150, 252, 175),
        "surface_b": mean(468, 150, 648, 175),
        "ref_w": mean(-36, 60, -8, 140),
        "ref_b": mean(728, 60, 756, 140),
        # The footer's top edge, dark half: the strip just above the boundary
        # (the plane alone) against the strip just below it (whatever the arm
        # puts in the footer). A second glass hand-stacked on the plane shows
        # up as a step between these two; a merged or absorbed footer shows
        # none. The footer glass's top edge is at pane y 178.
        "edge_above": mean(468, 174, 648, 176),
        "edge_below": mean(468, 179, 648, 181),
    }

print(f"{'arm':20} {'footer@w':10} {'footer@b':10} {'surface@w':10} "
      f"{'surface@b':10} {'ref white':10} {'ref black':10} "
      f"{'edge above/below':18}")
for arm in ["absorb", "container", "violation", "container-outermask"]:
    b = bands(f"{out}/pane-{arm}-screen.png")
    print(f"{arm:20} {b['footer_w']:10} {b['footer_b']:10} {b['surface_w']:10} "
          f"{b['surface_b']:10} {b['ref_w']:10} {b['ref_b']:10} "
          f"{b['edge_above']} / {b['edge_below']}")
EOF
echo

# Corner probes read RGBA off the `-l` files, where the mask is exact: outside
# the squircle the window's own buffer is α=0. The bottom corners must be
# OUTSIDE the mask (α=0) and the top corners INSIDE it (α=255) — the top pair
# doubles as the orientation check the first run failed. The `-l` colour being
# a flat slab does not matter here; only the alpha does.
echo "=== corner mask probes (RGBA, -l route; want a=0 bottom, a=255 top) ==="
PIXEL_PY="$PIXEL" python3 - "$OUT" <<'EOF'
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location("pixel", os.environ["PIXEL_PY"])
px = importlib.util.module_from_spec(spec); spec.loader.exec_module(px)
out = sys.argv[1]
print(f"{'arm':20} {'bottom-left':16} {'bottom-right':16} {'top-left':16} {'top-right':16}")
for arm in ["absorb", "container", "violation", "container-outermask"]:
    w, h, bpp, rows = px.read_png(f"{out}/pane-{arm}.png")
    def rgba(fx, fy):
        y, x = int(h * fy), int(w * fx) * bpp
        r = rows[y][x:x + bpp]
        return f"({r[0]},{r[1]},{r[2]},a={r[3] if bpp == 4 else 255})"
    print(f"{arm:20} {rgba(0.004, 0.993):16} {rgba(0.996, 0.993):16} "
          f"{rgba(0.004, 0.007):16} {rgba(0.996, 0.007):16}")
EOF
echo

echo "captures and numbers: $OUT"
echo "The findings live in this probe's README.md; these files are what it cites."
