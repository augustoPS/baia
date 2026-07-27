#!/bin/bash
# Builds and runs the find-panel probe. Output goes to a scratch directory; the
# only thing this writes into the repo is nothing at all.
#
# One case per process, the rule the other two probes follow: the responder case
# counts the hand-back of the keyboard, and a shared process would let one case's
# window state stand in for the other's.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-find-in-pane-probe
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
build_module PaneSearch

# `PalettePanel` is sliced out of the shipped file rather than retyped here, so
# the probe cannot pass against a copy that has drifted from what the app builds.
# `canBecomeKey` is the line that matters: a panel that cannot take key never
# takes the keyboard, so the hand-back this probe counts would never run.
awk '/^\/\/\/ A borderless panel/{f=1} /^\/\/\/ The .* project palette\./{f=0} f' \
  Sources/CommandPaletteController.swift > "$OUT/palettepanel_extracted.body"
{ printf 'import AppKit\n\n'; cat "$OUT/palettepanel_extracted.body"; } \
  > "$OUT/palettepanel_extracted.swift"
grep -q 'final class PalettePanel' "$OUT/palettepanel_extracted.swift"
grep -q 'canBecomeKey' "$OUT/palettepanel_extracted.swift"
echo "extracted $(grep -c '' "$OUT/palettepanel_extracted.swift") lines from Sources/CommandPaletteController.swift"

# The panel itself and the palette views are compiled from the repo verbatim,
# which is stronger than slicing: there is no extraction step that could go stale
# and nothing here to keep in step with them.
echo "compiling Sources/FindPanelController.swift and Sources/CommandPaletteView.swift verbatim"

# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so the shipped source compiles under the rules
# it ships under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/findtest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lPaneSearch \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/findtest.swift" \
  Sources/FindPanelController.swift \
  Sources/CommandPaletteView.swift \
  "$OUT/palettepanel_extracted.swift"

# Both cases fail by printing FAIL and exiting 1, so `set -e` and the exit status
# are the assertion for the script as a whole.
for case in responder retention; do
  "$OUT/findtest" "$case"
  echo
done
