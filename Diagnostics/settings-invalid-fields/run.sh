#!/bin/bash
# Builds and runs the settings-invalid-fields fixtures. Output goes to a
# scratch directory; it writes nothing into the repo.
#
#   ./run.sh
#
# Two fixtures. `bannertest.swift` instantiates the shipped
# `SettingsRecoveryBanner` and never installs it in a window. `retypetest.swift`
# compiles the shipped `SettingsControls.swift` verbatim and drives one text,
# number or colour control in a window that is never ordered front, the
# `settings-field-history` harness.
#
# **Opens no window on screen and takes no focus.** There is no `orderFront`,
# `makeKey`, `activate` or `pkill` in either; the activation policy is
# `.accessory`, as in `override-wires`. It is not on `guard-baia-alive.sh`'s
# `SAFE_PROBES`; that list is the record, and adding a member is the guard
# owner's decision, not this file's.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-settings-invalid-fields-probe
LIB="$OUT/lib"
mkdir -p "$LIB" "$OUT/control"
cd "$ROOT"

# The revision whose banner ignored decoder `invalidKeys`, and whose controls
# proposed a commit on every focus loss. Bug arms must fail against it; that
# is the red run, kept next to the green one. Pinned rather than `HEAD~n` so a
# later commit cannot move the control onto a tree where the arms pass.
BUGGY_REVISION=10dc9bafd86c6a63ff211b4b1d3fef3534b5f2dd

# Dependency edges live in `lib/build-packages.sh`, for the reason that file
# records. The banner needs `BaiaSettings` alone; `SettingsControls.swift`
# imports `BaiaSettings` and `PaneChrome`, and `PaneChrome` links
# `GitWorkspace`.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

# The banner class lives below this mark in SettingsWindowController.swift.
# Extracting it is what lets this fixture compile the shipped view without
# ConfigurationCenter, SettingsPages, or a window.
extract_banner() {
  local src=$1 dest=$2
  {
    printf '%s\n' 'import AppKit' 'import BaiaSettings' ''
    awk '/^\/\/ MARK: - Recovery banner/,0' "$src"
  } > "$dest"
  grep -q 'final class SettingsRecoveryBanner' "$dest" || {
    echo "extract_banner: SettingsRecoveryBanner missing from $src" >&2
    return 1
  }
}

build_probe() {
  # build_probe <output-binary> <SettingsRecoveryBanner.swift>
  swiftc -swift-version 6 -parse-as-library -default-isolation MainActor -o "$1" \
    -I "$LIB" -L "$LIB" -lBaiaSettings \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$HERE/bannertest.swift" "$2"
}

build_retype() {
  # build_retype <output-binary> <SettingsControls.swift>
  #
  # The shipped file is compiled verbatim, not sliced and not retyped, so the
  # controls under test are the controls the app ships. -default-isolation
  # MainActor matches the app target's SWIFT_DEFAULT_ACTOR_ISOLATION.
  swiftc -swift-version 6 -default-isolation MainActor -o "$1" \
    -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$HERE/retypetest.swift" "$2"
}

extract_banner "$ROOT/Sources/SettingsWindowController.swift" "$OUT/banner.swift"
build_probe "$OUT/bannertest" "$OUT/banner.swift"
build_retype "$OUT/retypetest" "$ROOT/Sources/SettingsControls.swift"

git -C "$ROOT" show "$BUGGY_REVISION:Sources/SettingsWindowController.swift" \
  > "$OUT/control/SettingsWindowController.swift"
extract_banner "$OUT/control/SettingsWindowController.swift" "$OUT/control/banner.swift"
build_probe "$OUT/bannertest-control" "$OUT/control/banner.swift"
git -C "$ROOT" show "$BUGGY_REVISION:Sources/SettingsControls.swift" \
  > "$OUT/control/SettingsControls.swift"
build_retype "$OUT/retypetest-control" "$OUT/control/SettingsControls.swift"

# The banner arms that name the bug. Each must pass on the working tree and
# fail on the revision whose banner ignored invalidKeys.
BUG_ARMS="discovery clamp-wording correction sibling-write"

# Decoder, malformed-file, write-failure and retry behaviour the warning
# must not disturb. These pass on both builds.
GUARD_ARMS="sibling-applied clean-hides malformed-shows write-failure history-retry"

# The retype arms that name the stale-error bug: refused text, then the file's
# own value typed back, must clear the reason and propose nothing. The buggy
# revision cleared it by proposing a duplicate write, so each arm grades both
# the error line and the proposal list and fails there on the second.
RETYPE_BUG_ARMS="text-retype-mirror-clears number-retype-mirror-clears colour-retype-mirror-clears"

# What the retype path must not change: focus through untouched refused text
# keeps it and its reason, and a value typed over refused text after ⌘Z moved
# the file is still a proposal. These pass on both builds.
RETYPE_GUARD_ARMS="number-leave-refused-untouched number-retype-old-value-after-undo-commits"

echo "== working tree =="
for arm in $BUG_ARMS $GUARD_ARMS; do
  "$OUT/bannertest" "$arm"
done
for arm in $RETYPE_BUG_ARMS $RETYPE_GUARD_ARMS; do
  "$OUT/retypetest" "$arm"
done
echo

echo "== control: $BUGGY_REVISION =="
for arm in $BUG_ARMS; do
  if "$OUT/bannertest-control" "$arm"; then
    echo "CONTROL DID NOT FAIL: $arm passes on the buggy revision, so it is not grading the bug"
    exit 1
  fi
  echo "($arm failed on the buggy revision, as it must)"
done
for arm in $GUARD_ARMS; do
  "$OUT/bannertest-control" "$arm"
done
for arm in $RETYPE_BUG_ARMS; do
  if "$OUT/retypetest-control" "$arm"; then
    echo "CONTROL DID NOT FAIL: $arm passes on the buggy revision, so it is not grading the bug"
    exit 1
  fi
  echo "($arm failed on the buggy revision, as it must)"
done
for arm in $RETYPE_GUARD_ARMS; do
  "$OUT/retypetest-control" "$arm"
done
echo

echo "all 14 arms pass on the working tree; 7 bug arms fail and 7 guard arms pass on $BUGGY_REVISION"
