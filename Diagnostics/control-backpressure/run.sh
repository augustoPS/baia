#!/bin/bash
# Unique-directory slow-reader harness for ControlTransport + ControlClient.
# The probe owns a private directory socket, bounds every read, and asserts
# shutdown unlinks the socket. Does not launch baia.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/.build/control-backpressure"
mkdir -p "$OUT"

swift build --package-path "$ROOT/Packages/WorkspaceLayout" --build-path "$OUT/pkg" -c debug

MOD="$OUT/pkg/arm64-apple-macosx/debug"
swiftc -swift-version 6 \
  -parse-as-library \
  -I "$MOD/Modules" \
  -o "$OUT/probe" \
  "$ROOT/Sources/ControlTransport.swift" \
  "$ROOT/CLI/ControlClient.swift" \
  "$HERE/probe.swift" \
  "$MOD/PaneControl.build"/*.swift.o \
  "$MOD/WorkspaceLayout.build"/*.swift.o

"$OUT/probe"
