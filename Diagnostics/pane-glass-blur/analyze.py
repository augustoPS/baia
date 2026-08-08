#!/usr/bin/env python3
"""Band metrics for the pane-glass-blur captures.

    analyze.py <png> <fx0> <fy0> <fx1> <fy1>

Prints one line: mean luminance, standard deviation, and the horizontal
neighbour-gradient mean (mean |lum(x+1,y) - lum(x,y)|) over the fractional
band. The gradient is the detail-retention number: the controlled backdrop is
vertical gratings, so surviving fine structure is horizontal luminance change,
and blur is exactly what removes it. Luminance is (r+g+b)/3 on 0..255.

Reuses `Diagnostics/lib/pixel.py`'s dependency-free PNG decoder rather than
carrying a second one.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from pixel import read_png  # noqa: E402


def main():
    if len(sys.argv) != 6:
        raise SystemExit("usage: analyze.py <png> fx0 fy0 fx1 fy1")
    path = sys.argv[1]
    fx0, fy0, fx1, fy1 = (float(v) for v in sys.argv[2:6])
    width, height, bpp, rows = read_png(path)

    x0, x1 = int(width * fx0), max(int(width * fx1), int(width * fx0) + 2)
    y0, y1 = int(height * fy0), max(int(height * fy1), int(height * fy0) + 1)

    total = 0.0
    total_sq = 0.0
    count = 0
    grad = 0.0
    grad_count = 0
    for y in range(y0, y1):
        row = rows[y]
        prev = None
        for x in range(x0, x1):
            o = x * bpp
            lum = (row[o] + row[o + 1] + row[o + 2]) / 3
            total += lum
            total_sq += lum * lum
            count += 1
            if prev is not None:
                grad += abs(lum - prev)
                grad_count += 1
            prev = lum

    mean = total / count
    variance = max(total_sq / count - mean * mean, 0.0)
    print(
        "mean=%.1f std=%.2f hgrad=%.3f"
        % (mean, variance ** 0.5, grad / grad_count)
    )


if __name__ == "__main__":
    main()
