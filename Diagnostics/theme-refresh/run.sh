#!/bin/bash
# Builds and runs the theme-refresh probe. Output goes to a scratch directory; it
# writes nothing into the repo.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-theme-refresh-probe
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
# drifted from what the app builds. Same boundary the pane-resize probe uses: if
# those two classes ever move out of that file, this awk range is the line to fix.
awk '/^\/\/\/ One split node:/{f=1} f' Sources/PaneTreeController.swift > "$OUT/panesplit_extracted.body"
{ printf 'import AppKit\nimport PaneChrome\nimport WorkspaceLayout\n\n'; cat "$OUT/panesplit_extracted.body"; } \
  > "$OUT/panesplit_extracted.swift"
grep -q 'final class PaneSplitController' "$OUT/panesplit_extracted.swift"
grep -q 'static func applyTheme' "$OUT/panesplit_extracted.swift"
echo "extracted $(grep -c '' "$OUT/panesplit_extracted.swift") lines from Sources/PaneTreeController.swift"

# -default-isolation MainActor matches the app target's
# SWIFT_DEFAULT_ACTOR_ISOLATION, so the extracted source compiles under the rules
# it ships under.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/themetest" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/themetest.swift" "$OUT/panesplit_extracted.swift"

# One arm per process. The first two are what the fix is measured against; only
# the third asserts, and it exits non-zero when any divider kept the old colour or
# any view moved.
"$OUT/themetest" noop
echo
"$OUT/themetest" rebuild
echo
"$OUT/themetest" push
