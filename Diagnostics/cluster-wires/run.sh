#!/bin/bash
# Builds and runs the cluster-wires probe. Output goes to a scratch directory;
# it writes nothing into the repo.
#
#   ./run.sh
#
# **Safe from anywhere, including inside a baia pane.** This probe opens no
# window, takes no focus, launches nothing and quits nothing: every arm renders
# the capsule offscreen into a bitmap and reads the bytes back. It is
# `override-wires` applied to `PaneClusterView`, and it qualifies for the
# guard's SAFE_PROBES on the same ground as that probe: nothing here ever
# reaches a compositor.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-cluster-wires-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here, for the
# reason that file records: seven probes carried their own copies and six went
# stale, silently, because no `make` target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The shipped files are compiled verbatim, not sliced and not retyped, so the
# pixels this probe measures are the pixels the app draws. `PaneClusterView`
# subclasses `PaneOverlayView`, which reaches `WindowCorner` and nothing else
# in `Sources/`. If either grows a dependency on another file, this line is
# where that shows up.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship
# under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/clustertest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/clustertest.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/PaneOverlayView.swift" "$ROOT/Sources/PaneClusterView.swift"

# One arm per process, each followed by its negative control. `set -e` makes
# the passing arms the test; the controls are inverted, so a control that stops
# failing fails the run just as loudly as an arm that stops passing — the same
# discipline `override-wires` runs under.
ARMS="nil-cluster opacity focus"
COUNT=0
for arm in $ARMS; do
  "$OUT/clustertest" "$arm"
  echo
  if "$OUT/clustertest" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even when $arm is wrong, so it proves nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail"
