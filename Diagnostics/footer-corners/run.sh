#!/bin/bash
# Builds and runs the footer-corners probe. Output goes to a scratch directory; it
# writes nothing into the repo.
set -euo pipefail

# Frozen as record on 2026-08-13, when `Sources/PaneStatusBarView.swift` was
# deleted. The `swiftc` line below compiles that file verbatim — that is the
# point of the arrangement, not an accident — so this probe cannot build and
# will never build again. It exits here, saying so, rather than dying twenty
# lines down on `no such file or directory` and reading like a broken probe
# instead of a retired one.
#
# The directory survives because three probes cite its method; see README.md
# for which and why. Nothing below this block has run since that date.
cat <<'FROZEN'
footer-corners is frozen as record and does not run.

It measured the footer (`Sources/PaneStatusBarView.swift`), which was deleted
on 2026-08-13. The file it compiled verbatim is gone, so there is nothing to
build. The directory is kept because `glass-backdrop`, `pane-glass-stacking`
and `override-wires` cite this probe's method; README.md carries the frozen
findings and the citation list.
FROZEN
exit 0

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-footer-corners-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The packages the probe needs, built straight from source rather than picked out
# of SwiftPM's incremental object directory, whose per-file objects carry
# duplicate type metadata and do not link on their own.
# The dependency edges live in `lib/build-packages.sh` rather than here. This
# probe carried its own copy and it went stale when `FileTreeExpansions` gave
# `PaneChrome` a `GitWorkspace` import, which no `make` target could notice
# because none of them compiles a probe.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The four shipped files are compiled verbatim, not sliced and not retyped, so
# the corners this probe measures are the corners the app draws. `PaneStatusBarView`
# and `PaneOverlayView` reach nothing outside these packages, `WindowCorner` and
# `SurfaceFill`, which is what makes that possible; if either ever grows a
# dependency on another file in `Sources/`, this line is where that shows up.
#
# `SurfaceFill.swift` joined the list when the design overrides were wired: it is
# where a dialled `DesignOverrides.Chrome.Material` becomes a glass tint, and
# `PaneStatusBarView.updateGlassTint()` calls it. It was added rather than worked
# around, because the comment above is the point of the arrangement — a new edge
# is supposed to show up here and be looked at, not to be routed around so the
# probe keeps compiling. It brings no new package edge: it links `BaiaSettings`
# and `PaneChrome`, both already here.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/cornertest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/cornertest.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/SurfaceFill.swift" \
  "$ROOT/Sources/PaneStatusBarView.swift" "$ROOT/Sources/PaneOverlayView.swift"

# One arm per process, each followed by its negative control. `set -e` makes the
# passing arms the test; the controls are inverted, so a control that stops
# failing fails the run just as loudly as an arm that stops passing.
#
# `fullscreen` is last because it is the only arm that takes over the display: it
# activates, opens a window and drives it into full screen and back, twice.
for arm in radius match concentric height clip capsule frame fullscreen; do
  "$OUT/cornertest" "$arm"
  echo
  if "$OUT/cornertest" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even when $arm is wrong, so it proves nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
done

echo "all eight arms pass and all eight controls fail"
