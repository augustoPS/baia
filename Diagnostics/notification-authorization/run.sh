#!/bin/bash
# Compiles AttentionNotifier with a fake UN client and runs the R12 checks,
# then the same checks against a copy with the generation guard deleted.
# Launches nothing, takes no focus, changes no OS permission.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
scratch=${TMPDIR:-/tmp}
scratch=${scratch%/}
OUT=$(mktemp -d "$scratch/baia-notification-authorization.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cd "$ROOT"

compile() {
  local source=$1 dest=$2
  swiftc -swift-version 6 -default-isolation MainActor \
    -framework AppKit -framework UserNotifications \
    -o "$dest" \
    "$HERE/authtest.swift" \
    "$source"
}

compile "$ROOT/Sources/AttentionNotifier.swift" "$OUT/authtest"
"$OUT/authtest"

mutant=$OUT/AttentionNotifier-unguarded.swift
/usr/bin/sed '/guard generation == authorizationGeneration else { return }/d' \
  "$ROOT/Sources/AttentionNotifier.swift" > "$mutant"
if grep -q 'guard generation == authorizationGeneration else { return }' "$mutant"; then
  echo "FAIL mutant still contains the generation guard" >&2
  exit 1
fi
compile "$mutant" "$OUT/authtest-unguarded"
if "$OUT/authtest-unguarded"; then
  echo "FAIL generation-guard-removed mutant passed; stale completion is not last" >&2
  exit 1
fi
echo "ok    generation-guard-removed mutant failed as required"
