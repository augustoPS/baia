#!/usr/bin/env bash
# Whether each build ships its own icon, and whether the chain that gives it one
# is still connected.
#
#   ./Diagnostics/app-icon/run.sh
#
# Launches nothing, opens no window, kills nothing, and writes nothing outside
# the repository. Safe from inside a pane, unlike every other driver here.
#
# ## Why this exists
#
# `observer/dev-icon` gave the Debug build its own icon and nothing in the
# repository could observe it losing one. The wave-five verification pass proved
# that by reverting `CFBundleIconFile` from `$(PRODUCT_NAME)` to the literal
# `baia`, which is the whole substantive change of that branch: `make build`
# succeeded, `make test` reported zero failures, and the built `baia-dev.app`
# quietly carried the Release icon again. The branch had been passed by an
# observer looking at a screen, and a screen was the only witness it ever had.
#
# An icon is a screen judgment and this does not pretend otherwise: it never asks
# whether the artwork is good. It asks whether the wiring that hands each
# configuration a *different* file is intact, which is a question with an answer.
set -uo pipefail
cd "$(dirname "$0")/../.."

fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

plist_get() {                   # plist_get <plist> <key>
  plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

echo "== the template, which is what makes the icon per-configuration"

# The mutation that proved the gap. A literal here is not a worse icon, it is one
# icon for two apps, and it is invisible in every build log.
icon_template=$(plist_get Info.plist CFBundleIconFile)
if [ "$icon_template" = '$(PRODUCT_NAME)' ]; then
  ok "Info.plist CFBundleIconFile is \$(PRODUCT_NAME)"
else
  bad "Info.plist CFBundleIconFile is '$icon_template', so both builds take one icon"
fi

# XcodeGen silently overwrites Info.plist with a stub if `info:` is added to the
# target, which would take this key with it. Cheap to assert here, and this is
# the file that would lose it.
if grep -qE '^\s*info:' project.yml; then
  bad "project.yml has an 'info:' key; XcodeGen will overwrite Info.plist with a stub"
else
  ok "project.yml has no 'info:' key, so Info.plist is ours"
fi

echo
echo "== both icons are tracked and both ship"

for name in baia baia-dev; do
  if [ -f "Icon/$name.icns" ]; then
    ok "Icon/$name.icns exists"
  else
    bad "Icon/$name.icns is missing"
  fi
  if grep -q "path: Icon/$name.icns" project.yml; then
    ok "project.yml copies Icon/$name.icns in as a resource"
  else
    bad "project.yml does not list Icon/$name.icns"
  fi
done

# Two names for one picture would satisfy every other check here while leaving
# the two builds indistinguishable in the Dock, which is the thing the branch was
# for.
if [ -f Icon/baia.icns ] && [ -f Icon/baia-dev.icns ]; then
  if cmp -s Icon/baia.icns Icon/baia-dev.icns; then
    bad "the two icons are byte-identical, so the builds look the same"
  else
    ok "the two icons differ"
  fi
fi

echo
echo "== the built bundles"

# Whatever is on disk. The Debug build comes from `make build`; Release is either
# built or installed, and an uninstalled Release is not a failure, it is a check
# that cannot run yet and says so.
BUNDLES=()
[ -d ".build/Build/Products/Debug/baia-dev.app" ] && BUNDLES+=(".build/Build/Products/Debug/baia-dev.app")
[ -d ".build/Build/Products/Release/baia.app" ] && BUNDLES+=(".build/Build/Products/Release/baia.app")
[ -d "/Applications/baia.app" ] && BUNDLES+=("/Applications/baia.app")

if [ ${#BUNDLES[@]} -eq 0 ]; then
  echo "  none built. Run 'make build' for the Debug half of this check."
fi

seen_icons=""
for bundle in "${BUNDLES[@]}"; do
  plist="$bundle/Contents/Info.plist"
  # The path, not the basename: a built Release bundle and an installed one are
  # both `baia.app` and are routinely different builds, so a basename label makes
  # two lines that look like a repeat and hides which copy failed.
  label="$bundle"
  exe=$(plist_get "$plist" CFBundleExecutable)
  icon=$(plist_get "$plist" CFBundleIconFile)

  # The template resolved. A build carrying the literal `$(PRODUCT_NAME)` has an
  # icon nothing can find, and a build whose icon does not match its own
  # executable name is carrying the other configuration's.
  if [ "$icon" = "$exe" ]; then
    ok "$label: CFBundleIconFile resolved to '$icon', its own PRODUCT_NAME"
  else
    bad "$label: CFBundleIconFile is '$icon' but the executable is '$exe'"
  fi

  # Named without the extension in the plist, present with it on disk.
  if [ -f "$bundle/Contents/Resources/$icon.icns" ]; then
    ok "$label: Resources/$icon.icns is there for it to find"
  else
    bad "$label: Resources/$icon.icns is missing, so the Dock falls back to a blank"
  fi

  # The tracked file is the source of truth; a bundle carrying something else
  # means `make-icon.swift` was run and its output never committed.
  if [ -f "Icon/$icon.icns" ] && [ -f "$bundle/Contents/Resources/$icon.icns" ]; then
    if cmp -s "Icon/$icon.icns" "$bundle/Contents/Resources/$icon.icns"; then
      ok "$label: the shipped icon matches tracked Icon/$icon.icns"
    else
      bad "$label: the shipped icon differs from tracked Icon/$icon.icns"
    fi
  fi

  seen_icons="$seen_icons $icon"
done

# The cross-configuration claim, and the only check that needs two builds. It is
# the one the branch actually made: not "each build has an icon" but "the two
# builds have different ones".
debug_icon=""
release_icon=""
for bundle in "${BUNDLES[@]}"; do
  icon=$(plist_get "$bundle/Contents/Info.plist" CFBundleIconFile)
  case "$(basename "$bundle")" in
    baia-dev.app) debug_icon=$icon ;;
    baia.app) release_icon=$icon ;;
  esac
done

echo
if [ -n "$debug_icon" ] && [ -n "$release_icon" ]; then
  if [ "$debug_icon" != "$release_icon" ]; then
    ok "the two configurations name different icons: '$debug_icon' and '$release_icon'"
  else
    bad "both configurations name '$debug_icon', which is the state dev-icon existed to end"
  fi
else
  echo "  SKIP  the two-configuration check needs both bundles."
  echo "        have:${seen_icons:- none}. Build the other, or 'make install'."
fi

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
