#!/bin/bash
# Builds and runs the cluster-attention probe. Output goes to a scratch
# directory; it writes nothing into the repo, opens no window and takes no focus.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-cluster-attention-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here, for the
# reason `find-in-pane` learned by going stale: a probe carrying its own copy of
# the package graph breaks silently when an import is added, and no `make`
# target compiles a probe to notice.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# `PaneClusterView` and its superclass are compiled verbatim, so the pixels
# measured are the pixels the app draws. Neither reaches libghostty: the view
# imports AppKit, BaiaSettings and PaneChrome only, which is what makes this
# probe possible at all without a Metal device or a spawned shell.
compile() {
  local name=$1
  shift
  swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/clusterattentiontest-$name" \
    -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$HERE/main.swift" "$@" > "$OUT/build-$name.log" 2>&1 ||
    { cat "$OUT/build-$name.log" >&2; return 1; }
}

compile clean "$ROOT/Sources/PaneClusterView.swift" "$ROOT/Sources/PaneOverlayView.swift" "$ROOT/Sources/WindowCorner.swift"

# A damaged copy of the view for the `ink` control, mutated the way `pane-resize`
# does rather than by adding a seam to production: a flag the probe could set is
# a second way the shipped code can be wrong, and the damage belongs in the
# drawing under test.
#
# A no-op sed is a hard failure, for `pane-resize`'s reason: it means the line
# moved or was rewritten and the control below would fail for a reason that has
# nothing to do with the arm.
mkdir -p "$OUT/damaged"
sed 's/ink: theme.ink(on: under),/ink: theme.foreground,/' \
  "$ROOT/Sources/PaneClusterView.swift" > "$OUT/damaged/PaneClusterView.swift"
if cmp -s "$ROOT/Sources/PaneClusterView.swift" "$OUT/damaged/PaneClusterView.swift"; then
  echo "MUTATION CHANGED NOTHING: the glyph's ink line has moved or been rewritten in"
  echo "Sources/PaneClusterView.swift, so the ink control would fail for a reason that"
  echo "has nothing to do with the arm."
  exit 1
fi
compile damaged-ink "$OUT/damaged/PaneClusterView.swift" "$ROOT/Sources/PaneOverlayView.swift" "$ROOT/Sources/WindowCorner.swift"

# One arm per process: `levels` renders three views and a shared process would
# let one arm's cached placement stand in for another's.
#
# `levels` and `anchor` damage themselves through the `break` argument, which is
# legitimate where the damage is to the *fixture* rather than to the drawing
# (rendering every level as `asking`, widening one level's text). `ink` needs a
# damaged view, so it takes the mutated binary.
for arm in levels calm anchor; do
  "$OUT/clusterattentiontest-clean" "$arm"
  echo
  if "$OUT/clusterattentiontest-clean" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes against a damaged drawing, so it proves nothing"
    exit 1
  fi
  echo "(the $arm control failed, as it must)"
  echo
done

"$OUT/clusterattentiontest-clean" ink
echo
if "$OUT/clusterattentiontest-damaged-ink" ink; then
  echo "CONTROL DID NOT FAIL: the ink arm passes against a glyph drawn in theme.foreground,"
  echo "so it is not checking that the ink is the one bounded against the fill."
  exit 1
fi
echo "(the ink control failed, as it must)"
echo

echo "all four arms pass and all four controls fail"
