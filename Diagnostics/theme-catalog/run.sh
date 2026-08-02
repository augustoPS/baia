#!/bin/bash
# Builds and runs the theme-catalog sweep. Output goes to a scratch directory;
# it writes nothing into the repo, opens no window, and touches no running app.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-theme-catalog-probe
LIB="$OUT/lib"
mkdir -p "$LIB"
cd "$ROOT"

# The theme catalog is gitignored and reproduced from two tracked files, so a
# fresh clone has no `upstream/` at all. `make upstream` is idempotent and does
# not build, generate or launch anything.
if [ ! -d "$ROOT/upstream/libghostty-spm/Sources/GhosttyTheme" ]; then
  make upstream
fi

# Built straight from source rather than picked out of SwiftPM's incremental
# object directory, whose per-file objects carry duplicate type metadata and do
# not link on their own. Same reason as `attention-colour/run.sh`.
build_module() {
  local name=$1
  shift
  swiftc -swift-version 6 -emit-library -emit-module \
    -module-name "$name" -emit-module-path "$LIB/$name.swiftmodule" \
    -o "$LIB/lib$name.dylib" -I "$LIB" -L "$LIB" "$@" \
    Packages/"$name"/Sources/"$name"/*.swift
}

build_module BaiaSettings
build_module GitWorkspace
build_module PaneChrome -lBaiaSettings -lGitWorkspace

# The catalog, from the patched checkout `project.yml` points at, so the themes
# swept are the themes the app offers. `GhosttyThemeDefinition+TerminalConfiguration`
# is the one file left out: it imports `GhosttyTerminal`, which pulls in
# libghostty and a Metal surface, and nothing here needs a terminal to exist.
swiftc -swift-version 6 -emit-library -emit-module \
  -module-name GhosttyTheme -emit-module-path "$LIB/GhosttyTheme.swiftmodule" \
  -o "$LIB/libGhosttyTheme.dylib" -I "$LIB" -L "$LIB" \
  "$ROOT/upstream/libghostty-spm/Sources/GhosttyTheme/GhosttyThemeDefinition.swift" \
  "$ROOT/upstream/libghostty-spm/Sources/GhosttyTheme/GhosttyThemeCatalog.swift" \
  "$ROOT"/upstream/libghostty-spm/Sources/GhosttyTheme/Themes/*.swift

swiftc -swift-version 6 -O -o "$OUT/catalogsweep" \
  -I "$LIB" -L "$LIB" -lBaiaSettings -lGitWorkspace -lPaneChrome -lGhosttyTheme \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$HERE/catalogsweep.swift"

# The arm, then one negative control per rule it grades. `set -e` makes the arm
# the test; the controls are inverted, so a control that stops failing fails the
# run as loudly as an arm that stops passing.
#
# Three rather than one, and that is a finding rather than thoroughness. The
# first version had a single control that replaced `nightshade` with the bar it
# is drawn on, and it passed: `nightshade` already clears 4.5:1 raw on none of
# the 485, the repair chain lifts a bar-coloured accent like any other, and
# `derived(from:)` still had a palette to walk. It damaged nothing any pin or
# rule could see. Each control now imitates one specific wrong measurement.
"$OUT/catalogsweep"
echo

for control in break-repair break-derive break-pins; do
  if "$OUT/catalogsweep" "$control"; then
    echo "CONTROL DID NOT FAIL: $control passes, so the rule it damages is not being graded"
    exit 1
  fi
  echo "($control failed, as it must)"
  echo
done

echo "the sweep passes and all three controls fail"
