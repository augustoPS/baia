#!/bin/bash
# Builds and runs the preview-dials probe. Output goes to a scratch directory;
# it writes nothing into the repo.
#
#   ./run.sh
#
# **Safe from anywhere, including inside a baia pane.** This probe opens no
# window, takes no focus, launches nothing and quits nothing: every arm renders
# the settings preview's chrome offscreen into a bitmap and reads the bytes
# back — `cluster-legibility`'s arrangement, which is `cluster-wires`'. Nothing
# here ever reaches a compositor.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-preview-dials-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here, for the
# reason that file records: seven probes carried their own copies and six went
# stale, silently, because no `make` target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The shipped files compiled verbatim, `cluster-legibility`'s own build line:
# `PaneClusterView` and `PaneEdgeFrameView` are the two views the settings
# preview installs, and `PaneOverlayView` (which carries `PaneEdgeFrameView`)
# reaches `WindowCorner` and nothing else in `Sources/`.
#
# `SettingsPreviewPane.swift` itself is deliberately NOT on this line. It
# imports `GhosttyTerminal` for its sample surface, which needs Metal and a
# window; the probe rebuilds that file's two-view stack instead, and
# `renderPreviewPane` carries the note that a divergence between the two is a
# probe measuring a preview that does not exist.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship
# under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/dials" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/dials.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/PaneOverlayView.swift" "$ROOT/Sources/PaneClusterView.swift"

# One arm per process, each followed by its negative control. The controls here
# render both halves at the *same* dial value, so an arm's "something changed"
# assertions must fail: a control that still reports change means the two
# renders differ for a reason that is not the dial. `set -e` makes the passing
# arms the test; the controls are inverted, so a control that stops failing
# fails the run as loudly as an arm that stops passing.
# `fixture` is run without a control and deliberately so: it turns no dial, so
# there is no value to hold still and `break` would be the identical run. It is
# the arms' precondition rather than a measurement — it asserts the sample
# statuses still carry the dot and the segments the dials are read off — and its
# own failure mode is covered by the assertions being about the fixture rather
# than about a render.
"$OUT/dials" fixture
echo

ARMS="focus-accent attention-accent alert-behavior attention-style capsule-alone"
COUNT=0
for arm in $ARMS; do
  "$OUT/dials" "$arm"
  echo
  if "$OUT/dials" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm reports change with the dial held still, so it measures noise"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail (plus the fixture precondition)"
