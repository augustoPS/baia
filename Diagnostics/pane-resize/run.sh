#!/bin/bash
# Builds and runs the pane-resize probe. Output goes to a scratch directory; the
# only thing this writes into the repo is nothing at all.
#
# One case per process: a contaminated event queue produced a false result during
# the investigation that found this bug, and the cheapest defence is a fresh
# process per case.
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
build_module() {
  local name=$1
  shift
  swiftc -swift-version 6 -emit-library -emit-module \
    -module-name "$name" -emit-module-path "$LIB/$name.swiftmodule" \
    -o "$LIB/lib$name.dylib" -I "$LIB" -L "$LIB" "$@" \
    Packages/"$name"/Sources/"$name"/*.swift
}

build_module BaiaSettings
build_module PaneChrome -lBaiaSettings
build_module WorkspaceLayout

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
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/dragtest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/dragtest.swift" "$OUT/panesplit_extracted.swift"

for mech in drag set; do
  for axis in sidebyside stacked; do
    for mode in broken fixed; do
      "$OUT/dragtest" "$axis" "$mode" "$mech"
      echo
    done
  done
done

# The two cases whose failure is not a printed number but a dead process, so
# `set -e` and the exit status are the assertion. Both abort with SIGABRT under
# an uncaught NSGenericException if `applyRatio` ever chases a position
# `minimumThickness` refuses.
"$OUT/dragtest" starve
echo
"$OUT/dragtest" click
