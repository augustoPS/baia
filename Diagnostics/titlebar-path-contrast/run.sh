#!/bin/bash
# Compiles the production titlebar accessory and verifies its glass-only edge.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-titlebar-path-contrast
LIB="$OUT/lib"
mkdir -p "$LIB"

. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneControl PaneChrome WorkspaceLayout

PROBE="$HERE/main.swift"
if [[ ${1:-} == "--expect-missing" ]]; then
  PROBE="$HERE/missing.swift"
  shift
fi

swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/titlebar-path-contrast" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$PROBE" \
  "$ROOT/Sources/SidebarRowMetrics.swift" \
  "$ROOT/Sources/TitlebarPathAccessory.swift"

"$OUT/titlebar-path-contrast" "$@"
