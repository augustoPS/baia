#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-tab-close-layout.XXXXXX")
trap 'rm -f "$OUT/Controller.swift" "$OUT/probe"; rmdir "$OUT"' EXIT
python3 "$HERE/extract.py" "$ROOT/Sources/WorkspaceWindowController.swift" "$OUT/Controller.swift" "$@"
swiftc -parse-as-library -swift-version 6 -default-isolation MainActor "$HERE/main.swift" "$OUT/Controller.swift" -o "$OUT/probe"
"$OUT/probe"
