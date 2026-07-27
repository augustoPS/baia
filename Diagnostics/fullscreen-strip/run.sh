#!/bin/bash
# Builds and runs the full-screen strip probe. Output goes to a scratch
# directory; nothing is written into the repo.
#
# `geometry` takes over the display for a few seconds, the way footer-corners'
# own fullscreen arm does, so it is not something to start in the middle of
# something else. It exits on its own.
#
# `sample` needs an image and is therefore not run here: pass it a screenshot.
#
#   ./run.sh
#   ./run.sh sample ~/Desktop/shot.png 1800,36 600,106
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${TMPDIR:-/tmp}/baia-fullscreen-strip-probe
mkdir -p "$OUT"

# No package dependencies. The question is entirely about AppKit's own geometry,
# so linking baia's packages in would only add ways for the probe to fail for
# reasons that are not the answer.
swiftc -swift-version 6 -default-isolation MainActor -o "$OUT/fullscreenstrip" \
  "$HERE/fullscreenstrip.swift"

if [ $# -gt 0 ]; then
  "$OUT/fullscreenstrip" "$@"
else
  "$OUT/fullscreenstrip" geometry
fi
