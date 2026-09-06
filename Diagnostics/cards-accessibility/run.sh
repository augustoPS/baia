#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-cards-accessibility.XXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
LIB="$OUT/lib"
SOURCE_SNAPSHOT="$OUT/sources"
mkdir -p "$LIB" "$SOURCE_SNAPSHOT"
cd "$ROOT"

build_module() {
  local name=$1
  shift
  mkdir -p "$SOURCE_SNAPSHOT/$name"
  cp Packages/"$name"/Sources/"$name"/*.swift "$SOURCE_SNAPSHOT/$name/"
  rm -f "$SOURCE_SNAPSHOT/$name/SettingsDerivations.swift" \
    "$SOURCE_SNAPSHOT/$name/PaneAppearance.swift"
  swiftc -swift-version 6 -emit-library -emit-module \
    -module-name "$name" -emit-module-path "$LIB/$name.swiftmodule" \
    -o "$LIB/lib$name.dylib" -I "$LIB" -L "$LIB" "$@" \
    "$SOURCE_SNAPSHOT/$name"/*.swift
}

build_module BaiaSettings
build_module GitWorkspace
build_module PaneControl
build_module PaneChrome -lBaiaSettings -lGitWorkspace
build_module WorkspaceLayout -lPaneControl

swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
  -o "$OUT/cards-accessibility" \
  -I "$LIB" -L "$LIB" \
  -lBaiaSettings -lGitWorkspace -lPaneControl -lPaneChrome -lWorkspaceLayout \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/main.swift" \
  "$ROOT/Sources/WindowCorner.swift" \
  "$ROOT/Sources/PaneOverlayView.swift" \
  "$ROOT/Sources/PaneClusterView.swift" \
  "$ROOT/Sources/ClusterPlaceCardView.swift" \
  "$ROOT/Sources/ClusterChangesCardView.swift" \
  "$ROOT/Sources/ClusterAttentionCardView.swift" \
  "$ROOT/Sources/SurfaceFill.swift"

"$OUT/cards-accessibility"
