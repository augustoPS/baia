#!/bin/bash
# Builds the Debug app unless the coordinator already did, then runs the
# Settings window's in-app self-check against an isolated copy.
#
#   ./run.sh
#
# **Not safe from inside a baia pane.** The check launches the copy in the
# foreground, opens its windows, and quits. Run it from a terminal that is not
# a pane.
#
# Isolation owns the instance: unique bundle id, Application Support directory,
# config file, and ZDOTDIR. It does not copy the owner's config and does not
# launch `baia-dev.app` against the Debug session or acknowledgement.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"

if [ -n "${BAIA_PANE:-}" ]; then
  echo "settings-window launches an app that takes focus. Run it outside a baia pane."
  exit 1
fi

if [ "${BAIA_SETTINGS_WINDOW_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != "1" ]; then
  make build
fi

ISOLATED_LABEL=settings-window
# shellcheck source=../lib/isolated-app.sh
source "$ROOT/Diagnostics/lib/isolated-app.sh"
isolated_install_traps
isolated_prepare

cat > "$ISOLATED_CONFIG" <<EOF
{
  "controlChannelEnabled": false,
  "controlAllowRun": false,
  "notificationsEnabled": false,
  "restoreSession": true,
  "projectRoots": ["$ISOLATED_OUT"]
}
EOF

BAIA_SETTINGS_SELFCHECK=1 isolated_launch
wait "$ISOLATED_CHILD_PID"
cat "$ISOLATED_EVIDENCE/app.log"
