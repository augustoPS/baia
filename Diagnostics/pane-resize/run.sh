#!/bin/bash
# Builds and runs the pane-resize probe. Output goes to a scratch directory; the
# only thing this writes into the repo is nothing at all.
#
# One case per process: a contaminated event queue produced a false result during
# the investigation that found this bug, and the cheapest defence is a fresh
# process per case.
#
# Exits non-zero if any arm fails or if any negative control passes.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-pane-resize-probe
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

# `PaneSplitController` and `PaneSplitView` are sliced out of the shipped file
# rather than retyped here, so the probe cannot pass against a copy that has
# drifted from what the app builds.
awk '/^\/\/\/ One split node:/{f=1} f' Sources/PaneTreeController.swift > "$OUT/panesplit_extracted.body"
{ printf 'import AppKit\nimport PaneChrome\nimport WorkspaceLayout\n\n'; cat "$OUT/panesplit_extracted.body"; } \
  > "$OUT/panesplit_extracted.swift"
grep -q 'final class PaneSplitController' "$OUT/panesplit_extracted.swift"
grep -q 'final class PaneSplitView' "$OUT/panesplit_extracted.swift"
echo "extracted $(grep -c '' "$OUT/panesplit_extracted.swift") lines from Sources/PaneTreeController.swift"

# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so the extracted source compiles under the rules
# it ships under.
#
# Warnings are kept out of the transcript because a damaged copy leaves bindings
# unused and would bury the arms in noise, but the log is printed whenever the
# build actually fails.
# The third argument names the lib directory to link against, and defaults to
# the clean one; the `reachable` control links a damaged `WorkspaceLayout`.
compile() {
  local log="$OUT/build-$1.log"
  local lib=${3:-$LIB}
  if ! swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/dragtest-$1" \
    -I "$lib" -L "$lib" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
    -Xlinker -rpath -Xlinker "$lib" \
    "$HERE/dragtest.swift" "$2" > "$log" 2>&1
  then
    cat "$log" >&2
    return 1
  fi
}

compile clean "$OUT/panesplit_extracted.swift"

# A negative control: the same slice of the shipped file with one line of the
# write-back path damaged, so an arm that cannot fail is caught being unable to.
#
# The damage lands in `recordDrag` and `SplitSeat.reachablePosition` themselves,
# not in something they call. The footer-corners probe was written the other way round
# once, verifying a geometry helper while the code consuming it was covered by
# nothing, and its controls still failed, which is exactly what made it look
# sound.
#
# A mutation that changes nothing is a control that passes for a reason that has
# nothing to do with the arm, so a no-op sed is a hard failure here: it means the
# targeted line moved or was rewritten in Sources/PaneTreeController.swift and
# this file needs updating with it.
mutate() {
  local name=$1
  shift
  cp "$OUT/panesplit_extracted.swift" "$OUT/damaged-$name.swift"
  local script
  for script in "$@"; do
    sed -i '' "$script" "$OUT/damaged-$name.swift"
  done
  if cmp -s "$OUT/panesplit_extracted.swift" "$OUT/damaged-$name.swift"; then
    echo "MUTATION '$name' CHANGED NOTHING: the line it targets has moved or been"
    echo "rewritten in Sources/PaneTreeController.swift, so the control below would"
    echo "fail for a reason that has nothing to do with the arm."
    exit 1
  fi
  compile "$name" "$OUT/damaged-$name.swift"
}

# The drag is measured, clamped and applied, and simply never reported. The
# divider stays where the mouse left it and the tree never hears, which is the
# same bug one relaunch later.
mutate notify 's/^        onRatioChange?(path, fraction)$/        _ = path/'

# The original bug verbatim: the drag is reported, but the controller keeps
# enforcing the ratio it was constructed with, so the layout pass the drag itself
# triggers puts the divider back.
mutate pin 's/^        ratio = fraction$/        _ = fraction/'

# The click test written against the stored ratio instead of against where the
# gesture started, which is how a bare mouse-down used to overwrite an
# arrangement wherever the minimum held the divider off its stored ratio.
mutate moved 's/^        guard let start, abs(current - start) > 0.5 else { return }$/        _ = start; guard abs(current - thickness \* ratio) > 0.5 else { return }/'

# The layout-time enforcement removed, which is what the pre-fix arms are about:
# with nothing re-pinning the divider on every pass, the nested dividers move,
# nothing snaps back to half, and the built-in control stops reproducing the bug
# it exists to reproduce.
mutate enforce '/super.viewDidLayout()/{n;s/applyRatio()/_ = ratio/;}'

