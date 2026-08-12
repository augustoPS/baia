#!/bin/bash
# Builds and runs the cluster-card-key probe. Output goes to a scratch
# directory; it writes nothing into the repo.
#
#   ./run.sh
#
# **NOT safe from inside a baia pane, and deliberately not in the guard's
# `SAFE_PROBES` list.** This probe takes the keyboard, on purpose and
# repeatedly: its subject is the cluster cards' key discipline — key taken on
# show, returned on every dismissal path — and a probe that avoided taking key
# would be measuring nothing, the same argument `design-panel-key`'s run.sh
# makes for itself. The first-mouse arm additionally posts a real CGEvent
# click (at a point it first verifies belongs to its own window), which needs
# Accessibility permission for whatever runs this — the same grant
# `lib/click.swift` already relies on. Run it from a second terminal, or from
# a pane you are not typing into. See README.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-cluster-card-key-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

PALETTE="$ROOT/Sources/CommandPaletteController.swift"

# `ClusterCardController` is compiled verbatim below — unlike `DesignPanel` it
# shares no file with the app target's reach. The one class this probe retypes
# is `PalettePanel`: two overrides, in the palette controller's file, which
# reaches the whole app target. Retyped code goes stale in the direction that
# matters, so the two lines are grepped out of the shipped file before any arm
# runs, inside the class's own body — the discipline `design-panel-key`
# established, including the lesson that a bare count is not a check.
require_in_palette_panel() {
  if ! awk '/^final class PalettePanel: NSPanel \{/,/^\}/' "$PALETTE" | grep -qE "$1"; then
    echo "STALE: PalettePanel in Sources/CommandPaletteController.swift no longer contains: $2"
    echo "       cardkeytest.swift retypes PalettePanel and has drifted from it. Re-read both."
    exit 1
  fi
}
require_in_palette_panel 'override var canBecomeKey: Bool \{ true \}'   'canBecomeKey answering true'
require_in_palette_panel 'override var canBecomeMain: Bool \{ false \}' 'canBecomeMain answering false'
echo "shipped PalettePanel matches what cardkeytest.swift retypes"
echo

# The dependency edges live in `lib/build-packages.sh` rather than here, for
# the reason that file records.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

# The controller and the capsule are compiled verbatim, so what the arms
# measure is the shipped key discipline and the shipped `acceptsFirstMouse`,
# not a copy. `PaneClusterView` subclasses `PaneOverlayView`, which reaches
# `WindowCorner` and nothing else in `Sources/`.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship
# under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/cardkeytest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/cardkeytest.swift" "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/PaneOverlayView.swift" "$ROOT/Sources/PaneClusterView.swift" \
  "$ROOT/Sources/ClusterCardController.swift"

# One arm per process, each followed by its negative control, the same
# discipline every probe here runs under: `set -e` makes the passing arms the
# test, and the inverted controls make a control that stops failing fail the
# run just as loudly.
#
# A fresh process per arm because key status is process-global. The five card
# arms' `break` damages the retyped panel (it refuses key, so every arm's
# took-key precondition fails); `first-mouse break` instead swaps the capsule
# for a view without the `acceptsFirstMouse` override, which is what proves
# the real-click mechanism actually consults it.
ARMS="show esc click-outside switch dismiss first-mouse"
COUNT=0
for arm in $ARMS; do
  "$OUT/cardkeytest" "$arm"
  echo
  if "$OUT/cardkeytest" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even when $arm is wrong, so it proves nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail"
