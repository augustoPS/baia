#!/bin/bash
# Builds and runs the titlebar-merge probe. One binary, one question: can the
# titlebar band and the sidebar column read as ONE glass panel?
#
#   ./run.sh [output-directory]
#
# Captures land in the output directory (default: a scratch directory under
# TMPDIR). Nothing is written into the repo.
#
# This binary never activates, never makes a window key, and neither quits nor
# launches baia. `NSApplication.setActivationPolicy(.accessory)` plus
# `orderFrontRegardless()` is the `SAFE_PROBES` standard, and this probe meets it
# the way `glass-backdrop` does rather than the way `override-wires` does: it puts
# real windows on screen for about twenty seconds, over a full-screen white/black
# backdrop it needs as a controlled thing for glass to sample. Windows appear over
# whatever is in front, take no focus, and are ordered out again.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-${TMPDIR:-/tmp}/baia-titlebar-merge}
BUILD="$OUT/build"
LIB="$BUILD/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here. Six of
# seven probes carried their own copy and went stale, silently, because no `make`
# target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl WorkspaceLayout PaneChrome

# `WorkspaceLayout` is linked for `SidebarGeometry.default.width`, and `PaneChrome`
# for the chrome vocabulary the arms mirror. The arms read the column width off the
# package at run time rather than transcribing 260, so the arm that claims to
# reproduce today's arrangement cannot grade against a number that has since moved.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so the probe compiles under the rules the code it
# mirrors ships under.
swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/mergetest" \
  -I "$LIB" -L "$LIB" \
  -lBaiaSettings -lGitWorkspace -lPaneControl -lWorkspaceLayout -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/mergetest.swift"

echo "=== six arms: shipped two planes, container merge, one full-size plane, flat"
echo "    control, route A (split rect), route D (band drawn by the column) ==="
"$BUILD/mergetest" "$OUT" | tee "$OUT/measurement.txt"
status=${PIPESTATUS[0]}

echo
echo "captures and the strip numbers: $OUT"
echo "The verdict is in this probe's README.md; these files are what it cites."
echo
echo "Every arm asserts the controlled backdrop was behind it before its number is"
echo "published; a displaced backdrop exits non-zero naming the arm. The"
echo "backdrop-check-<arm>.png strips are that assertion's evidence."
exit "$status"
