#!/bin/bash
# Builds the theme-catalog sweep and prints the path to the binary. Runs nothing.
#
# Split out of `run.sh` on 2026-08-02, for a reason that is about agents rather
# than about builds. A reviewer that wants to *inspect* the sweep, rather than
# take its verdict, needs the binary without the arm and the three controls. With
# only `run.sh` on disk it has one option: transcribe these `swiftc` lines into a
# single Bash call. That call has to carry `build_module` as a one-line shell
# function, and a brace holding a quote is what Claude Code's own command
# analyser reads as possible brace-expansion obfuscation. It then refuses to
# prefix-match the command against any allow rule, so the call prompts and **no
# permission entry can ever pre-approve it**. The only fix is to stop generating
# the shape, which means shipping the build as a script worth allowing.
#
# Writes only under $OUT, opens no window, launches no app, and touches nothing
# in the repository.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-${TMPDIR:-/tmp}/baia-theme-catalog-probe}
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

echo "$OUT/catalogsweep"
