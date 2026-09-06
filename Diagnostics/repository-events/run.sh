#!/bin/bash
# Compiles and runs the standalone RepositoryEvents fixture. It creates only a
# private temporary Git repository and never launches baia.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
scratch=${TMPDIR:-/tmp}
scratch=${scratch%/}
OUT=$(mktemp -d "$scratch/baia-repository-events.XXXXXX")
trap 'rm -rf "$OUT"' EXIT

swiftc -swift-version 6 \
  -default-isolation MainActor \
  -framework CoreServices \
  -o "$OUT/repository-events" \
  "$ROOT/Sources/RepositoryEvents.swift" \
  "$HERE/repositoryeventstest.swift"

"$OUT/repository-events"
