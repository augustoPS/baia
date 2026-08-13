#!/bin/bash
# Builds and runs the cluster-notice probe. Output goes to a scratch directory;
# it writes nothing into the repo.
#
#   ./run.sh
#
# **Safe from anywhere, including inside a baia pane.** This probe opens no
# window, takes no focus, launches nothing and quits nothing: every arm renders
# the capsule offscreen into a bitmap and reads the bytes back — the
# `cluster-wires` arrangement that `cluster-legibility` also runs under. Nothing
# here ever reaches a compositor.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-cluster-notice-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here, for the
# reason that file records: seven probes carried their own copies and six went
# stale, silently, because no `make` target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The shipped files are compiled verbatim, not sliced and not retyped, so the
# pixels this probe grades are the pixels the app draws — `cluster-wires`' own
# build line, including its note: `PaneClusterView` subclasses `PaneOverlayView`,
# which reaches `WindowCorner` and nothing else in `Sources/`.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship under.
#
# Three files where `cluster-legibility` links ten: this probe grades the capsule
# alone and never touches the sidebar's offer pill, so `FilesSurface.swift` and
# its four companions are not on the line.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/notice" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/notice.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/PaneOverlayView.swift" "$ROOT/Sources/PaneClusterView.swift"

# One arm per process, each followed by its negative control, which must fail.
# `set -e` makes the passing arms the test; the controls are inverted, so a
# control that stops failing fails the run just as loudly as an arm that stops
# passing — `cluster-legibility`'s loop, and `override-wires`' discipline behind
# it.
ARMS="draws bare-shell legible operation fits vanish"
COUNT=0
for arm in $ARMS; do
  "$OUT/notice" "$arm"
  echo
  if "$OUT/notice" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes under its control, so it grades nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail"
