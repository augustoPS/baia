#!/bin/bash
# Builds and runs the footer-status-store probe. Output goes to a scratch
# directory; it writes nothing into the repo.
#
#   ./run.sh
#
# **Safe from anywhere, including inside a baia pane.** This probe opens no
# window, takes no focus, launches nothing and quits nothing: every arm renders
# the shipped footer offscreen through `cacheDisplay(in:to:)` and reads the flags
# and layers back — the `cluster-notice` arrangement. Nothing here ever reaches a
# compositor.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-footer-status-store-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh` rather than here, for the
# reason that file records: seven probes carried their own copies and six went
# stale, silently, because no `make` target compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The shipped `PaneStatusBarView` is compiled verbatim, not sliced and not
# retyped, so the `didSet` this probe grades is the one the app runs. It reaches
# `WindowCorner` and nothing else in `Sources/` — `cluster-notice`'s own note
# about the footer family.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so it compiles under the rules it ships under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/store" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/store.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/PaneStatusBarView.swift"

# One arm per process, each followed by its negative control, which must fail.
# `set -e` makes the passing arms the test; the controls are inverted, so a
# control that stops failing fails the run just as loudly as an arm that stops
# passing — `cluster-notice`'s loop, and `override-wires`' discipline behind it.
ARMS="gated pulse strip handed"
COUNT=0
for arm in $ARMS; do
  "$OUT/store" "$arm"
  if "$OUT/store" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes under its control, so it grades nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail"
