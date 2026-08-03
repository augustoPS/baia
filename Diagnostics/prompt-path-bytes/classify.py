#!/usr/bin/env python3
"""Says what arrived and which layer ate the byte, if one did.

    classify.py <label> <file> <expected-bytes> <lossy-bytes>

Split out of `run.sh` rather than inlined, because a heredoc inside a heredoc
inside a shell function is the kind of construct that breaks silently a month
later, and because the classification is the whole product of this probe: the
question is not whether the path arrived but *where* it stopped.

Exit 0 only on a byte-for-byte match. Every other outcome is a failure with a
different diagnosis printed above it.
"""
import sys


def main() -> int:
    label, path, expected_path, lossy_path = sys.argv[1:5]

    try:
        got = open(path, "rb").read()
    except FileNotFoundError:
        # Deliberately does not name a cause. It named one until 2026-08-03,
        # "an unterminated quote leaves zsh at a continuation prompt", which is
        # only the most interesting of several and was wrong on the run that
        # exposed it: that run had no Accessibility permission, so nothing was
        # ever typed and the confident diagnosis pointed at the shell. A missing
        # file is the one outcome that carries no information about bytes.
        print(f"  FAIL  {label}")
        print(f"          nothing was written to {path}")
        print("          this says nothing about the bytes. The command never ran, and")
        print("          the reasons are not distinguishable from here: an unterminated")
        print("          quote leaving zsh at a continuation prompt, a click that landed")
        print("          on the wrong row, or a keystroke that never left the harness.")
        print("          Read the capture beside it before concluding anything.")
        return 1

    # The Return that hands the line to a canonical-mode reader is not part of
    # the path. Exactly one, since that is exactly how many were typed.
    if got.endswith(b"\n"):
        got = got[:-1]

    expected = open(expected_path, "rb").read()
    lossy = open(lossy_path, "rb").read()

    print(f"          got:    {got!r}")

    if got == expected:
        print(f"  ok    {label}: byte for byte, the 0xE9 intact")
        return 0

    if got == lossy:
        print(f"  FAIL  {label}: U+FFFD, which is the pre-fix behaviour exactly")
        print("          the path went through a Swift String somewhere on the route.")
        return 1

    if b"\xe9" in got:
        print(f"  FAIL  {label}: the 0xE9 survived but the bytes differ")
        print(f"          wanted: {expected!r}")
        return 1

    if expected.startswith(got):
        print(f"  FAIL  {label}: truncated before the 0xE9")
        print(f"          wanted: {expected!r}")
        print("          everything from the first byte that is not valid UTF-8 was")
        print("          dropped upstream of this reader.")
        return 1

    print(f"  FAIL  {label}: unrecognised")
    print(f"          wanted: {expected!r}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
