#!/usr/bin/env python3
"""Reads the wash-sweep captures and prints the contrast curve.

usage: measure.py <capture-directory>

Reuses `Diagnostics/lib/pixel.py`'s PNG decoder (dependency-free) and applies
the WCAG relative-luminance formula. The band fractions below are the contract
with `washsweep.swift`; change one, change both.

The measured route is the `-R` screen composite (`sweep-aNNN-screen.png`).
The `-l` route cannot see this material: a full-pane `NSGlassEffectView`
composites at the window-server level (same as glass-backdrop's sidebar
column), so its `-l` band is a flat slab at every α — verified below rather
than assumed. `-R` carries the display's brightness/EDR tone response at
capture time, so both sides of every contrast are sampled from the same file
(ink from the glyph band, backdrop from the ink-free band) and all absolutes
are within-run only.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import pixel  # noqa: E402

# Band fractions (the contract with washsweep.swift).
WHITE_X = (0.10, 0.35)   # over the backdrop's white half
BLACK_X = (0.65, 0.90)   # over the backdrop's black half
BAND_Y = (0.60, 0.75)    # ink-free band: NO glyph rows (0.55-0.80 held clear)
INK_Y = (0.20, 0.45)     # dense glyph rows, for sampling the drawn ink

ALPHAS = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.9, 1.0]
INK = (0xBB, 0xBB, 0xBB)  # PaneTheme.darkPastel.foreground, the drawn value
FLOOR = 4.5


def lin(c):
    c = c / 255
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def region(w, h, xr, yr):
    x0, x1 = int(w * xr[0]), max(int(w * xr[1]), int(w * xr[0]) + 1)
    y0, y1 = int(h * yr[0]), max(int(h * yr[1]), int(h * yr[0]) + 1)
    return x0, x1, y0, y1


def mean(img, xr, yr):
    w, h, bpp, rows = img
    x0, x1, y0, y1 = region(w, h, xr, yr)
    r = g = b = n = 0
    for y in range(y0, y1):
        row = rows[y]
        for x in range(x0, x1):
            o = x * bpp
            r += row[o]
            g += row[o + 1]
            b += row[o + 2]
            n += 1
    return (r // n, g // n, b // n)


def brightest(img, xr, yr):
    w, h, bpp, rows = img
    x0, x1, y0, y1 = region(w, h, xr, yr)
    best, best_c = -1, (0, 0, 0)
    for y in range(y0, y1):
        row = rows[y]
        for x in range(x0, x1):
            o = x * bpp
            c = (row[o], row[o + 1], row[o + 2])
            if sum(c) > best:
                best, best_c = sum(c), c
    return best_c


def hexed(c):
    return "#%02x%02x%02x" % c


def shipped_arm(out):
    """The SHIPPED-DEFAULT arm and its negative control.

    The sweep asks where the crossing sits. This asks the narrower question the
    shipped feature has to answer: **does the value baia ships clear AA on this
    run's tone response?** The α is not a literal here either — it is read from
    `shipped-default.txt`, which `washsweep.swift` wrote after reading
    `ChromeMaterials.PaneWash.floor` off the linked package at run time.

    The control renders the same pane with the wash view *removed from the view
    tree*. Two verdicts are printed because only one of them is trustworthy on
    an arbitrary run:

    - **Absolute:** the control must fail 4.5:1. This is the check that has real
      teeth, and it holds on a bright tone-response day. It cannot be relied on
      universally: the sweep's own α = 0.00 row cleared 4.5:1 on the dark
      tone-response run of record, i.e. bare glass over the bright half can pass
      without a wash. Where that happens the absolute control is vacuous, not
      violated.
    - **Relative:** the washed band must be darker than the unwashed band by at
      least what finding 3's linear model predicts,
      `band(α) = α·wash + (1 − α)·band(0)`, allowing the model's own ±1 byte
      tolerance plus one byte of capture noise. This holds on every tone
      response, because both bands come from the same capture session and the
      model is a statement about compositing, not about the display.

    `run.sh` reads the machine-readable verdict lines this prints.
    """
    washed_path = os.path.join(out, "shipped-default-screen.png")
    control_path = os.path.join(out, "shipped-control-nowash-screen.png")
    floor_path = os.path.join(out, "shipped-default.txt")

    print("")
    print("=== the SHIPPED-DEFAULT arm (does today's default clear AA on this run?) ===")

    if not os.path.exists(floor_path):
        print("  MISSING shipped-default.txt (the run-time-read floor)")
        print("SHIPPED-ARM: INCONCLUSIVE")
        return
    with open(floor_path) as handle:
        alpha = float(handle.read().strip())
    print("  α = ChromeMaterials.PaneWash.floor = %.4f, read off PaneChrome at run time" % alpha)

    missing = [p for p in (washed_path, control_path) if not os.path.exists(p)]
    if missing:
        for path in missing:
            print("  MISSING %s" % os.path.basename(path))
        print("SHIPPED-ARM: INCONCLUSIVE")
        return

    washed = pixel.read_png(washed_path)
    control = pixel.read_png(control_path)

    # The bright half is the worst case; the dark half is printed beside it so a
    # reader can see both, but only the bright half carries the assertion.
    rows = []
    for label, xr in (("WHITE (worst case)", WHITE_X), ("BLACK", BLACK_X)):
        w_band = mean(washed, xr, BAND_Y)
        w_ink = brightest(washed, xr, INK_Y)
        c_band = mean(control, xr, BAND_Y)
        c_ink = brightest(control, xr, INK_Y)
        rows.append((label, w_band, w_ink, contrast(w_ink, w_band),
                     c_band, c_ink, contrast(c_ink, c_band)))

    print("  half               | washed band | ink       | contrast | control band | ink       | contrast")
    for label, wb, wi, wc, cb, ci, cc in rows:
        print("  %-18s | %s     | %s   | %6.2f:1 | %s      | %s   | %6.2f:1" % (
            label, hexed(wb), hexed(wi), wc, hexed(cb), hexed(ci), cc))
    print("  (wallpaper caveat: the underlay is a pure-white/pure-black seam, the worst")
    print("   case by construction; every absolute here is within-run only — see the")
    print("   tone-response line at the top of this file and calibration.png)")

    _, washed_band, _, washed_contrast, control_band, _, control_contrast = rows[0]

    print("")
    if washed_contrast >= FLOOR:
        print("SHIPPED-ARM: PASS — %.2f:1 >= %.1f:1 at α %.4f on the bright half"
              % (washed_contrast, FLOOR, alpha))
    else:
        print("SHIPPED-ARM: FAIL — %.2f:1 < %.1f:1 at α %.4f on the bright half"
              % (washed_contrast, FLOOR, alpha))

    # The absolute control.
    if control_contrast < FLOOR:
        print("SHIPPED-CONTROL-ABSOLUTE: FAIL-AS-REQUIRED — wash removed reads %.2f:1 < %.1f:1"
              % (control_contrast, FLOOR))
    else:
        print("SHIPPED-CONTROL-ABSOLUTE: VACUOUS — wash removed still reads %.2f:1 >= %.1f:1;"
              % (control_contrast, FLOOR))
        print("  bare glass clears AA on this run's tone response (the sweep's α = 0.00 row")
        print("  does the same), so the absolute control proves nothing here. The relative")
        print("  control below is the arm that has teeth on this run.")

    # The relative control: finding 3's linear model, which transfers between
    # tone responses where the absolutes do not. `wash` is the theme background
    # byte the wash paints; read it off the α = 1.00 sweep capture rather than
    # transcribing `#141414`, so the model's constant comes from this run too.
    opaque_path = os.path.join(out, "sweep-a100-screen.png")
    if os.path.exists(opaque_path):
        wash_byte = mean(pixel.read_png(opaque_path), WHITE_X, BAND_Y)
    else:
        wash_byte = None

    print("")
    if wash_byte is None:
        print("SHIPPED-CONTROL-RELATIVE: INCONCLUSIVE — sweep-a100-screen.png absent, so the")
        print("  model's wash constant cannot be read off this run")
        return

    # Per channel, because the bands are near-neutral but not exactly so.
    predicted = tuple(alpha * wash_byte[i] + (1 - alpha) * control_band[i] for i in range(3))
    # ±1 for the model's own fit tolerance (finding 3), ±1 for capture noise.
    tolerance = 2.0
    deltas = [washed_band[i] - predicted[i] for i in range(3)]
    worst = max(abs(d) for d in deltas)
    print("SHIPPED-CONTROL-RELATIVE: the linear model band(α) = α·wash + (1−α)·band(0)")
    print("  wash constant (α = 1.00 capture, bright half): %s" % hexed(wash_byte))
    print("  unwashed band %s  ->  predicts %s at α %.4f" % (
        hexed(control_band),
        "#%02x%02x%02x" % tuple(int(round(p)) for p in predicted),
        alpha))
    print("  measured washed band %s (per-channel error %s, tolerance ±%.0f)" % (
        hexed(washed_band), ", ".join("%+.1f" % d for d in deltas), tolerance))
    darker = all(washed_band[i] <= control_band[i] for i in range(3))
    if darker and worst <= tolerance:
        print("SHIPPED-CONTROL-RELATIVE: PASS — the wash darkened the band by the predicted")
        print("  amount, so the layer is doing the work the assertion credits it with")
    elif not darker:
        print("SHIPPED-CONTROL-RELATIVE: FAIL — the washed band is not darker than the")
        print("  unwashed band; the wash layer is not darkening the pane at all")
    else:
        print("SHIPPED-CONTROL-RELATIVE: FAIL — the washed band is darker, but by %.1f bytes"
              % worst)
        print("  more error than the linear model allows; the compositing changed")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: measure.py <capture-directory>")
    out = sys.argv[1]

    cal = os.path.join(out, "calibration.png")
    if os.path.exists(cal):
        img = pixel.read_png(cal)
        white = mean(img, WHITE_X, (0.2, 0.8))
        black = mean(img, BLACK_X, (0.2, 0.8))
        print("=== this run's tone response (bare backdrop through -R) ===")
        print("  pure white reads %s, pure black reads %s" % (hexed(white), hexed(black)))
        print("  (glass-backdrop measured white at #373737 and #7d7d7d on other days;")
        print("   every absolute below moves with this value and is within-run only)")
        print("")

    print("=== the curve (-R route; sampled ink vs ink-free band; within-run only) ===")
    print("     α | WHITE band | ink       | contrast |  >=4.5 | BLACK band | ink       | contrast |  >=4.5")
    first_clear = None
    later_fail = []
    for a in ALPHAS:
        name = "sweep-a%03d-screen.png" % round(a * 100)
        path = os.path.join(out, name)
        if not os.path.exists(path):
            print("  %.2f | MISSING %s" % (a, name))
            continue
        img = pixel.read_png(path)
        white = mean(img, WHITE_X, BAND_Y)
        black = mean(img, BLACK_X, BAND_Y)
        ink_w = brightest(img, WHITE_X, INK_Y)
        ink_b = brightest(img, BLACK_X, INK_Y)
        cw = contrast(ink_w, white)
        cb = contrast(ink_b, black)
        print("  %.2f | %s    | %s   | %6.2f:1 | %6s | %s    | %s   | %6.2f:1 | %6s" % (
            a, hexed(white), hexed(ink_w), cw, "yes" if cw >= FLOOR else "NO",
            hexed(black), hexed(ink_b), cb, "yes" if cb >= FLOOR else "NO"))
        if cw >= FLOOR and first_clear is None:
            first_clear = a
        if first_clear is not None and cw < FLOOR:
            later_fail.append(a)

    print("")
    if first_clear is None:
        print("no α in the sweep clears %.1f:1 on the white (worst) half" % FLOOR)
    else:
        print("minimum α clearing %.1f:1 on the white (worst) half: %.2f" % (FLOOR, first_clear))
    if later_fail:
        print("NON-MONOTONIC: these α above the crossing fail again: %s" % later_fail)

    print("")
    print("=== the -l negative result (flat slab; recorded, not measured) ===")
    print("     α | -l band left / right (must be flat #141414-ish at every α) | drawn ink (brightest)")
    for a in ALPHAS:
        name = "sweep-a%03d.png" % round(a * 100)
        path = os.path.join(out, name)
        if not os.path.exists(path):
            print("  %.2f | MISSING %s" % (a, name))
            continue
        img = pixel.read_png(path)
        left = mean(img, WHITE_X, BAND_Y)
        right = mean(img, BLACK_X, BAND_Y)
        ink = brightest(img, WHITE_X, INK_Y)
        flag = "" if sum(abs(l - r) for l, r in zip(left, right)) <= 12 else "  <-- SPLIT: -l saw the backdrop after all"
        warn = "" if all(abs(g - i) <= 6 for g, i in zip(ink, INK)) else "  <-- ink off nominal #bbbbbb"
        print("  %.2f | %s / %s%s | %s%s" % (a, hexed(left), hexed(right), flag, hexed(ink), warn))

    shipped_arm(out)

    print("")
    print("=== wallpaper, for the record (wallpaper-dependent; not comparable) ===")
    for a in (0.0, 0.65):
        name = "wallpaper-a%03d-screen.png" % round(a * 100)
        path = os.path.join(out, name)
        if not os.path.exists(path):
            print("  %.2f | MISSING %s" % (a, name))
            continue
        img = pixel.read_png(path)
        left = mean(img, WHITE_X, BAND_Y)
        right = mean(img, BLACK_X, BAND_Y)
        ink_l = brightest(img, WHITE_X, INK_Y)
        ink_r = brightest(img, BLACK_X, INK_Y)
        print("  α %.2f | band left %s (ink %s, %5.2f:1) | band right %s (ink %s, %5.2f:1)" % (
            a, hexed(left), hexed(ink_l), contrast(ink_l, left),
            hexed(right), hexed(ink_r), contrast(ink_r, right)))


if __name__ == "__main__":
    main()
