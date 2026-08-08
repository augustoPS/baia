#!/bin/bash
# Builds and runs the override-wires probe. Output goes to a scratch directory; it
# writes nothing into the repo.
#
#   ./run.sh
#
# **Safe from anywhere, including inside a baia pane.** This probe opens no
# window, takes no focus, launches nothing and quits nothing: every arm renders a
# view offscreen into a bitmap and reads the bytes back. It is in the same class
# as `theme-catalog` and `app-icon` on that count, and unlike `glass-backdrop` and
# `footer-corners` it never needs a compositor, because its question is what this
# app's own drawing code puts down rather than what glass samples.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-override-wires-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here, for the
# reason that file records: seven probes carried their own copies and six went
# stale, silently, because no `make` target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The shipped files are compiled verbatim, not sliced and not retyped, so the
# pixels this probe measures are the pixels the app draws. This is the same set
# `footer-corners` compiles, and for the same reason: `PaneStatusBarView` and
# `PaneOverlayView` reach nothing outside these packages, `WindowCorner` and
# `SurfaceFill`. If either grows a dependency on another file in `Sources/`, this
# line is where that shows up.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/wiretest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/wiretest.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/SurfaceFill.swift" \
  "$ROOT/Sources/PaneStatusBarView.swift" "$ROOT/Sources/PaneOverlayView.swift"

# One arm per process, each followed by its negative control. `set -e` makes the
# passing arms the test; the controls are inverted, so a control that stops
# failing fails the run just as loudly as an arm that stops passing. The same
# discipline `footer-corners` runs under, and it is what stops an arm that has
# quietly become a tautology from reading as evidence.
ARMS="lift-nil lift-ring lift-highlight lift-enabled rim busy-dot bar-lift surface-fill"
COUNT=0
for arm in $ARMS; do
  "$OUT/wiretest" "$arm"
  echo
  if "$OUT/wiretest" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even when $arm is wrong, so it proves nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail"
