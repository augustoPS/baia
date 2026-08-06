#!/bin/bash
# Builds and runs the glass-backdrop spike. Two binaries, two questions.
#
#   ./run.sh [output-directory]
#
# Captures land in the output directory (default: a scratch directory under
# TMPDIR). Nothing is written into the repo.
#
# Neither binary activates, neither makes a window key, and neither quits or
# launches baia. `NSApplication.setActivationPolicy(.accessory)` plus
# `orderFrontRegardless()` is the `SAFE_PROBES` standard that `pane-resize` and
# `theme-refresh` meet, and this probe meets it too. What it does do that they do
# not is put pixels on screen for about ten seconds: windows appear over whatever
# is in front, take no focus, and are ordered out again. See the README's
# "what inactive means here" for why that is the honest arrangement rather than a
# limitation worked around.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-${TMPDIR:-/tmp}/baia-glass-backdrop}
BUILD="$OUT/build"
LIB="$BUILD/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here. Six of
# seven probes carried their own copy and went stale, silently, because no `make`
# target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

# --- the four render arms ----------------------------------------------------
#
# Links `PaneChrome` only. The arms read `PaneStatusBarMetrics.height` and
# `MaterialSet.dark.fillChrome` off the package at run time rather than
# transcribing them, so the arm that claims to reproduce the shipped footer
# cannot grade against numbers that have since moved.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so the probe compiles under the rules the code it
# mirrors ships under.
swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/backdroptest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/backdroptest.swift"

# --- the grid measurement ----------------------------------------------------
#
# This one needs libghostty itself: a real surface on a real PTY, because the
# question is what the shell is told, and a stand-in view has no PTY to tell.
# `GhosttyTerminal` comes out of SwiftPM's build products rather than being
# rebuilt from source, since it is a binary xcframework dependency and not a local
# package.
#
# The framework paths are derived from the Debug build products, so `make build`
# has to have run at least once. That is asserted rather than assumed: without it
# the swiftc line fails with a module-not-found that reads as a probe bug.
PRODUCTS="$ROOT/.build/Build/Products/Debug"
if [ ! -d "$PRODUCTS" ]; then
  echo "no build products at $PRODUCTS — run 'make build' first." >&2
  echo "The grid arm needs a real libghostty surface, which only the app build provides." >&2
  exit 1
fi

GHOSTTY_MODULE=$(find "$PRODUCTS" -name "GhosttyTerminal.swiftmodule" -maxdepth 3 2>/dev/null | head -1)
if [ -z "$GHOSTTY_MODULE" ]; then
  echo "GhosttyTerminal.swiftmodule not found under $PRODUCTS — run 'make build'." >&2
  exit 1
fi

XCFRAMEWORK=$(find "$ROOT/.build/SourcePackages/artifacts" -name "GhosttyKit.xcframework" -maxdepth 4 2>/dev/null | head -1)
if [ -z "$XCFRAMEWORK" ]; then
  echo "GhosttyKit.xcframework not found — run 'make build'." >&2
  exit 1
fi
# The macOS slice, which despite the `.xcframework` extension is a static archive
# beside a `Headers/` directory rather than a framework bundle. `-F` finds nothing
# in it: what the compiler needs is the clang module `libghostty` declared by
# `Headers/module.modulemap`, reached with `-Xcc -I`, and the archive linked
# directly. The first version of this line used `-F`/`-rpath` and failed with
# `missing required module 'libghostty'`, which reads as a missing dependency
# rather than as the wrong flag for the artifact's actual shape.
ARCH_DIR=$(find "$XCFRAMEWORK" -maxdepth 1 -type d -name "macos-*" | head -1)
if [ -z "$ARCH_DIR" ]; then
  echo "no macOS slice inside $XCFRAMEWORK" >&2
  exit 1
fi
GHOSTTY_HEADERS="$ARCH_DIR/Headers"
GHOSTTY_ARCHIVE="$ARCH_DIR/libghostty.a"

# The grid binary is built best-effort. It is the arm that needs the most of the
# toolchain (a binary xcframework, a spawned shell, a Metal device), and a
# link-line change upstream must not take the four capture arms down with it: the
# captures answer (A)-versus-(B) on optics and the grid arm answers whether (B) is
# affordable, and losing the second is a degraded run rather than a failed one.
GRID_BUILT=0
# Object files, not libraries. `make build` leaves each package as a single
# `<Name>.o` in the products directory and `PackageFrameworks/` empty, so `-l`
# finds nothing: the second failure of this line was `library 'GhosttyTerminal'
# not found` for exactly that reason. They are passed to the linker positionally
# instead. `GhosttyTheme` and `MSDisplayLink` are included because
# `GhosttyTerminal` references them, and `libghostty.a` last because it is what
# every symbol above ultimately resolves into.
if swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/gridtest" \
  -I "$PRODUCTS" \
  -Xcc -I -Xcc "$GHOSTTY_HEADERS" \
  "$HERE/gridtest.swift" \
  "$PRODUCTS/GhosttyTerminal.o" \
  "$PRODUCTS/GhosttyKit.o" \
  "$PRODUCTS/GhosttyTheme.o" \
  "$PRODUCTS/MSDisplayLink.o" \
  "$GHOSTTY_ARCHIVE" \
  > "$BUILD/gridtest-build.log" 2>&1
then
  GRID_BUILT=1
else
  echo "note: the grid arm did not build; its log is at $BUILD/gridtest-build.log" >&2
  echo "      the capture arms below still run." >&2
fi

# --- run ---------------------------------------------------------------------

echo "=== captures: four arms, the capsule pair, the sidebar, and the inactive pair ==="
"$BUILD/backdroptest" "$OUT"
echo

status=0
if [ "$GRID_BUILT" = "1" ]; then
  echo "=== the grid measurement for arm 3 ==="
  "$BUILD/gridtest" | tee "$OUT/grid-measurement.txt" || status=$?
else
  echo "=== the grid measurement for arm 3: SKIPPED (build failed) ==="
  echo "SKIPPED: see $BUILD/gridtest-build.log" > "$OUT/grid-measurement.txt"
  status=1
fi

echo
echo "captures and the grid numbers: $OUT"
echo "The verdict is in this probe's README.md; these files are what it cites."
exit $status
