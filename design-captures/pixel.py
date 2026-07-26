#!/usr/bin/env python3
"""Reads pixels out of a screencapture PNG, with no third-party dependency.

Written because the obvious routes are all unavailable here. `sips` reports
metadata but cannot print a pixel, Pillow is not installed, and the first
attempt at this shelled out to `sips` to resize a probe capture to 1x1 and read
that, which silently produced no output file and left the caller reporting an
empty colour as if it were a measurement.

Decodes greyscale, truecolour and alpha variants at 8 bits; a 16-bit capture
would need the stride maths widening, and screencapture does not produce one.
"""

import sys
import zlib
import struct


def read_png(path):
    data = open(path, "rb").read()
    pos, idat = 8, b""
    width = height = 0
    depth, ctype = 8, 6
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    if depth != 8:
        raise SystemExit(f"{path}: {depth}-bit PNG is not supported")

    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    bpp = channels
    stride = width * bpp

    rows, prev, i = [], bytearray(stride), 0
    for _ in range(height):
        filt = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        # The five PNG filters, applied in place. Left/up neighbours outside the
        # image are zero by definition.
        if filt == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif filt == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif filt == 3:
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 255
        elif filt == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 255
        rows.append(bytes(line))
        prev = line
    return width, height, bpp, rows


def rgb(rows, bpp, x, y):
    row = rows[y]
    o = x * bpp
    return row[o], row[o + 1], row[o + 2]


def hexed(c):
    return "#%02x%02x%02x" % c


def region(width, height, args):
    """Fractions of the image, so a caller does not need its pixel size."""
    fx0, fy0, fx1, fy1 = (float(v) for v in args)
    return (int(width * fx0), int(height * fy0),
            max(int(width * fx1), int(width * fx0) + 1),
            max(int(height * fy1), int(height * fy0) + 1))


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: pixel.py <at|brightest|mean> <png> fx0 fy0 [fx1 fy1]")
    verb, path = sys.argv[1], sys.argv[2]
    width, height, bpp, rows = read_png(path)

    if verb == "at":
        fx, fy = float(sys.argv[3]), float(sys.argv[4])
        print(hexed(rgb(rows, bpp, int(width * fx), int(height * fy))))
        return

    x0, y0, x1, y1 = region(width, height, sys.argv[3:7])

    if verb == "brightest":
        best = (-1, (0, 0, 0))
        for y in range(y0, y1):
            for x in range(x0, x1):
                c = rgb(rows, bpp, x, y)
                if sum(c) > best[0]:
                    best = (sum(c), c)
        print(hexed(best[1]))
    elif verb == "mean":
        r = g = b = n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                c = rgb(rows, bpp, x, y)
                r += c[0]; g += c[1]; b += c[2]; n += 1
            # Sampling every row is enough at these sizes; no stride skipping,
            # so the number is the real mean rather than an estimate.
        print(hexed((r // n, g // n, b // n)))
    else:
        raise SystemExit(f"unknown verb {verb}")


if __name__ == "__main__":
    main()
