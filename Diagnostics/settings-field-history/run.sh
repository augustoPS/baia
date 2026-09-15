#!/bin/bash
# Builds and runs the settings-field-history probe. Output goes to a scratch
# directory; it writes nothing into the repo.
#
#   ./run.sh
#
# **Opens no window on screen and takes no focus.** The probe creates one
# `NSWindow` it never orders front, drives its responder chain to start and end
# a field's editing session, and fires the stepper's action the way a click
# does. There is no `orderFront`, `makeKey`, `activate` or `pkill` in it; the
# activation policy is `.accessory`, as in `override-wires`. It is not yet on
# `guard-baia-alive.sh`'s `SAFE_PROBES`; that list is the record, and adding a
# member is the guard owner's decision, not this file's.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-settings-field-history-probe
LIB="$OUT/lib"
mkdir -p "$LIB" "$OUT/control"
cd "$ROOT"

# The revision that carried the bug, and the control build's source. The arms
# below that name the bug must fail against it; that is the red run, kept
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
  # controls under test are the controls the app ships. It reaches nothing
  # else in `Sources/`; if it grows a dependency on another file there, this
  # line is where that shows up.
  #
  # -default-isolation MainActor matches the app target's
  # SWIFT_DEFAULT_ACTOR_ISOLATION, so it compiles under the rules it ships under.
  swiftc -swift-version 6 -default-isolation MainActor -o "$1" \
    -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$HERE/fieldprobe.swift" "$2"
}

build_probe "$OUT/fieldprobe" "$ROOT/Sources/SettingsControls.swift"
git -C "$ROOT" show "$BUGGY_REVISION:Sources/SettingsControls.swift" > "$OUT/control/SettingsControls.swift"
build_probe "$OUT/fieldprobe-control" "$OUT/control/SettingsControls.swift"

# The arms that name the bug. Each must pass on the working tree and fail on
# the buggy revision, so a fix that quietly stops covering one of them fails
# the run as loudly as a regression. The `leave-untouched` pair is here
# because the buggy revision proposed a commit on every focus loss, typed or
# not; `number-stepper-replaces-typing` because it proposed the stepper's text
# a second time when focus left. `number-keystroke-backspace-then-history-undo`
# leaves the text as it was through the field editor and then undoes a write on
# the app's own manager; it fails on the baseline for the same frozen-text
# reason. `undo-wiring` is a report arm, always green, not listed here; run
# the built binary with it by hand.
BUG_ARMS="number-mirror-while-focused number-undo-then-leave number-leave-untouched number-stepper-replaces-typing number-keystroke-backspace-then-history-undo text-mirror-while-focused text-undo-then-leave text-leave-untouched"

# The arms that guard what the fix must not change: typed text still commits
# once and in the owner's locale, still wins over ⌘Z made mid-edit, and
# refused text still keeps its reason. These pass on both builds; they are
# regression guards rather than controls, and the run says so.
GUARD_ARMS="number-typed-commit number-locale-typed number-typed-survives-undo number-invalid-kept number-out-of-range number-whole-levels text-typed-commit text-typed-survives-undo text-invalid-kept"

# The locale arm runs a second time under a locale whose decimal separator is
# a comma, through Foundation's argument domain. The arm prints the separator
# it saw; if the override did not take, the second run proved nothing about
# the comma and the run says so rather than passing on the default locale
# twice.
SECOND_LOCALE=de_DE

echo "== working tree =="
for arm in $BUG_ARMS $GUARD_ARMS; do
  "$OUT/fieldprobe" "$arm"
done
echo "-- number-locale-typed under $SECOND_LOCALE --"
"$OUT/fieldprobe" number-locale-typed -AppleLocale "$SECOND_LOCALE" | tee "$OUT/locale.log"
grep -q "decimal separator ','" "$OUT/locale.log" || {
  echo "LOCALE OVERRIDE DID NOT TAKE: -AppleLocale $SECOND_LOCALE left the decimal separator unchanged, so the comma was not exercised"
  exit 1
}
echo

echo "== control: $BUGGY_REVISION =="
for arm in $BUG_ARMS; do
  if "$OUT/fieldprobe-control" "$arm"; then
    echo "CONTROL DID NOT FAIL: $arm passes on the buggy revision, so it is not grading the bug"
    exit 1
  fi
  echo "($arm failed on the buggy revision, as it must)"
done
for arm in $GUARD_ARMS; do
  "$OUT/fieldprobe-control" "$arm"
done
echo

echo "all 17 arms pass on the working tree, the locale arm twice; 8 bug arms fail and 9 guard arms pass on $BUGGY_REVISION"
