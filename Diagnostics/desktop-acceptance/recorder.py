#!/usr/bin/env python3
"""Raw-mode stdin recorder for a scratch pane.

Run it inside the pane under test before an approval or key-event case. It
puts the controlling terminal into raw mode, records every byte stdin
delivers with a timestamp (hex only, never interpreted), and restores the
saved termios on every exit path: stop file, deadline, three consecutive
Ctrl-D bytes, SIGTERM, SIGHUP, or an unexpected error.

Files in --out (created 0700, must not already exist):
  meta.json     pid, pane (from BAIA_PANE), tty, label, start time
  bytes.jsonl   one line per read: {"at": epoch, "hex": "...", "len": n}
  summary.json  totals, counts of 0x0D and 0x1B, stop reason, termios restored

It echoes what it records as sanitized text (printable ASCII as-is, every other
byte as <XX>) so a screenshot of the pane agrees with the file.
"""

import argparse
import json
import os
import select
import signal
import sys
import termios
import time
import tty

STOP_NAME = "stop"
CTRL_D = 0x04
CR = 0x0D
ESC = 0x1B


def sanitized(data):
    parts = []
    for byte in data:
        if 0x20 <= byte < 0x7F:
            parts.append(chr(byte))
        else:
            parts.append("<%02X>" % byte)
    return "".join(parts)


def write_json(path, document):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


class Recorder:
    def __init__(self, out, seconds, label, fd=0):
        self.out = out
        self.seconds = seconds
        self.label = label
        self.fd = fd
        self.saved = None
        self.restored = None
        self.reason = None
        self.total = 0
        self.cr = 0
        self.esc = 0
        self.reads = 0
        self.consecutive_ctrl_d = 0
        self.log = None

    def emit(self, text):
        target = 1 if os.isatty(1) else self.fd
        try:
            os.write(target, text.encode("utf-8", "replace"))
        except OSError:
            pass

    def restore(self):
        if self.saved is None or self.restored is not None:
            return
        # TCSANOW, not TCSADRAIN: drain waits for the master side to read
        # every pending byte, which blocks forever when nothing is reading
        # (a headless pty, a pane whose reader is gone), and a blocked restore
        # leaves the terminal raw.
        try:
            termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)
            self.restored = True
        except termios.error:
            self.restored = False

    def stop(self, reason):
        if self.reason is None:
            self.reason = reason

    def handle_signal(self, number, _frame):
        self.stop("signal-%d" % number)

    def record(self, data):
        now = time.time()
        self.total += len(data)
        self.reads += 1
        self.cr += data.count(bytes([CR]))
        self.esc += data.count(bytes([ESC]))
        for byte in data:
            self.consecutive_ctrl_d = self.consecutive_ctrl_d + 1 if byte == CTRL_D else 0
        self.log.write(json.dumps({"at": now, "hex": data.hex(), "len": len(data)}) + "\n")
        self.log.flush()
        os.fsync(self.log.fileno())
        self.emit(sanitized(data))
        if self.consecutive_ctrl_d >= 3:
            self.stop("ctrl-d-x3")

    def run(self):
        os.mkdir(self.out, 0o700)
        if not os.isatty(self.fd):
            raise SystemExit("recorder needs a terminal on stdin")
        self.saved = termios.tcgetattr(self.fd)
        try:
            tty_name = os.ttyname(self.fd)
        except OSError:
            tty_name = None
        write_json(os.path.join(self.out, "meta.json"), {
            "pid": os.getpid(),
            "pane": os.environ.get("BAIA_PANE"),
            "tty": tty_name,
            "label": self.label,
            "startedAt": time.time(),
            "seconds": self.seconds,
            "stopFile": os.path.join(self.out, STOP_NAME),
        })
        descriptor = os.open(os.path.join(self.out, "bytes.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        self.log = os.fdopen(descriptor, "w", encoding="utf-8")
        for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(number, self.handle_signal)
        deadline = time.monotonic() + self.seconds
        stop_file = os.path.join(self.out, STOP_NAME)
        try:
            tty.setraw(self.fd, termios.TCSANOW)
            self.emit("recorder ready pane=%s out=%s\r\n" % (os.environ.get("BAIA_PANE"), self.out))
            while self.reason is None:
                if os.path.exists(stop_file):
                    self.stop("stop-file")
                    break
                if time.monotonic() >= deadline:
                    self.stop("deadline")
                    break
                try:
                    ready, _, _ = select.select([self.fd], [], [], 0.2)
                except InterruptedError:
                    continue
                if not ready:
                    continue
                try:
                    data = os.read(self.fd, 4096)
                except InterruptedError:
                    continue
                except OSError:
                    self.stop("read-error")
                    break
                if not data:
                    self.stop("eof")
                    break
                self.record(data)
        finally:
            self.restore()
            self.log.close()
            write_json(os.path.join(self.out, "summary.json"), {
                "pid": os.getpid(),
                "pane": os.environ.get("BAIA_PANE"),
                "label": self.label,
                "endedAt": time.time(),
                "reason": self.reason or "error",
                "reads": self.reads,
                "bytes": self.total,
                "cr": self.cr,
                "esc": self.esc,
                "termiosRestored": self.restored,
            })
            self.emit("\r\nrecorder stopped reason=%s bytes=%d cr=%d esc=%d\r\n" % (
                self.reason, self.total, self.cr, self.esc))


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="new directory for meta, bytes and summary")
    parser.add_argument("--seconds", type=float, default=900.0, help="deadline (default 900)")
    parser.add_argument("--label", default="", help="free text recorded in meta and summary")
    return parser.parse_args(argv)


def main(argv=None):
    arguments = parse_arguments(argv)
    if arguments.seconds <= 0 or arguments.seconds > 3600:
        print("seconds must be above 0 and at most 3600", file=sys.stderr)
        return 2
    if not os.path.isabs(arguments.out):
        print("--out must be an absolute path", file=sys.stderr)
        return 2
    if os.path.exists(arguments.out):
        print("--out must not exist yet: %s" % arguments.out, file=sys.stderr)
        return 2
    Recorder(arguments.out, arguments.seconds, arguments.label).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
