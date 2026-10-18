#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
if [[ "${1:-}" != "--build-only" && ( -n "${BAIA_PANE:-}" || -n "${BAIA_TOKEN:-}" ) ]]; then
    echo "Refused: this probe takes keyboard focus. Run from a terminal outside baia, or use --build-only." >&2
    exit 2
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--build-only" ) ]]; then
    echo "Usage: $0 [--build-only]" >&2
    exit 2
fi

OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-quick-terminal.XXXXXX")
cd "$ROOT"
source "$ROOT/Diagnostics/lib/build-packages.sh"
build_packages "$OUT" PaneControl WorkspaceLayout
swiftc -swift-version 6 -default-isolation MainActor \
    -I "$OUT" -L "$OUT" -lPaneControl -lWorkspaceLayout \
    "$ROOT/Sources/QuickTerminalController.swift" \
    "$ROOT/Sources/GlobalTerminalShortcut.swift" \
    "$HERE/probe.swift" -o "$OUT/probe"
if [[ "${1:-}" == "--build-only" ]]; then
    echo "Quick terminal probe compiled. Live checks were not run."
    exit 0
fi
export DYLD_LIBRARY_PATH="$OUT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
if "$OUT/probe" --negative-control; then
    echo "FAIL: identity-loss negative control did not fail" >&2
    exit 1
fi
"$OUT/probe"
