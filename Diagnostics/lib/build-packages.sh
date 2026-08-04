#!/bin/bash
# Builds local packages from source for a probe, with the dependency edges that
# SwiftPM knows and a hand-written `swiftc` line does not.
#
# Sourced, not executed:
#
#   . "$ROOT/Diagnostics/lib/build-packages.sh"
#   build_packages "$LIB" BaiaSettings PaneChrome WorkspaceLayout
#
# Why this file exists. Every probe that compiles a package builds it straight
# from source rather than out of SwiftPM's incremental object directory, whose
# per-file objects carry duplicate type metadata and do not link on their own.
# That is still correct. What was wrong is that each probe wrote its own module
# list and its own `-l` flags, so seven copies of the same dependency graph sat
# outside the one place that updates itself when a file moves.
#
# They went stale, silently, and `make build` and `make test` both stayed green
# the whole time because neither compiles a probe. Measured 2026-08-03, six of
# seven were dead:
#
#   theme-catalog     GhosttyTerminal, via SettingsDerivations (9e60308, same day)
#   attention-colour  GitWorkspace, PaneControl, and the same SettingsDerivations
#   clip-layout       GhosttyTerminal, via SettingsDerivations
#   theme-refresh     GitWorkspace, via FileTreeExpansions
#   pane-resize       GitWorkspace, via FileTreeExpansions
#   footer-corners    GitWorkspace, via FileTreeExpansions
#
# Only `fullscreen-strip` survived, because it builds a minimal target of its own
# and imports no local package at all.
#
# So the edges live here once. A package that gains a cross-package import needs
# one line in `package_deps` rather than an edit to every probe that links it,
# and a probe that is not updated fails loudly on the next run instead of
# quietly on the next move.

# What each package imports, beyond Foundation and the system frameworks. Read
# off the sources rather than the manifests: `Package.swift` describes the test
# targets too, and the link line wants only what the library half needs.
#
# Keep in dependency order within a value; `build_packages` links left to right.
package_deps() {
  case "$1" in
    BaiaSettings)    printf '' ;;
    GitWorkspace)    printf '' ;;
    PaneControl)     printf '' ;;
    WorkspaceLayout) printf 'PaneControl' ;;
    PaneChrome)      printf 'BaiaSettings GitWorkspace' ;;
    *)               printf '' ;;
  esac
}

# Files excluded from a package when a probe builds it.
#
# `SettingsDerivations.swift` imports `GhosttyTerminal`, which is where `View/`,
# `Surface/` and `Platform/` live: the rendering half, and the thing every
# headless probe exists to stay clear of. It arrived in `PaneChrome` on
# 2026-08-03 (`9e60308`) and killed three probes on contact. Nothing any probe
# grades calls its four derivations, so it is excluded rather than linked, which
# is the same move `theme-catalog` already made for
# `GhosttyThemeDefinition+TerminalConfiguration`.
#
# An exclusion is a claim that no probe needs the file. If one ever does, it
# links `GhosttyTerminal` and stops being headless, which is a decision worth
# making explicitly rather than discovering through a Metal crash.
package_excludes() {
  case "$1" in
    PaneChrome) printf 'SettingsDerivations.swift' ;;
    *)          printf '' ;;
  esac
}

# build_packages <lib-dir> <package>...
#
# Builds each named package into <lib-dir>, in the order given, linking whatever
# `package_deps` says it needs. Callers list packages in dependency order; this
# does not sort them, because a probe that lists them wrongly should fail on its
# own line rather than have the order silently repaired underneath it.
build_packages() {
  local lib=$1
  shift
  local name deps excludes dep_flags sources source base

  for name in "$@"; do
    deps=$(package_deps "$name")
    excludes=$(package_excludes "$name")

    dep_flags=()
    for dep in $deps; do
      dep_flags+=("-l$dep")
    done

    sources=()
    for source in "$ROOT"/Packages/"$name"/Sources/"$name"/*.swift; do
      base=$(basename "$source")
      case " $excludes " in
        *" $base "*) continue ;;
      esac
      sources+=("$source")
    done

    if [ ${#sources[@]} -eq 0 ]; then
      echo "build-packages: no sources for $name" >&2
      return 1
    fi

    # `${dep_flags[@]+"${dep_flags[@]}"}` rather than `"${dep_flags[@]}"`: bash
    # 3.2 is what ships on macOS, and there an empty array under `set -u` is an
    # unbound variable rather than zero arguments. Every leaf package (
    # `BaiaSettings`, `GitWorkspace`, `PaneControl`) has no deps, so the plain
    # spelling fails on the first package every probe builds.
    swiftc -swift-version 6 -emit-library -emit-module \
      -module-name "$name" -emit-module-path "$lib/$name.swiftmodule" \
      -o "$lib/lib$name.dylib" -I "$lib" -L "$lib" \
      ${dep_flags[@]+"${dep_flags[@]}"} \
      "${sources[@]}"
  done
}
