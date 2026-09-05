#!/bin/bash
# Real-app fixture for report deadlines and zoom-hidden pane observation.
# It launches an isolated app copy, so run it only outside a baia pane.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"

if [ "${BAIA_REPORT_EXPIRY_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != "1" ]; then
  make build
fi

# c43b0a1 introduced the shared isolation owner after this task's base revision.
# The override lets review use that committed helper now; after integration the
# default points at the same path in this checkout.
DIAGNOSTICS_LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
ISOLATION_HELPER="$DIAGNOSTICS_LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"
if [ ! -f "$ISOLATION_HELPER" ]; then
  echo "no isolation helper at $ISOLATION_HELPER" >&2
  echo "set BAIA_DIAGNOSTICS_LIBRARY_ROOT to a checkout containing c43b0a1" >&2
  exit 1
fi

ISOLATED_LABEL=report-expiry
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
# shellcheck source=../lib/isolated-app.sh
source "$ISOLATION_HELPER"
isolated_install_traps
isolated_refuse_pane
isolated_prepare

TOKENS="$ISOLATED_OUT/tokens"
mkdir -p "$TOKENS"
chmod 700 "$ISOLATED_OUT" "$TOKENS"
umask 077

ALPHA=BA1AC0DE-0000-4000-8000-000000000001
BRAVO=BA1AC0DE-0000-4000-8000-000000000002
cat > "$ISOLATED_SESSION" <<EOF
{
  "panes": [
    { "id": { "rawValue": "$ALPHA" }, "workingDirectory": "$ISOLATED_OUT" },
    { "id": { "rawValue": "$BRAVO" }, "workingDirectory": "$ISOLATED_OUT" }
  ],
  "schemaVersion": 1,
  "workspace": {
    "tabs": [
      {
        "id": "BA1AC0DE-0000-4000-8000-0000000000AA",
        "focusedPane": { "rawValue": "$ALPHA" },
        "tree": {
          "split": {
            "axis": "horizontal",
            "ratio": 0.5,
            "first": { "leaf": { "_0": { "rawValue": "$ALPHA" } } },
            "second": { "leaf": { "_0": { "rawValue": "$BRAVO" } } }
          }
        }
      }
    ],
    "focusedTabIndex": 0
  },
  "windowFrame": { "x": 120, "y": 120, "width": 1000, "height": 680 }
}
EOF

cat > "$ISOLATED_CONFIG" <<EOF
{
  "controlChannelEnabled": true,
  "controlAllowRun": false,
  "projectRoots": ["$ISOLATED_OUT"],
  "restoreSession": true,
  "notificationsEnabled": false,
  "activityPollSeconds": 1
}
EOF

# Each real pane writes out the capability the app injected. Bravo then waits in
# a zsh builtin, which leaves the shell idle without spawning a process for the
# activity classifier to mistake for work. The probe creates run-hidden only
# after Alpha has zoomed and expects Bravo's later sleep to be observed while
# Bravo's view is detached.
cat > "$ISOLATED_ZDOT/.zshenv" <<EOF
umask 077
printf 'pane=%s\ntoken=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" > "$TOKENS/pane-\$BAIA_PANE.env"
export HISTFILE=/dev/null
EOF
cat > "$ISOLATED_ZDOT/.zshrc" <<EOF
if [ "\$BAIA_PANE" = "$BRAVO" ]; then
  zmodload zsh/zselect
  while [ ! -e "$ISOLATED_OUT/run-hidden" ]; do
    zselect -t 10
  done
  sleep 6
  while [ ! -e "$ISOLATED_OUT/run-stable" ]; do
    zselect -t 10
  done
  sleep 120
fi
EOF

BAIA_CONFIG_FILE="$ISOLATED_CONFIG" ZDOTDIR="$ISOLATED_ZDOT" \
  "$ISOLATED_BINARY" > "$ISOLATED_EVIDENCE/app.log" 2>&1 &
isolated_record_child "$!"
echo "launched isolated baia as pid $ISOLATED_CHILD_PID"

for _ in $(seq 1 60); do
  reported=$(ls "$TOKENS" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$reported" -ge 2 ] && [ -S "$ISOLATED_SOCKET" ]; then break; fi
  sleep 0.5
done
if [ ! -S "$ISOLATED_SOCKET" ]; then
  echo "no socket at $ISOLATED_SOCKET after 30 seconds. The app's own log:"
  cat "$ISOLATED_EVIDENCE/app.log"
  exit 1
fi
if [ "$(ls "$TOKENS" | wc -l | tr -d ' ')" -lt 2 ]; then
  echo "the panes reported fewer than two capabilities after 30 seconds."
  cat "$ISOLATED_EVIDENCE/app.log"
  exit 1
fi

/usr/bin/python3 -u "$HERE/probe.py" \
  "$ISOLATED_SOCKET" "$TOKENS" "$ISOLATED_SESSION" "$ISOLATED_CONFIG" \
  "$ISOLATED_OUT" "$ISOLATED_EVIDENCE" "$ISOLATED_CHILD_PID" \
  "$ROOT/Diagnostics/control-channel/probe.py" "$ISOLATED_BINARY"
