#!/bin/bash
# Builds and runs the settings-colour-history probe. Output goes to a scratch
# directory; it writes nothing into the repo.
#
#   ./run.sh
#
# **Opens no window on screen and takes no focus.** The probe creates one
# `NSWindow` it never orders front, drives its responder chain to start and end
# the hex field's editing session, and fires the colour well's action the way
# the Colors panel does. There is no `orderFront`, `makeKey`, `activate` or
# `pkill` in it; the activation policy is `.accessory`, as in `override-wires`.
# It is not yet on `guard-baia-alive.sh`'s `SAFE_PROBES`; that list is the
# record, and adding a member is the guard owner's decision, not this file's.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-settings-colour-history-probe
LIB="$OUT/lib"
mkdir -p "$LIB" "$OUT/control"
cd "$ROOT"

# The revision that carried the bug, and the control build's source. The four
# arms below that name the bug must fail against it; that is the red run, kept
# next to the green one. Pinned rather than `HEAD~n` so a later commit cannot
# move the control onto a tree where the arms pass.
BUGGY_REVISION=10dc9bafd86c6a63ff211b4b1d3fef3534b5f2dd

# Dependency edges live in `lib/build-packages.sh`, for the reason that file
# records. `SettingsControls.swift` imports `BaiaSettings` and `PaneChrome`;
# `PaneChrome` links `GitWorkspace`.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

build_probe() {
  # build_probe <output-binary> <SettingsControls.swift>
  #
  # The shipped file is compiled verbatim, not sliced and not retyped, so the
  # control under test is the control the app ships. It reaches nothing else
  # in `Sources/`; if it grows a dependency on another file there, this line
  # is where that shows up.
  #
  # -default-isolation MainActor matches the app target's
  # SWIFT_DEFAULT_ACTOR_ISOLATION, so it compiles under the rules it ships under.
  swiftc -swift-version 6 -default-isolation MainActor -o "$1" \
    -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$HERE/historyprobe.swift" "$2"
}

build_probe "$OUT/historyprobe" "$ROOT/Sources/SettingsControls.swift"
git -C "$ROOT" show "$BUGGY_REVISION:Sources/SettingsControls.swift" > "$OUT/control/SettingsControls.swift"
build_probe "$OUT/historyprobe-control" "$OUT/control/SettingsControls.swift"

# The arms that name the bug. Each must pass on the working tree and fail on
# the buggy revision, so a fix that quietly stops covering one of them fails
# the run as loudly as a regression. `leave-untouched` is here because the
# buggy revision proposed a commit on every focus loss, typed or not.
# `keystroke-backspace-then-panel` and `invalid-then-panel-consistent` grade
# the two follow-ups of the independent review (D1, D2); both fail on the
# baseline.
BUG_ARMS="mirror-while-focused leave-without-typing undo-redo-then-leave leave-untouched keystroke-backspace-then-panel invalid-then-panel-consistent"

# The arms that guard what the fix must not change: typed text still commits
# once, still wins over a panel pick made mid-edit, and invalid text still
# keeps its reason. These pass on both builds; they are regression guards
# rather than controls, and the run says so.
GUARD_ARMS="typed-commit typed-survives-panel invalid-kept"

echo "== working tree =="
for arm in $BUG_ARMS $GUARD_ARMS; do
  "$OUT/historyprobe" "$arm"
done
echo

echo "== control: $BUGGY_REVISION =="
for arm in $BUG_ARMS; do
  if "$OUT/historyprobe-control" "$arm"; then
    echo "CONTROL DID NOT FAIL: $arm passes on the buggy revision, so it is not grading the bug"
    exit 1
  fi
  echo "($arm failed on the buggy revision, as it must)"
done
for arm in $GUARD_ARMS; do
  "$OUT/historyprobe-control" "$arm"
done
echo

echo "all 9 arms pass on the working tree; 6 bug arms fail and 3 guard arms pass on $BUGGY_REVISION"
