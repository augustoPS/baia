#!/bin/bash
# Builds and runs the pane-glass-inactive probe, then measures the captures.
#
#   ./run.sh [output-directory]
#
# Captures land in Diagnostics/pane-glass-inactive/captures/ by default — INSIDE
# the repo, on purpose: the owner rules on these files and the spec will
# reference them, so they live at a stable path rather than under TMPDIR.
#
# **NOT safe from inside a baia pane, and deliberately not in the guard's
# `SAFE_PROBES` list.** This probe takes the keyboard for about two seconds. That
# is not a side effect to be engineered away: the question is what
# NSGlassEffectView looks like when its window IS key versus when it is not, and
# a key state cannot be photographed without holding key. The probe records the
# frontmost app before starting, holds key only across one capture, then yields
# activation back to that app and captures the inactive state. Keystrokes typed
# during those two seconds land in the probe's window (which ignores them), not
# in your pane — which is exactly why it must be run from a second terminal, or
# from a pane nobody is typing into. Same standing as design-panel-key.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:-$HERE/captures}
BUILD=${TMPDIR:-/tmp}/baia-pane-glass-inactive-build
mkdir -p "$OUT" "$BUILD"

# No package is linked: the probe reaches nothing but AppKit, and the wash/tint
# values are stated stand-ins (see README), not readings off PaneChrome.
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION.
swiftc -swift-version 6 -default-isolation MainActor \
  -o "$BUILD/glassinactive" "$HERE/glassinactivetest.swift"

"$BUILD/glassinactive" "$OUT"
echo

python3 "$HERE/analyze.py" "$OUT" | tee "$OUT/analysis.txt"
