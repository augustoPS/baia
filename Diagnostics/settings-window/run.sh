#!/bin/bash
# Builds the Debug app and runs the Settings window's in-app self-check.
#
#   ./run.sh
#
# **Not safe from inside a baia pane.** The check launches baia-dev in the
# foreground of the calling shell, opens its windows, and quits: it takes
# focus for the seconds it runs. Run it from a terminal that is not a pane.
#
# The app is pointed at a scratch copy of the real config through
# `BAIA_CONFIG_FILE`, so nothing here writes to ~/.config/baia/config.json.
# The Debug build owns its own session file, socket and acknowledgement file
# under Application Support/baia-dev, so the installed copy is untouched too.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-settings-window-probe
mkdir -p "$OUT"
cd "$ROOT"

make --no-print-directory build >/dev/null

SCRATCH="$OUT/config.json"
if [[ -f "$HOME/.config/baia/config.json" ]]; then
  cp "$HOME/.config/baia/config.json" "$SCRATCH"
else
  rm -f "$SCRATCH"
fi

BAIA_SETTINGS_SELFCHECK=1 BAIA_CONFIG_FILE="$SCRATCH" \
  ".build/Build/Products/Debug/baia-dev.app/Contents/MacOS/baia-dev"
