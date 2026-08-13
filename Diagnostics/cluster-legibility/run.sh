#!/bin/bash
# Builds and runs the cluster-legibility probe. Output goes to a scratch
# directory; it writes nothing into the repo.
#
#   ./run.sh
#
# **Safe from anywhere, including inside a baia pane.** This probe opens no
# window, takes no focus, launches nothing and quits nothing: every arm renders
# the capsule offscreen into a bitmap and reads the bytes back — the
# `cluster-wires` arrangement, graded with `pane-glass-legibility`'s contrast
# method. Nothing here ever reaches a compositor.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-cluster-legibility-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here, for
# the reason that file records: seven probes carried their own copies and six
# went stale, silently, because no `make` target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The shipped files are compiled verbatim, not sliced and not retyped, so the
# pixels this probe grades are the pixels the app draws — `cluster-wires`' own
# build line, including its note: `PaneClusterView` subclasses
# `PaneOverlayView`, which reaches `WindowCorner` and nothing else in
# `Sources/`.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship
# under.
#
# The offer arms add the sidebar's own files: `FilesSurface.swift` carries
# `InitOfferView`, `WorkspaceSurface.swift` its caption constant and the surface
# protocol, `SidebarRowMetrics.swift` the row metrics both the pill and the
# caption are measured from, and `SurfaceFill.swift` the tint vocabulary the
# glass backing resolves through. `GitWorkspace` joins the link line with them,
# because the file tree the surface draws is that package's type.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/legibility" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/legibility.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/PaneOverlayView.swift" "$ROOT/Sources/PaneClusterView.swift" \
  "$ROOT/Sources/FilesSurface.swift" "$ROOT/Sources/WorkspaceSurface.swift" \
  "$ROOT/Sources/SidebarRowMetrics.swift" "$ROOT/Sources/SurfaceFill.swift" \
  "$ROOT/Sources/RowFeedback.swift" "$ROOT/Sources/DividerGrabView.swift"

# One arm per process, each followed by its negative control: the graded ink
# set to the composited fill colour, which must fail the threshold. `set -e`
# makes the passing arms the test; the controls are inverted, so a control
# that stops failing fails the run just as loudly as an arm that stops
# passing — the same discipline `override-wires` runs under.
ARMS="resting focused dot offer-glass offer-flat"
COUNT=0
for arm in $ARMS; do
  "$OUT/legibility" "$arm"
  echo
  if "$OUT/legibility" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even with fill-coloured ink, so it grades nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail"
