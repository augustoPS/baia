#!/bin/bash
# Builds and runs the clip-layout probe. Output goes to a scratch directory; it
# writes nothing into the repo.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-clip-layout-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# Built straight from source rather than picked out of SwiftPM's incremental
# object directory, whose per-file objects carry duplicate type metadata and do
# not link on their own. Same reason as `footer-corners`.
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
build_module GitWorkspace

# The shipped sidebar files are compiled verbatim, not sliced and not retyped, so
# the view driven below is the view the app installs. If `ChangesSurface` ever
# grows a dependency on another file in `Sources/`, this line is where that shows
# up, and adding it here is the right answer rather than stubbing it.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/cliptest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lGitWorkspace -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/cliptest.swift" \
  "$ROOT/Sources/ChangesSurface.swift" \
  "$ROOT/Sources/WorkspaceSurface.swift" \
  "$ROOT/Sources/RowFeedback.swift" \
  "$ROOT/Sources/DividerGrabView.swift"

# One arm per process, each followed by its negative control. `set -e` makes the
# passing arms the test; the controls are inverted, so a control that stops
# failing fails the run just as loudly as an arm that stops passing.
#
# Every arm runs as an accessory app and none takes focus: the window is built
# off-screen and never ordered front.
for arm in floor width tracking reflow; do
  "$OUT/cliptest" "$arm"
  echo
  if "$OUT/cliptest" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even when $arm is wrong, so it proves nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
done

echo "all four arms pass and all four controls fail"
