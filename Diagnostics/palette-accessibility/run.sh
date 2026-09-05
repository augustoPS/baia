#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-palette-accessibility.XXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
LIB="$OUT/lib"
SOURCE_SNAPSHOT="$OUT/sources"
mkdir -p "$LIB" "$SOURCE_SNAPSHOT"
cd "$ROOT"

GHOSTTY_LIB="$ROOT/.build/Build/Products/Debug"
GHOSTTY_HEADERS="$ROOT/.build/SourcePackages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers"
if [[ ! -f "$GHOSTTY_LIB/GhosttyTheme.o" || ! -f "$GHOSTTY_LIB/libghostty.a" ]]; then
  echo "palette-accessibility: Debug libghostty products are missing" >&2
  echo "  Run 'make build' outside this task, then re-run this fixture." >&2
  exit 1
fi
if [[ ! -f "$GHOSTTY_HEADERS/module.modulemap" ]]; then
  echo "palette-accessibility: libghostty module map is missing" >&2
  echo "  Run 'make build' outside this task, then re-run this fixture." >&2
  exit 1
fi

build_module() {
  local name=$1
  shift
  mkdir -p "$SOURCE_SNAPSHOT/$name"
  cp Packages/"$name"/Sources/"$name"/*.swift "$SOURCE_SNAPSHOT/$name/"
  swiftc -swift-version 6 -emit-library -emit-module \
    -module-name "$name" -emit-module-path "$LIB/$name.swiftmodule" \
    -o "$LIB/lib$name.dylib" -I "$LIB" -L "$LIB" \
    -I "$GHOSTTY_LIB" -Xcc -fmodule-map-file="$GHOSTTY_HEADERS/module.modulemap" \
    -Xcc -I"$GHOSTTY_HEADERS" "$@" \
    "$SOURCE_SNAPSHOT/$name"/*.swift
}

build_module BaiaSettings
build_module GitWorkspace
build_module PaneChrome -lBaiaSettings -lGitWorkspace \
  "$GHOSTTY_LIB/GhosttyTheme.o" "$GHOSTTY_LIB/GhosttyTerminal.o" \
  "$GHOSTTY_LIB/GhosttyKit.o" "$GHOSTTY_LIB/MSDisplayLink.o" \
  "$GHOSTTY_LIB/libghostty.a"

swiftc -swift-version 6 -parse-as-library -default-isolation MainActor -o "$OUT/palette-accessibility" \
  -I "$LIB" -L "$LIB" -I "$GHOSTTY_LIB" \
  -Xcc -fmodule-map-file="$GHOSTTY_HEADERS/module.modulemap" -Xcc -I"$GHOSTTY_HEADERS" \
  -lBaiaSettings -lGitWorkspace -lPaneChrome \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/main.swift" Sources/CommandPaletteView.swift

"$OUT/palette-accessibility"
