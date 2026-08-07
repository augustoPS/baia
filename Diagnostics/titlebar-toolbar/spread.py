#!/usr/bin/env python3
"""Grades each titlebar arm on luminance spread, and fails if the fix regressed.

    spread.py <capture-directory>

Spread rather than mean, because the mean cannot answer the question. The
titlebar material is a flat neutral and so is a dark wallpaper behind a bare
titlebar; both average to about the same grey, which is how a shipped build with
no titlebar at all measured "flat neutral (23,23,23)" in this probe's first
generation and was believed fixed. Walking down the strip separates them: the
material holds one value, and show-through varies with whatever is behind the
window.

Two regions per arm:

  band  the titlebar strip, right of the traffic lights. Near-zero spread is
        material; anything approaching the bare-desktop spread is show-through.
  well  the content area. This must KEEP a real spread — that is the desktop
        showing through the wells, which is the whole point of the non-opaque
        window, and an arm that flattens it has fixed the titlebar by making
        the window opaque again.
"""

import importlib.util
import os
import sys

_spec = importlib.util.spec_from_file_location(
    "pixel", os.path.join(os.path.dirname(__file__), "..", "lib", "pixel.py"))
pixel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pixel)

# A band this flat is material. Measured: every materialed arm reads 0.0-0.1,
# every bare one 60+, so the gap is three orders of magnitude and the threshold
# is not a tuned number.
MATERIAL_MAX_SPREAD = 5.0
# A well this flat means the desktop stopped showing through. The opaque
# baseline reads 0.0 and every transparent arm reads 29+.
SHOWTHROUGH_MIN_SPREAD = 10.0


def spread(path, y0f, y1f, x0f, x1f):
    width, height, bpp, rows = pixel.read_png(path)
    x0, x1 = int(width * x0f), int(width * x1f)
    y0, y1 = int(height * y0f), int(height * y1f)
    lums = []
    for y in range(y0, y1):
        total = count = 0
        for x in range(x0, x1, 3):
            r, g, b = pixel.rgb(rows, bpp, x, y)
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            count += 1
        lums.append(total / count)
    return max(lums) - min(lums)


def band(path):
    # Right of the traffic lights, top of the window.
    return spread(path, 0.0, 0.085, 0.55, 0.95)


def well(path):
    return spread(path, 0.45, 0.85, 0.05, 0.95)


def main():
    out = sys.argv[1]
    baseline = os.path.join(out, "baseline.png")

    print(f"{'arm':32s} {'band spread':>12s} {'well spread':>12s}   verdict")
    print(f"{'-' * 32} {'-' * 12:>12s} {'-' * 12:>12s}   -------")
    print(f"{'(bare desktop)':32s} {band(baseline):12.1f} {well(baseline):12.1f}"
          "   no window")

    arms = sorted(f for f in os.listdir(out) if f.startswith("arm-") and f.endswith(".png"))
    failures = []
    for name in arms:
        path = os.path.join(out, name)
        label = name[:-4].split("-", 2)[2]
        b, w = band(path), well(path)

        if b <= MATERIAL_MAX_SPREAD:
            verdict = "MATERIAL"
            if w < SHOWTHROUGH_MIN_SPREAD:
                verdict += ", wells opaque"
        else:
            verdict = "show-through"
        print(f"{label:32s} {b:12.1f} {w:12.1f}   {verdict}")

        # The shipped arrangement is the one the app must not go back to, and
        # the minimal-alpha arm is the one it now uses. Both are asserted, so
        # this probe fails if either the defect returns or the fix stops working.
        if label == "minimal-alpha":
            if b > MATERIAL_MAX_SPREAD:
                failures.append(f"minimal-alpha lost its titlebar material (band spread {b:.1f})")
            if w < SHOWTHROUGH_MIN_SPREAD:
                failures.append(f"minimal-alpha stopped showing the desktop through (well spread {w:.1f})")
        if label == "shipped-clear" and b <= MATERIAL_MAX_SPREAD:
            failures.append(
                "shipped-clear now reads as material, so this probe no longer "
                "reproduces the defect it exists to explain")

    # The SIGWINCH assertion, read off the probe's own log: every geometry line
    # must be identical, or flipping the background moved something the pane
    # tree lays out against.
    log = os.path.join(out, "arms.log")
    if os.path.exists(log):
        lines = open(log).read().splitlines()
        try:
            start = lines.index("--- geometry across the background flip (must not move) ---")
        except ValueError:
            start = None
        if start is not None:
            geometry = [ln for ln in lines[start + 1:] if ln.strip()]
            print()
            print("geometry across the background flip:")
            for ln in geometry:
                print(f"  {ln}")
            # Compare the measurements only. The label is a padded prefix and
            # differs between rows by construction, so splitting on the first
            # space compares the labels too and every run "fails".
            measured = {
                " ".join(part for part in ln.split() if "=" in part)
                for ln in geometry
            }
            if len(measured) > 1:
                failures.append(
                    "the background flip MOVED window geometry, so it is a live "
                    "grid resize and a SIGWINCH to every running pane")
            elif geometry:
                print("  all identical: the flip moves no geometry, so no pane is resized")

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("A `.clear` window background gives no titlebar material; any non-zero")
    print("alpha gives all of it, and the wells keep the desktop either way.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
