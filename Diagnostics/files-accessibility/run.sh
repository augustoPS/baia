#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-files-accessibility.XXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
LIB="$OUT/lib"
SOURCE_SNAPSHOT="$OUT/sources"
mkdir -p "$LIB" "$SOURCE_SNAPSHOT"
cd "$ROOT"

# Snapshot package sources before compiling so concurrent package work cannot
# produce a module assembled from two revisions. PaneChrome's terminal-backed
# appearance files are unrelated to this AppKit-only fixture and intentionally
# excluded, matching Diagnostics/lib/build-packages.sh.
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
build_module PaneChrome -lBaiaSettings -lGitWorkspace

swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
  -o "$OUT/files-accessibility" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/main.swift" \
  "$ROOT/Sources/FilesSurface.swift" \
  "$ROOT/Sources/SidebarRowMetrics.swift" \
  "$ROOT/Sources/WorkspaceSurface.swift" \
  "$ROOT/Sources/RowFeedback.swift" \
  "$ROOT/Sources/DividerGrabView.swift" \
  "$ROOT/Sources/SurfaceFill.swift"

"$OUT/files-accessibility"
