#!/usr/bin/env python3
"""Create two PNG files and an independently quoted expected PTY payload."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zlib


def quoted(path):
    if re.fullmatch(r"[A-Za-z0-9./_@+:-]+", path):
        return path
    return "'" + path.replace("'", "'\\''") + "'"


def create(root):
    root.mkdir(parents=True, exist_ok=True)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"\0\x42\xa0\xe8"))
           + chunk(b"IEND", b""))
    files = []
    for name in ["first image 'quote' $.png", "second `tick` café.png"]:
        path = root / name
        path.write_bytes(png)
        files.append({"url": path.as_uri(), "sha256": hashlib.sha256(png).hexdigest()})
    (root / "manifest.json").write_text(json.dumps({"files": files}, indent=2) + "\n")
    paths = [str(root / name) for name in ["first image 'quote' $.png", "second `tick` café.png"]]
    (root / "expected-payload.bin").write_bytes("".join(quoted(path) + " " for path in paths).encode())


if __name__ == "__main__":
    create(Path(sys.argv[1]).resolve())
