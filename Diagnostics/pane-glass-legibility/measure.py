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
