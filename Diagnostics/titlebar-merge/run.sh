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

# --- the grid measurement for arm 5 -----------------------------------------
#
# The second binary, and it needs libghostty itself: a real surface on a real
# PTY, because arm 5's question is what the SHELL is told and an `NSColor`
# stand-in has no PTY to tell. This is the follow-up the README's "what is not
# answered" names, built on `glass-backdrop/gridtest.swift`'s pattern rather than
# re-derived.
#
# `GhosttyTerminal` comes out of SwiftPM's build products rather than being
# rebuilt from source, since it is a binary xcframework dependency and not a local
# package. The framework paths are derived from the Debug build products, so
# `make build` has to have run at least once. That is asserted rather than
# assumed: without it the swiftc line fails with a module-not-found that reads as
# a probe bug.
PRODUCTS="$ROOT/.build/Build/Products/Debug"
GRID_BUILT=0
GRID_SKIP_REASON=""

if [ ! -d "$PRODUCTS" ]; then
  GRID_SKIP_REASON="no build products at $PRODUCTS — run 'make build' first"
else
  XCFRAMEWORK=$(find "$ROOT/.build/SourcePackages/artifacts" -name "GhosttyKit.xcframework" -maxdepth 4 2>/dev/null | head -1)
  if [ -z "$XCFRAMEWORK" ]; then
    GRID_SKIP_REASON="GhosttyKit.xcframework not found — run 'make build'"
  else
    # The macOS slice, which despite the `.xcframework` extension is a static
    # archive beside a `Headers/` directory rather than a framework bundle. `-F`
    # finds nothing in it: what the compiler needs is the clang module
    # `libghostty` declared by `Headers/module.modulemap`, reached with
    # `-Xcc -I`, and the archive linked directly. `glass-backdrop`'s run.sh
    # records the run where `-F`/`-rpath` failed with `missing required module
    # 'libghostty'`, which reads as a missing dependency rather than as the wrong
    # flag for the artifact's actual shape.
    ARCH_DIR=$(find "$XCFRAMEWORK" -maxdepth 1 -type d -name "macos-*" | head -1)
    if [ -z "$ARCH_DIR" ]; then
      GRID_SKIP_REASON="no macOS slice inside $XCFRAMEWORK"
    else
      # Object files, not libraries. `make build` leaves each package as a single
      # `<Name>.o` in the products directory and `PackageFrameworks/` empty, so
      # `-l` finds nothing. They are passed to the linker positionally instead.
      # `GhosttyTheme` and `MSDisplayLink` are included because `GhosttyTerminal`
      # references them, and `libghostty.a` last because it is what every symbol
      # above ultimately resolves into.
      #
      # `WorkspaceLayout` is built from source into `$LIB` above and linked with
      # `-l`, for `SidebarGeometry.default.width`: the grid arm reads the column
      # width off the package at run time exactly as the capture arms do, so it
      # cannot grade against a number that has moved.
      if swiftc -swift-version 6 -default-isolation MainActor -o "$BUILD/gridtest" \
        -I "$PRODUCTS" -I "$LIB" -L "$LIB" -lPaneControl -lWorkspaceLayout \
        -Xlinker -rpath -Xlinker "$LIB" \
        -Xcc -I -Xcc "$ARCH_DIR/Headers" \
        "$HERE/gridtest.swift" \
        "$PRODUCTS/GhosttyTerminal.o" \
        "$PRODUCTS/GhosttyKit.o" \
        "$PRODUCTS/GhosttyTheme.o" \
        "$PRODUCTS/MSDisplayLink.o" \
        "$ARCH_DIR/libghostty.a" \
        > "$BUILD/gridtest-build.log" 2>&1
      then
        GRID_BUILT=1
      else
        GRID_SKIP_REASON="the grid arm did not build; its log is at $BUILD/gridtest-build.log"
      fi
    fi
  fi
fi

# Built best-effort, on `glass-backdrop`'s precedent. The grid arm needs the most
# of the toolchain (a binary xcframework, a spawned shell, a Metal device), and a
# link-line change upstream must not take the six capture arms down with it: the
# captures answer which arrangement merges, and the grid arm answers whether route
# A is affordable. Losing the second is a degraded run rather than a failed one.
if [ "$GRID_BUILT" = "0" ]; then
  echo "note: $GRID_SKIP_REASON" >&2
  echo "      the capture arms below still run." >&2
fi

echo "=== seven arms: shipped two planes, container merge, one full-size plane, flat"
echo "    control, route A (split rect), route D (band drawn by the column), and the"
echo "    VERTICAL join arm 7 reads across ==="
"$BUILD/mergetest" "$OUT" | tee "$OUT/measurement.txt"
status=${PIPESTATUS[0]}

echo
if [ "$GRID_BUILT" = "1" ]; then
  echo "=== the grid measurement for arm 5: route A on a real PTY ==="
  if "$BUILD/gridtest" | tee "$OUT/grid-measurement.txt"; then
    :
  else
    grid_status=${PIPESTATUS[0]}
    [ "$status" = "0" ] && status=$grid_status
  fi
else
  echo "=== the grid measurement for arm 5: SKIPPED ==="
  echo "SKIPPED: $GRID_SKIP_REASON" > "$OUT/grid-measurement.txt"
  echo "$GRID_SKIP_REASON"
  [ "$status" = "0" ] && status=1
fi

echo
echo "captures, the strip numbers and the grid numbers: $OUT"
echo "The verdict is in this probe's README.md; these files are what it cites."
echo
echo "Every arm asserts the controlled backdrop was behind it before its number is"
echo "published; a displaced backdrop exits non-zero naming the arm. The"
echo "backdrop-check-<arm>.png strips are that assertion's evidence."
exit "$status"
