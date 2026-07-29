#!/usr/bin/env bash
# Builds the two throwaway repositories the sidebar captures are taken in.
#
# The Changes surface groups conflicts, staged, unstaged and untracked, and no
# real repository on this machine holds all four at once. Rather than stage and
# conflict a repository the owner is working in, the states are manufactured in
# a scratch directory that is deleted and rebuilt on every run.
#
#   ./design-captures/demo-repo.sh
#
# Writes two paths and nothing else, so a caller can read them:
#   <root>/dirty  every marker state, plus a deep tree for the file surface
#   <root>/clean  one commit, nothing changed, for the "no changes" empty state
set -euo pipefail

ROOT="${1:-/tmp/baia-design-demo}"
rm -rf "$ROOT"
mkdir -p "$ROOT"

git_quiet() { git -c init.defaultBranch=main -c user.name=capture -c user.email=capture@local "$@" >/dev/null 2>&1; }

# --- dirty ------------------------------------------------------------------
# Deep enough that the tree has something to indent and something to truncate at
# 260 pt, and shallow enough to read in one screenshot.
D="$ROOT/dirty"
mkdir -p "$D/Sources/Workspace/Rendering" "$D/Tests/WorkspaceTests" "$D/docs"
cd "$D"
git_quiet init
printf 'workspace\n' > README.md
printf 'struct Pane {}\n' > Sources/Workspace/Pane.swift
printf 'struct Renderer {}\n' > Sources/Workspace/Rendering/Renderer.swift
printf 'struct GridGeometry {}\n' > Sources/Workspace/Rendering/GridGeometry.swift
printf 'import Testing\n' > Tests/WorkspaceTests/PaneTests.swift
printf '# notes\n' > docs/architecture.md
git_quiet add -A
git_quiet commit -m "first"

# A conflict, which is the only state that needs two branches to exist.
git_quiet checkout -b other
printf 'workspace, from the branch\n' > README.md
git_quiet commit -am "branch edit"
git_quiet checkout main
printf 'workspace, from main\n' > README.md
git_quiet commit -am "main edit"
git merge other >/dev/null 2>&1 || true   # leaves README.md at UU

# Staged, unstaged and untracked, one each.
printf 'struct Divider {}\n' > Sources/Workspace/Divider.swift
git_quiet add Sources/Workspace/Divider.swift
printf 'struct Pane { var isFocused = false }\n' > Sources/Workspace/Pane.swift
printf 'scratch\n' > docs/scratch.md

# One path too long for a 260 pt column at any reasonable width, so the set shows
# what truncation does rather than only what a fitting path looks like. This is the
# row that used to lose its file name outright.
printf 'struct GridGeometry { var columns = 0 }\n' > Sources/Workspace/Rendering/GridGeometry.swift

# --- clean ------------------------------------------------------------------
C="$ROOT/clean"
mkdir -p "$C/Sources"
cd "$C"
git_quiet init
printf 'quiet\n' > README.md
printf 'struct Quiet {}\n' > Sources/Quiet.swift
git_quiet add -A
git_quiet commit -m "first"

echo "$D"
echo "$C"
