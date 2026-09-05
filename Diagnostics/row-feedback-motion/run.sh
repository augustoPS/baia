#!/bin/bash
# Builds and runs the row-feedback-motion probe.
#
#   ./run.sh
#
# Headless: the probe opens no window, builds no view, launches nothing and
# quits nothing. It drives `RowFeedback`'s clock on the main run loop of a
# command-line process and reads back the fills and inks the rows view would
# have drawn. It is not in `guard-baia-alive.sh`'s `SAFE_PROBES` list, so run it
# from a shell outside a baia pane. Everything it writes goes to a scratch
# directory of its own that is removed on exit; nothing lands in the repo.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-row-feedback-motion.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The dependency edges live in `lib/build-packages.sh`, for the reason that file
# records. `RowFeedback` reaches `PaneChrome` for `PaneTheme` and `RGB` and
# nothing else in `Sources/`.
. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

# Two binaries from one grader. `motiontest` compiles the shipped file verbatim,
# so the clock graded is the clock the sidebar runs. `motiontest-defect`
# compiles a copy with the repair undone: the Reduce Motion answer routed back
# through `fade(_:to:over:)`, whose Reduce Motion arm snaps to the target inside
# the same call, which is the erased-outcome defect. Every arm must pass the
# first. Against the second only the arms that grade the repaired property may
# fail, so the controls break the production behaviour under test and nothing
# else; the two arms the defect never touched must keep passing there, which is
# what shows the mutant is the narrow one it claims to be. The copy is compared
# to the original so a source change that defeats the substitution fails here,
# loudly.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION.
build() {
  swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/$1" \
    -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$HERE/motiontest.swift" "$2"
}

build motiontest "$ROOT/Sources/RowFeedback.swift"

perl -pe 's/guard reducesMotion\(\) else \{/if true {/' \
  "$ROOT/Sources/RowFeedback.swift" > "$OUT/RowFeedback-defect.swift"
if cmp -s "$ROOT/Sources/RowFeedback.swift" "$OUT/RowFeedback-defect.swift"; then
  echo "the defect substitution matched nothing in Sources/RowFeedback.swift; the controls would grade the repair against itself"
  exit 1
fi
build motiontest-defect "$OUT/RowFeedback-defect.swift" 2>/dev/null

# `set -e` makes the passing arms the test. Every arm is then inverted against
# the mutant, so a control that stops failing fails the run as loudly as an arm
# that stops passing.
#
# `motion` and `reset` were briefly listed as unaffected. They were not: each had
# simply lost the half that discriminates. `motion` grades the animated path,
# which both builds share, so it needs its still-policy tail to say anything
# about the defect; `reset` grades silence after a cancellation, and under the
# defect there is no hold to cancel, so silence is free. Both now establish the
# positive case inside the arm, and both fail the mutant.
#
# `MUST_PASS` is kept, empty, because the split is the useful shape: an arm
# listed there asserts the mutant is not *wider* than R13, which is the check
# that catches a substitution grading something else. Nothing needs it today.
MUST_FAIL="still landed motion hover repeat toggle reset"
MUST_PASS=""

for arm in still landed motion hover repeat toggle reset; do
  "$OUT/motiontest" "$arm"
  echo
done

echo "=== against the defect-restored copy"
for arm in $MUST_FAIL; do
  if "$OUT/motiontest-defect" "$arm"; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes with the defect restored, so it proves nothing"
    exit 1
  fi
  echo "(defect: $arm failed, as it must)"
  echo
done

for arm in $MUST_PASS; do
  if ! "$OUT/motiontest-defect" "$arm"; then
    echo "CONTROL BROKE AN UNAFFECTED ARM: $arm fails with the defect restored, so the mutant is wider than R13"
    exit 1
  fi
  echo "(defect: $arm still passes, as it must)"
  echo
done

echo "all seven arms pass and all seven controls fail"
