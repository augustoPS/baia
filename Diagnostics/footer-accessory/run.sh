#!/bin/bash
# Builds and runs the footer-accessory probe: plan 5's hand-managed footer
# beside an NSSplitViewItemAccessoryViewController footer, scroll edge effect
# styles enumerated as arms.
#
#   ./run.sh [output-directory]
#
# Captures land in the output directory (default: a scratch directory under
# TMPDIR). Nothing is written into the repo.
#
# Meets the SAFE_PROBES standard the same way glass-backdrop does: the binary
# is `.accessory`, never key, never active, and quits nothing. It does put four
# windows on screen for about twenty seconds — they appear over whatever is in
# front, take no focus, scroll their own content, and are ordered out again.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-${TMPDIR:-/tmp}/baia-footer-accessory}
BUILD="$OUT/build"
LIB="$BUILD/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here; see
# glass-backdrop/run.sh for the staleness failure that rule closed.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

# Links `PaneChrome` only for values: the bar geometry
# (`PaneStatusBarMetrics`) and the shipped fill (`MaterialSet.dark.fillChrome`)
# are read off the package at run time rather than transcribed, so the
# hand-managed control cannot grade against numbers that have since moved.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so the probe compiles under the rules the code
# it mirrors ships under.
swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/footeraccessory" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/footeraccessory.swift"

"$BUILD/footeraccessory" "$OUT"
