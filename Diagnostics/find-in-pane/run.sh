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

# `PaneChrome` depends on libghostty (`GhosttyTheme` and `GhosttyTerminal` carry
# the theme catalog and the terminal configuration types), and libghostty is not
# a local package this script can compile from source. Its modules are taken from
# the Debug products directory instead, which holds whole-module `.o` files and
# `libghostty.a` — the *linked* output, not the per-file object directory the
# note below rejects. That makes `make build` a precondition of this probe, so
# say so here rather than letting swiftc report a missing module.
GHOSTTY_LIB="$ROOT/.build/Build/Products/Debug"
# `GhosttyTerminal` is built on the `libghostty` C module, so its Clang module
# map has to be reachable too; it ships inside the binary target's xcframework
# rather than in the products directory.
GHOSTTY_HEADERS="$ROOT/.build/SourcePackages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers"
if [[ ! -f "$GHOSTTY_LIB/GhosttyTheme.o" || ! -f "$GHOSTTY_LIB/libghostty.a" ]]; then
  echo "find-in-pane: libghostty products are missing from $GHOSTTY_LIB" >&2
  echo "  This probe links GhosttyTheme and GhosttyTerminal, which only exist" >&2
  echo "  after a Debug build. Run 'make build' first, then re-run this." >&2
  exit 1
fi
if [[ ! -f "$GHOSTTY_HEADERS/module.modulemap" ]]; then
  echo "find-in-pane: the libghostty module map is missing from" >&2
  echo "  $GHOSTTY_HEADERS" >&2
  echo "  Run 'make build' to resolve the binary target, then re-run this." >&2
  exit 1
fi

# The local packages are built straight from source rather than picked out of
# SwiftPM's incremental object directory, whose per-file objects carry duplicate
# type metadata and do not link on their own.
build_module() {
  local name=$1
  shift
  swiftc -swift-version 6 -emit-library -emit-module \
    -module-name "$name" -emit-module-path "$LIB/$name.swiftmodule" \
    -o "$LIB/lib$name.dylib" -I "$LIB" -L "$LIB" \
    -I "$GHOSTTY_LIB" -Xcc -fmodule-map-file="$GHOSTTY_HEADERS/module.modulemap" \
    -Xcc -I"$GHOSTTY_HEADERS" "$@" \
    Packages/"$name"/Sources/"$name"/*.swift
}

build_module BaiaSettings
build_module GitWorkspace
# `GhosttyTheme` sits on `GhosttyTerminal`, which sits on `GhosttyKit` and
# `MSDisplayLink` (its render tick). All four plus the static archive are named
# here because none of them is a dylib carrying its own dependencies.
build_module PaneChrome -lBaiaSettings -lGitWorkspace \
  "$GHOSTTY_LIB/GhosttyTheme.o" "$GHOSTTY_LIB/GhosttyTerminal.o" \
  "$GHOSTTY_LIB/GhosttyKit.o" "$GHOSTTY_LIB/MSDisplayLink.o" \
  "$GHOSTTY_LIB/libghostty.a"
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
  -I "$LIB" -L "$LIB" -I "$GHOSTTY_LIB" \
  -Xcc -fmodule-map-file="$GHOSTTY_HEADERS/module.modulemap" -Xcc -I"$GHOSTTY_HEADERS" \
  -lBaiaSettings -lGitWorkspace -lPaneChrome -lPaneSearch \
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
