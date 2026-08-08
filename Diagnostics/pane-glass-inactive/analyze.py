#!/usr/bin/env python3
"""Measures the key/inactive delta in the pane-glass-inactive captures.

Reads geometry.json (written by the probe) for the sample bands, decodes each
capture with Diagnostics/lib/pixel.py's reader, and reports per-band mean
luminance and mean HSV saturation, plus the key-minus-inactive delta. Also crops
each plane out of the KEY/INACTIVE pair into self-describing per-plane files, so
the owner can rule on one plane without squinting at thirds of a frame.

Within-run numbers only: every capture is `screencapture -R`, which carries the
display's tone response at capture time (measured in glass-backdrop's README).
The deltas cancel it; the absolutes do not transfer between runs.
"""

import json
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from pixel import read_png  # noqa: E402


def band_stats(rows, bpp, width, height, frac):
    x0 = int(width * frac["x0"])
    x1 = max(int(width * frac["x1"]), x0 + 1)
    y0 = int(height * frac["y0"])
    y1 = max(int(height * frac["y1"]), y0 + 1)
    n = rsum = gsum = bsum = 0
    lum = sat = 0.0
    for y in range(y0, y1):
        row = rows[y]
        for x in range(x0, x1):
            o = x * bpp
            r, g, b = row[o], row[o + 1], row[o + 2]
            rsum += r
            gsum += g
            bsum += b
            lum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            mx = max(r, g, b)
            if mx:
                sat += (mx - min(r, g, b)) / mx
            n += 1
    return {
        "mean": (rsum // n, gsum // n, bsum // n),
        "lum": lum / n,
        "sat": sat / n,
    }


def crop(rows, bpp, width, height, frac, path):
    """Writes the fractional region out as its own PNG (filter 0, RGB)."""
    x0 = int(width * frac["x0"])
    x1 = int(width * frac["x1"])
    y0 = int(height * frac["y0"])
    y1 = int(height * frac["y1"])
    w, h = x1 - x0, y1 - y0
    raw = bytearray()
    for y in range(y0, y1):
        row = rows[y]
        raw.append(0)
        for x in range(x0, x1):
            o = x * bpp
            raw += row[o:o + 3]

    def chunk(kind, payload):
        data = kind + payload
        return struct.pack(">I", len(payload)) + data + struct.pack(">I", zlib.crc32(data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        f.write(chunk(b"IEND", b""))


def hexed(c):
    return "#%02x%02x%02x" % c


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "captures"
    with open(os.path.join(out, "geometry.json")) as f:
        geo = json.load(f)

    captures = [
        ("pair-KEY.png", "key"),
        ("pair-INACTIVE.png", "inactive"),
        ("pair-INACTIVE-before-key.png", "inactive-before"),
        ("override-pretend-key.png", "override"),
    ]
    stats = {}
    decoded = {}
    for filename, label in captures:
        path = os.path.join(out, filename)
        if not os.path.exists(path):
            continue
        width, height, bpp, rows = read_png(path)
        decoded[label] = (width, height, bpp, rows)
        for plane in geo["planes"]:
            for band in ("washed", "bare"):
                stats[(label, plane["name"], band)] = band_stats(
                    rows, bpp, width, height, plane[band])

    # Backdrop saturation, for the wallpaper caveat.
    ref = os.path.join(out, "backdrop-reference.png")
    if os.path.exists(ref):
        width, height, bpp, rows = read_png(ref)
        whole = band_stats(rows, bpp, width, height,
                           {"x0": 0.02, "x1": 0.98, "y0": 0.02, "y1": 0.98})
        print(f"backdrop reference: mean {hexed(whole['mean'])}  "
              f"lum {whole['lum']:.1f}  sat {whole['sat']:.3f}")
        print()

    print(f"{'plane':16} {'band':7} {'state':16} {'mean':9} {'lum':>7} {'sat':>7}")
    for plane in geo["planes"]:
        for band in ("washed", "bare"):
            for _, label in captures:
                s = stats.get((label, plane["name"], band))
                if s:
                    print(f"{plane['name']:16} {band:7} {label:16} "
                          f"{hexed(s['mean']):9} {s['lum']:7.1f} {s['sat']:7.3f}")
            key = stats.get(("key", plane["name"], band))
            inact = stats.get(("inactive", plane["name"], band))
            if key and inact:
                print(f"{plane['name']:16} {band:7} {'DELTA key-inact':16} "
                      f"{'':9} {key['lum'] - inact['lum']:+7.1f} {key['sat'] - inact['sat']:+7.3f}")
            over = stats.get(("override", plane["name"], band))
            if key and over:
                print(f"{plane['name']:16} {band:7} {'DELTA key-override':18} "
                      f"{key['lum'] - over['lum']:+7.1f} {key['sat'] - over['sat']:+7.3f}")
        print()

    # Per-plane crop pairs for the owner's eye.
    for label, suffix in (("key", "KEY"), ("inactive", "INACTIVE"), ("override", "OVERRIDE")):
        if label not in decoded:
            continue
        width, height, bpp, rows = decoded[label]
        for plane in geo["planes"]:
            crop(rows, bpp, width, height, plane["plane"],
                 os.path.join(out, f"pair-{plane['name']}-{suffix}.png"))
    print("per-plane crop pairs written")


if __name__ == "__main__":
    main()
