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

# Glass is a THIRD state and spread alone cannot name it, which is the second
# time this probe's verdict metric has had to grow. Generation two separated
# the system slab from bare wallpaper on spread, and that worked because those
# two differ by three orders of magnitude. Glass sits between them and landed
# at 5.8 against a 5.0 threshold — a hair the wrong side of a line drawn for a
# different question, which would have graded the winning arrangement a
# failure.
#
# What actually distinguishes the three is the pair (mean, spread) read against
# the bare desktop behind the same rectangle:
#
#   slab     mean 36.9, spread  0.04  blocks the desktop entirely
#   nothing  mean 99.4, spread 26.6   passes it through nearly raw
#   glass    mean 68.9, spread  5.8   keeps the desktop's structure but softens
#                                     it, here by about 4.5x
#
# **Spread is the discriminator and the mean is only reported.** An earlier
# version of this grader also required the band's mean to sit near the bare
# desktop's, and that test is unsound: the baseline samples the whole strip of
# uncovered wallpaper, while an arm's band samples whatever is behind the
# window at its own position, so the two means describe different backdrops and
# a bright baseline failed a band that was visibly, correctly glass. What the
# three states genuinely differ in is how much of the backdrop's *structure*
# survives, which is a ratio against that same backdrop and needs no absolute.
# Both bounds are generous because the three clusters are far apart; the point
# is the shape of the test, not a tuned constant.
GLASS_MIN_STRUCTURE_LOSS = 2.5   # band spread must be this many times flatter
GLASS_MAX_SPREAD = 20.0          # ...and not merely a slightly-hazy wallpaper

# **The glass test needs a textured backdrop and silently cannot run without
# one.** Everything above distinguishes glass from the slab by what glass does
# to the desktop's *structure*, so a backdrop with no structure leaves the two
# indistinguishable: measured on a near-uniform one (baseline band spread 6.5)
# the glass arm reads spread 1.3 and grades "flat slab", which is not a
# regression, it is the question being unanswerable.
#
# **And "bare desktop" is a claim about the screen, not a fact the probe can
# arrange.** The baseline is captured at one fixed screen rect, and anything
# parked there is what gets measured — the first plain-backdrop run of this
# grader turned out to be a terminal window sitting at that spot, its own text
# averaging down to a flat grey, not a plain wallpaper at all. The probe cannot
# clear the screen for itself, so the honest move is to say when the backdrop
# it got cannot answer the question, and skip the glass assertions rather than
# fail them. A probe that fails on an unluckily-covered desktop teaches the
# next reader to ignore its failures.
GLASS_MIN_BASELINE_SPREAD = 25.0


def glass_verdict(band_spread, base_spread):
    """Names which of the three states a band is in, or None if it is glass.

    Returns the string "unmeasurable" when the backdrop carries too little
    structure for the question to have an answer this run.
    """
    if base_spread < GLASS_MIN_BASELINE_SPREAD:
        return "unmeasurable"
    if band_spread <= MATERIAL_MAX_SPREAD:
        return "flat slab (no desktop through it)"
    if band_spread > GLASS_MAX_SPREAD or base_spread / max(band_spread, 0.01) < GLASS_MIN_STRUCTURE_LOSS:
        return "bare show-through (nothing in the band)"
    return None


def profile(path, y0f, y1f, x0f, x1f):
    """Row luminances down the region, so callers can take spread and mean."""
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
    return lums


def spread(path, y0f, y1f, x0f, x1f):
    lums = profile(path, y0f, y1f, x0f, x1f)
    return max(lums) - min(lums)


def band(path):
    # Right of the traffic lights, top of the window.
    return spread(path, 0.0, 0.085, 0.55, 0.95)


def band_mean(path):
    lums = profile(path, 0.0, 0.085, 0.55, 0.95)
    return sum(lums) / len(lums)


def well(path):
    return spread(path, 0.45, 0.85, 0.05, 0.95)