# The position clamp removed, so a stored ratio the minimum refuses is chased on
# every layout pass. This is the crash class, and the control is expected to die
# rather than to print a wrong number.
#
# **The refusal bound has to go with it, and that is not belt-and-braces: it is
# the second half of one control** (2026-08-14). The clamp alone stopped being
# fatal when `refusals` shipped on 2026-07-31, and for a year of probe runs
# nobody noticed, because a control that quietly stops killing looks exactly
# like a control that passes. Measured that day, both variants built from this
# same extracted slice: clamp removed alone exits 0 and prints every arm green,
# with the divider still reported at 96.0 in all six cases; clamp and bound
# removed together die at 133, SIGTRAP, with stdout still buffered so nothing
# prints at all. The bound is what turns an unbounded ask into three asks, so
# damaging the clamp while it stands damages nothing observable.
#
# The `starve` arm is therefore about the pair, not about the clamp: the crash
# needs a position AppKit refuses *and* a loop willing to re-ask forever. Delete
# either sed below and `fatal_control` will catch it, which is the point.
#
# **The clamp and the bound moved out of the controller on 2026-09-02**, into
# `SplitSeat` in `WorkspaceLayout` (the split seat is a pure decision; the
# controller keeps `setPosition` and the measurement). A mutation seam has to
# move with the module it disables, so this control damages a shadow copy of the
# package source and links the extracted, undamaged controller against that
# rebuilt library. Sedding the extracted slice would change nothing, and the
# no-op guard would refuse the run, which is what it is for.
mutate_seat() {
  local name=$1
  shift
  local shadow="$OUT/shadow-$name"
  local lib="$OUT/lib-$name"
  rm -rf "$shadow" "$lib"
  mkdir -p "$shadow/Packages/WorkspaceLayout/Sources" "$lib"
  cp -R "$ROOT/Packages/WorkspaceLayout/Sources/WorkspaceLayout" "$shadow/Packages/WorkspaceLayout/Sources/"
  local file="$shadow/Packages/WorkspaceLayout/Sources/WorkspaceLayout/SplitSeat.swift"
  cp "$file" "$OUT/seat-$name.orig"
  local script
  for script in "$@"; do
    sed -i '' "$script" "$file"
  done
  if cmp -s "$OUT/seat-$name.orig" "$file"; then
    echo "MUTATION '$name' CHANGED NOTHING: the line it targets has moved or been"
    echo "rewritten in Packages/WorkspaceLayout/Sources/WorkspaceLayout/SplitSeat.swift,"
    echo "so the control below would fail for a reason that has nothing to do with the arm."
    exit 1
  fi
  # The clean dependencies, then `WorkspaceLayout` rebuilt from the damaged copy
  # over them. `build_packages` reads `$ROOT`, so it is pointed at the shadow
  # for that one call and nothing else.
  cp "$LIB"/* "$lib"/
  (ROOT="$shadow" build_packages "$lib" WorkspaceLayout)
  compile "$name" "$OUT/panesplit_extracted.swift" "$lib"
}

mutate_seat reachable \
  's/^        guard highest >= lowest else { return nil }$//' \
  's/^        return min(max(thickness \* ratio, lowest), highest)$/        return thickness * ratio/' \
  's/^        guard refusals < Self.refusalLimit else { return .spent }$//'

# `run` takes an axis, a mode and a mechanism. The `broken` mode is the built-in
# control: it disconnects the write-back the way the code stood before the fix,
# and the arm asserts that the bug reproduces, so it exits 0 when the pre-fix
# path still misbehaves and non-zero when it has quietly started working.
for mech in drag set; do
  for axis in sidebyside stacked; do
    for mode in broken fixed; do
      "$OUT/dragtest-clean" "$axis" "$mode" "$mech"
      echo
    done
  done
done

# The two cases whose failure can also be a dead process rather than a printed
# number, so `set -e` and the exit status carry an assertion the numbers cannot.
"$OUT/dragtest-clean" starve
echo
"$OUT/dragtest-clean" click
echo

# Each control against the arm it is supposed to break. An arm that survives its
# own damage proves nothing, so a control that passes fails the run.
control() {
  local name=$1
  shift
  echo "-- control '$name' against: $*"
  local status=0
  "$OUT/dragtest-$name" "$@" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "CONTROL DID NOT FAIL: '$*' passes against a damaged $name, so it proves nothing"
    exit 1
  fi
  echo "(control failed with status $status, as it must)"
  echo
}

# The clamp control is the one whose damage kills the process rather than
# printing a wrong number, and that difference is the whole crash class, so the
# status is asserted rather than described in prose. Currently 133, SIGTRAP,
# raised inside the first layout pass with stdout still buffered, which is why it
# prints nothing at all. Any signal will do: what must not happen is a clean exit
# 1 from a printed FAIL, which would mean the layout loop had stopped being fatal
# and `starve` had stopped testing it.
#
# That is not hypothetical and this guard earned its keep: it caught exactly that
# on 2026-08-14, having been silently true since `refusals` shipped on
# 2026-07-31. The fix was to damage the bound alongside the clamp rather than to
# weaken this assertion, because what stops the process dying is now a deliberate
# guard in the shipped code and not an accident. See the `mutate reachable` note.
fatal_control() {
  local name=$1
  shift
  echo "-- control '$name' against: $*  (expected to be killed, not to print)"
  local status=0
  "$OUT/dragtest-$name" "$@" || status=$?
  if [ "$status" -lt 128 ]; then
    echo "CONTROL DID NOT DIE: '$*' exited $status against a damaged $name rather than"
    echo "being killed, so the unbounded layout pass is no longer what this arm proves."
    exit 1
  fi
  echo "(control was killed with status $status, as it must be)"
  echo
}

control notify sidebyside fixed drag
control notify stacked fixed set
control pin sidebyside fixed drag
control pin stacked fixed set
control enforce sidebyside broken drag
control enforce stacked broken set
control moved click
fatal_control reachable starve

echo "all ten arms pass and all eight controls fail"
