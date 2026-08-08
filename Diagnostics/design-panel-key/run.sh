#!/bin/bash
# Builds and runs the design-panel-key probe. Output goes to a scratch directory;
# it writes nothing into the repo.
#
#   ./run.sh
#
# **NOT safe from inside a baia pane, and deliberately not in the guard's
# `SAFE_PROBES` list.** This probe takes the keyboard. That is not a side effect
# to be engineered away: the question it answers is whether the design panel's
# `wantsKey` flag comes back down, and a flag about taking key cannot be measured
# without taking key. Measured rather than assumed — `makeKey()` on an
# `.accessory` app's nonactivating panel moves `NSApplication.isActive` false to
# true and takes key from the pane, while leaving the frontmost *application*
# unchanged at the Dock level. Focus returns when the process exits, so the cost
# is bounded to the two seconds of the run, but keystrokes during it land
# nowhere useful. `footer-corners` is denied for exactly this, and this probe
# would qualify no better. Run it from a second terminal, or from a pane you are
# not typing into. See README.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-design-panel-key-probe
mkdir -p "$OUT"
cd "$ROOT"

PANEL="$ROOT/Sources/DesignPanelController.swift"

# The one thing this probe cannot do is compile the class it is about.
# `DesignPanel` shares a file with `DesignPanelController`, which reaches
# `ConfigurationCenter` and from there the whole app target, so unlike
# `override-wires` and `footer-corners` there is nothing here to compile
# verbatim. `keytest.swift` retypes the four lines that decide the behaviour.
#
# Retyped code goes stale, silently and in the direction that matters: the probe
# keeps passing while the app stops doing what the probe says it does. So the
# four lines are grepped out of the shipped file before any arm runs, and a
# rename, a deletion or an inverted guard fails the run here rather than being
# measured against a copy nobody kept current.
#
# Anchored on the fixture rather than on exact whitespace, so reformatting does
# not fail the run while a behavioural change still does.
require() {
  if ! grep -qE "$1" "$PANEL"; then
    echo "STALE: Sources/DesignPanelController.swift no longer contains: $2"
    echo "       keytest.swift retypes DesignPanel and has drifted from it. Re-read both."
    exit 1
  fi
}
require 'var wantsKey = false'                    'the wantsKey flag'
require 'override var canBecomeKey: Bool \{ wantsKey \}' 'canBecomeKey answering wantsKey'
require 'override func resignKey\(\)'              'the resignKey override'
require 'override func orderOut\(_ sender: Any\?\)' 'the orderOut override'
# Both overrides have to actually lower the flag. An override that kept it up
# would pass the four greps above and be precisely the bug, so the two lowering
# sites are required by name, inside the body of the override that owns each.
#
# **Counting `wantsKey = false` does not work, and the first version of this
# check was wrong for exactly that reason.** The declaration is spelled
# `var wantsKey = false` and matches the same pattern, so stripping the lowering
# out of `resignKey()` left three matches (declaration, `orderOut`, hex field)
# and the count-based check passed while the bug was live. Found by doing it.
# `awk` reads each override's body instead.
require_lowering_in() {
  if ! awk "/override func $1/,/^        \}/" "$PANEL" | grep -q 'wantsKey = false'; then
    echo "STALE: $2 in Sources/DesignPanelController.swift no longer lowers wantsKey"
    echo "       That is the leak this probe exists to catch, in the shipped code."
    exit 1
  fi
}
require_lowering_in 'resignKey\(\)'              'the resignKey override'
require_lowering_in 'orderOut\(_ sender: Any\?\)' 'the orderOut override'
echo "shipped DesignPanel matches what keytest.swift retypes"
echo

# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so the panel compiles under the rules it ships
# under. No package is linked: this probe reaches nothing but AppKit.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/keytest" "$HERE/keytest.swift"

# One arm per process, each followed by its negative control. `set -e` makes the
# passing arms the test; the controls are inverted, so a control that stops
# failing fails the run just as loudly as an arm that stops passing. The same
# discipline `footer-corners` and `override-wires` run under, and it is what
# stops an arm that has quietly become a tautology from reading as evidence.
#
# A fresh process per arm because key status is process-global: an arm that left
# a panel key would decide the next arm's answer before it ran.
ARMS="resign-key order-out perform-close order-out-never-key reopen"
COUNT=0
for arm in $ARMS; do
  "$OUT/keytest" "$arm"
  echo
  if "$OUT/keytest" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even with the two overrides stripped,"
    echo "so it proves nothing about them"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
  COUNT=$((COUNT + 1))
done

echo "all $COUNT arms pass and all $COUNT controls fail"
