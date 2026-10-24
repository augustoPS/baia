#!/usr/bin/env python3
"""Exercise the probe's own receiver with a real PTY and negative controls."""
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time
import unittest

from fixture import create


class ReceiverTests(unittest.TestCase):
    def run_receiver(self, append=b"", mutate_image=False):
        with tempfile.TemporaryDirectory(prefix="baia-file-drop-receiver-") as directory:
            root = Path(directory)
            create(root)
            if mutate_image:
                next(root.glob("*.png")).write_bytes(b"not an image")
            master, slave = pty.openpty()
            child = subprocess.Popen(
                [sys.executable, str(Path(__file__).with_name("receiver.py")), str(root)],
                stdin=slave, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            )
            os.close(slave)
            try:
                deadline = time.monotonic() + 3
                while not (root / "receiver.ready").exists() and time.monotonic() < deadline:
                    self.assertIsNone(child.poll())
                    time.sleep(0.01)
                self.assertTrue((root / "receiver.ready").exists())
                os.write(master, (root / "expected-payload.bin").read_bytes() + append)
                while not (root / "receiver-result.json").exists() and time.monotonic() < deadline:
                    self.assertIsNone(child.poll())
                    time.sleep(0.01)
                return json.loads((root / "receiver-result.json").read_text())["checks"]
            finally:
                child.terminate()
                try:
                    child.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.communicate(timeout=1)
                os.close(master)

    def test_exact_payload_passes(self):
        self.assertTrue(all(self.run_receiver().values()))

    def test_appended_enter_fails(self):
        checks = self.run_receiver(append=b"\r")
        self.assertFalse(checks["exactPayload"])
        self.assertFalse(checks["noSubmit"])

    def test_changed_image_fails(self):
        checks = self.run_receiver(mutate_image=True)
        self.assertTrue(checks["exactPayload"])
        self.assertFalse(checks["imageHashesMatch"])
        self.assertFalse(checks["validPNG"])


if __name__ == "__main__":
    unittest.main()
