#!/bin/bash
# Builds and runs the attention-colour probe. Output goes to a scratch directory;
# it writes nothing into the repo.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-attention-colour-probe
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
build_module GitWorkspace
build_module PaneControl
build_module WorkspaceLayout -lPaneControl

# `PaneChrome` minus `SettingsDerivations.swift`, and with `GitWorkspace` linked.
# Both are consequences of files moving into this package after the line above was
# written, and neither announced itself: a hand-rolled link line sits outside
# SwiftPM's dependency graph, so it goes stale silently and the probe fails at
# compile time rather than reporting anything about the code it grades.
# `FileTreeExpansions` needs `GitWorkspace`; `SettingsDerivations` imports
# `GhosttyTerminal`, which is the rendering half and is excluded here for the same
# reason `theme-catalog/build.sh` excludes it.
PANE_CHROME_SOURCES=()
for source in Packages/PaneChrome/Sources/PaneChrome/*.swift; do
  [ "$(basename "$source")" = SettingsDerivations.swift ] && continue
  PANE_CHROME_SOURCES+=("$source")
done
swiftc -swift-version 6 -emit-library -emit-module \
  -module-name PaneChrome -emit-module-path "$LIB/PaneChrome.swiftmodule" \
  -o "$LIB/libPaneChrome.dylib" -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace \
  "${PANE_CHROME_SOURCES[@]}"

# The shipped files are compiled verbatim, not sliced and not retyped, so the
# pixels measured are the pixels the app draws. `PaneOverlayView` reaches nothing
# outside these three packages and `WindowCorner`; if it grows a dependency on
# another file in `Sources/`, this line is where that shows up.
#
# `Sources/PaneStatusBarView.swift` was on this line until 2026-08-13 and was
# deleted that day, taking the `fill`, `quiet`, `acked` and `conflict` arms with
# it — all four rendered the footer, which was the only view that drew the
# attention wash. Only `frame` survives; see the README for what went and what
# it would take to re-aim.
#
# `TerminalPaneController` is deliberately absent. It pulls in libghostty and
# spawns a pty, so the `frame` arm reads its one assignment out of the source text
# instead, and says so.
#
# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so they compile under the rules they ship under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/attentiontest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/attentiontest.swift" \
  "$ROOT/Sources/WindowCorner.swift" \
    "$ROOT/Sources/PaneOverlayView.swift"

# One arm per process, each followed by its negative control. `set -e` makes the
# passing arms the test; the controls are inverted, so a control that stops
# failing fails the run just as loudly as an arm that stops passing.
for arm in frame; do
  "$OUT/attentiontest" "$arm"
  echo
  if "$OUT/attentiontest" "$arm" break; then
    echo "CONTROL DID NOT FAIL: the $arm arm passes even when the drawing is wrong, so it proves nothing"
    exit 1
  fi
  echo "(control failed, as it must)"
  echo
done

echo "the frame arm passes and its control fails"