def main():
    out = sys.argv[1]
    baseline = os.path.join(out, "baseline.png")

    base_spread, base_mean = band(baseline), band_mean(baseline)

    print(f"{'arm':32s} {'band spread':>12s} {'band mean':>10s} {'well spread':>12s}   verdict")
    print(f"{'-' * 32} {'-' * 12:>12s} {'-' * 10:>10s} {'-' * 12:>12s}   -------")
    print(f"{'(bare desktop)':32s} {base_spread:12.1f} {base_mean:10.1f} "
          f"{well(baseline):12.1f}   no window")

    arms = sorted(f for f in os.listdir(out) if f.startswith("arm-") and f.endswith(".png"))
    failures = []
    for name in arms:
        path = os.path.join(out, name)
        label = name[:-4].split("-", 2)[2]
        b, w, m = band(path), well(path), band_mean(path)
        not_glass = glass_verdict(b, base_spread)

        # The plainness caveat belongs to the arms whose verdict depends on
        # lensing, and to no others: `minimal-alpha` and `opaque-baseline` read
        # MATERIAL because they ARE the slab, and a plain wallpaper takes
        # nothing away from that.
        is_glass_arm = label.startswith("glass-in-")

        if not_glass is None:
            verdict = "GLASS"
        elif is_glass_arm and not_glass == "unmeasurable" and b <= MATERIAL_MAX_SPREAD:
            # Named rather than reported as MATERIAL, so a plain wallpaper does
            # not read as evidence the glass arm regressed to the slab.
            verdict = "flat (wallpaper too plain to tell)"
        elif b <= MATERIAL_MAX_SPREAD:
            verdict = "MATERIAL"
            if w < SHOWTHROUGH_MIN_SPREAD:
                verdict += ", wells opaque"
        else:
            verdict = "show-through"
        print(f"{label:32s} {b:12.1f} {m:10.1f} {w:12.1f}   {verdict}")

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

        # Generation three. `transparent-no-glass` is the control and must read
        # show-through: it proves `titlebarAppearsTransparent` really does stop
        # the system slab painting, so a glass arm's reading is the glass and
        # not the slab surviving underneath it.
        if (label == "transparent-no-glass" and b <= MATERIAL_MAX_SPREAD
                and base_spread >= GLASS_MIN_BASELINE_SPREAD):
            failures.append(
                "transparent-no-glass reads as material, so titlebarAppearsTransparent "
                "did NOT stop the system slab and the glass arms measure the slab")
        # The adopted arrangement, held to the three-state test rather than to
        # a spread threshold. This is the assertion that would have caught the
        # owner's complaint: the shipped `minimal-alpha` band passes MATERIAL
        # and fails GLASS, which is the whole difference between "there is a
        # titlebar" and "the titlebar matches the rest of the chrome".
        if label == "glass-in-frame":
            if not_glass == "unmeasurable":
                print(f"{'':32s} {'':12s} {'':10s} {'':12s}   "
                      f"(glass unverifiable this run: desktop spread {base_spread:.1f} "
                      f"< {GLASS_MIN_BASELINE_SPREAD}; needs a textured wallpaper)")
            elif not_glass is not None:
                failures.append(
                    f"glass-in-frame is not reading as glass: {not_glass} "
                    f"(band spread {b:.1f}, mean {m:.1f} against desktop "
                    f"spread {base_spread:.1f}, mean {base_mean:.1f})")
            if w < SHOWTHROUGH_MIN_SPREAD:
                failures.append(
                    f"glass-in-frame stopped showing the desktop through the wells "
                    f"(well spread {w:.1f})")

    # The SIGWINCH assertion, read off the probe's own log: every geometry line
    # must be identical, or the flip moved something the pane tree lays out
    # against. Asked twice — once of the background colour (the `ea7a223` fix)
    # and once of the titlebar glass (the arrangement generation three adopts),
    # because they change different things and only the second one adds and
    # removes a view.
    log = os.path.join(out, "arms.log")
    if os.path.exists(log):
        lines = open(log).read().splitlines()

        # The losing ownership arm, asserted rather than remembered. Both glass
        # arms produce glass; they are told apart by what they cost. Parenting
        # the backing in the contentViewController's view needs
        # `.fullSizeContentView`, and that moves `contentLayoutRect` — which is
        # what the pane tree lays out against, so adopting it would resize every
        # grid and SIGWINCH every running shell. `glass-in-frame` needs no style
        # mask change and leaves the rect alone. If a future macOS stops
        # charging that, this assertion is where the news arrives.
        facts = {}
        for ln in lines:
            if ":" in ln and "contentLayoutH=" in ln:
                name, rest = ln.split(":", 1)
                facts[name.strip()] = dict(
                    part.split("=", 1) for part in rest.split() if "=" in part)
        content = facts.get("glass-in-content")
        frame = facts.get("glass-in-frame")
        shipped = facts.get("minimal-alpha")
        if content and shipped:
            if content["contentLayoutH"] == shipped["contentLayoutH"]:
                failures.append(
                    "glass-in-content no longer costs content height, so the "
                    "reason glass-in-frame was chosen over it has expired")
            else:
                print()
                print(f"glass-in-content contentLayoutH={content['contentLayoutH']} "
                      f"against the shipped {shipped['contentLayoutH']}: "
                      "fullSizeContentView moves what the pane tree lays out against")
        if frame and shipped and frame["contentLayoutH"] != shipped["contentLayoutH"]:
            failures.append(
                f"glass-in-frame changed contentLayoutH to {frame['contentLayoutH']} "
                f"from the shipped {shipped['contentLayoutH']}, so it is NOT free "
                "and adopting it resizes every grid")
        for name in ("glass-in-frame", "transparent-no-glass"):
            got = facts.get(name)
            if got and got.get("chrome") != "40":
                failures.append(
                    f"{name} chrome is {got.get('chrome')} pt, not the toolbar's 40: "
                    "titlebarAppearsTransparent cost the compact metric")
            if got and (got.get("title") == "GONE" or got.get("subtitle") == "GONE"):
                failures.append(f"{name} lost its title or subtitle")
            if got and got.get("toolbarVisible") != "true":
                failures.append(f"{name} lost its toolbar")

        for header, what in (
            ("--- geometry across the background flip (must not move) ---",
             "the background flip"),
            ("--- geometry across the titlebar-glass flip (must not move) ---",
             "the titlebar-glass flip"),
        ):
            try:
                start = lines.index(header)
            except ValueError:
                continue
            geometry = []
            for ln in lines[start + 1:]:
                if ln.startswith("---"):
                    break
                if ln.strip():
                    geometry.append(ln)
            print()
            print(f"geometry across {what}:")
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
                    f"{what} MOVED window geometry, so it is a live "
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
