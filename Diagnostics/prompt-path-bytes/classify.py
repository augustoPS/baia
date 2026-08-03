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
        print(f"  FAIL  {label}")
        print(f"          nothing was written to {path}")
        print("          the command never ran: an unterminated quote leaves zsh at a")
        print("          continuation prompt, which is itself the line editor refusing")
        print("          the bytes rather than a missing click.")
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
