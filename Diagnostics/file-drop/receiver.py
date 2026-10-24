#!/usr/bin/env python3
"""Read real PTY input without a shell line editor or executing the payload."""
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import sys
import termios
import time
import tty
from urllib.parse import unquote, urlsplit


def receive(root):
    expected = (root / "expected-payload.bin").read_bytes()
    manifest = json.loads((root / "manifest.json").read_text())
    previous = termios.tcgetattr(0)
    received = bytearray()
    try:
        tty.setraw(0)
        (root / "receiver.ready").write_text("ready\n")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if not select.select([0], [], [], min(0.25, max(0, deadline - time.monotonic())))[0]:
                continue
            data = os.read(0, 65536)
            if not data:
                break
            received.extend(data)
            if len(received) >= len(expected):
                # Capture an accidental Enter sent just after the insertion too.
                deadline = min(deadline, time.monotonic() + 0.35)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, previous)

    paths = []
    try:
        paths = shlex.split(received.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        pass
    expected_paths = [unquote(urlsplit(row["url"]).path) for row in manifest["files"]]
    checks = {
        "exactPayload": bytes(received) == expected,
        "noSubmit": b"\r" not in received and b"\n" not in received,
        "pathsMatch": paths == expected_paths,
        "imagesReadable": False,
        "imageHashesMatch": False,
        "validPNG": False,
    }
    if paths == expected_paths:
        try:
            images = [Path(path).read_bytes() for path in paths]
            checks["imagesReadable"] = len(images) == 2
            checks["imageHashesMatch"] = all(
                hashlib.sha256(data).hexdigest() == row["sha256"]
                for data, row in zip(images, manifest["files"])
            )
            checks["validPNG"] = all(data.startswith(b"\x89PNG\r\n\x1a\n") for data in images)
        except OSError:
            pass
    result = {"checks": checks, "receivedBytes": len(received), "expectedBytes": len(expected)}
    temporary = root / "receiver-result.tmp"
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.rename(root / "receiver-result.json")
    # Keep the terminal surface alive until the isolated app is torn down.
    while True:
        time.sleep(1)


if __name__ == "__main__":
    receive(Path(sys.argv[1]))
