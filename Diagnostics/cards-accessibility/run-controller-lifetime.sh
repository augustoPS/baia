#!/bin/bash
# Compiles a real-window acceptance fixture for ClusterCardController. Pass
# --compile-only to verify production-source compatibility without creating an
# NSWindow or changing focus; the coordinator runs the executable acceptance.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-card-controller-lifetime.XXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

PALETTE="$ROOT/Sources/CommandPaletteController.swift"
require_in_palette_panel() {
  if ! awk '/^final class PalettePanel: NSPanel \{/,/^\}/' "$PALETTE" | grep -qE "$1"; then
    echo "STALE: PalettePanel no longer contains: $2"
    exit 1
  fi
}
require_in_palette_panel 'override var canBecomeKey: Bool \{ true \}' 'canBecomeKey answering true'
require_in_palette_panel 'override var canBecomeMain: Bool \{ false \}' 'canBecomeMain answering false'

. "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$LIB" BaiaSettings GitWorkspace PaneChrome

swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
  -o "$OUT/controller-lifetime" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/controller-lifetime.swift" \
  "$ROOT/Sources/ClusterCardController.swift" \
  "$ROOT/Sources/ClusterPlaceCardView.swift" \
  "$ROOT/Sources/ClusterChangesCardView.swift" \
  "$ROOT/Sources/ClusterAttentionCardView.swift" \
  "$ROOT/Sources/SurfaceFill.swift"

if [[ ${1:-} == "--compile-only" ]]; then
  echo "PASS: controller lifetime fixture compiled; no window was created"
  exit 0
fi

"$OUT/controller-lifetime"
