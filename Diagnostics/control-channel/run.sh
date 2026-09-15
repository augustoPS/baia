#!/bin/bash
# Builds baia unless the coordinator already did, launches an isolated copy,
# and exercises the control channel over that copy's real socket.
#
# Every control goes through the socket. probe.py writes bytes to the isolated
# instance's $BAIA_SOCK and reads bytes back. Nothing here writes the owner's
# config, session, or acknowledgement; those paths are hashed before and after.
#
# How to check that a control can fail: damage PaneGraph.authorize so it also
# resolves a pane id, run this, watch the pane-id controls answer ok, put it
# back. See the README.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"

if [ -n "${BAIA_PANE:-}" ]; then
  echo "control-channel launches an app that takes focus. Run it outside a baia pane."
  exit 1
fi

if [ "${BAIA_CONTROL_CHANNEL_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != "1" ]; then
  make build
fi

ISOLATED_LABEL=control-channel
# shellcheck source=../lib/isolated-app.sh
source "$ROOT/Diagnostics/lib/isolated-app.sh"
isolated_install_traps
isolated_prepare

TOKENS="$ISOLATED_OUT/tokens"
SHELLS="$ISOLATED_OUT/shells"
mkdir -p "$TOKENS" "$SHELLS"
chmod 700 "$ISOLATED_OUT" "$TOKENS" "$SHELLS"
umask 077

# Three panes, because the scope arms need panes that alpha is not entitled to
# see. The ids are fixed so a failure names something a reader can grep for, and
# they are read back out of this file by the probe: the pane-id-as-token control
# has to use an id that a same-uid process could find on disk.
ALPHA=BA1AC0DE-0000-4000-8000-000000000001
BRAVO=BA1AC0DE-0000-4000-8000-000000000002
CHARLIE=BA1AC0DE-0000-4000-8000-000000000003

mkdir -p "$ISOLATED_SUPPORT"
cat > "$ISOLATED_SESSION" <<EOF
{
  "panes": [
    { "id": { "rawValue": "$ALPHA" }, "workingDirectory": "$ISOLATED_OUT" },
    { "id": { "rawValue": "$BRAVO" }, "workingDirectory": "$ISOLATED_OUT" },
    { "id": { "rawValue": "$CHARLIE" }, "workingDirectory": "$ISOLATED_OUT" }
  ],
  "schemaVersion": 1,
  "sidebar": { "splitHeight": 48, "width": 320 },
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
            "second": {
              "split": {
                "axis": "vertical",
                "ratio": 0.5,
                "first": { "leaf": { "_0": { "rawValue": "$BRAVO" } } },
                "second": { "leaf": { "_0": { "rawValue": "$CHARLIE" } } }
              }
            }
          }
        }
      }
    ],
    "focusedTabIndex": 0
  },
  "windowFrame": { "x": 120, "y": 120, "width": 1100, "height": 720 }
}
EOF

# Current contract: run stays disabled until both controlAllowRun and this
# installation's acknowledgement marker are set. The isolated support directory
# is empty, so without seeding the marker the existing "disabled → refused"
# checks would see disabled forever and look like a Settings regression.
isolated_acknowledge

cat > "$ISOLATED_CONFIG" <<EOF
{
  "controlChannelEnabled": true,
  "controlAllowRun": false,
  "restoreSession": true,
  "notificationsEnabled": false,
  "projectRoots": ["$ISOLATED_OUT"]
}
EOF

# The readout. .zshenv is read by every zsh, login or not, before anything
# else, so a pane reports its capability the moment its shell starts.
cat > "$ISOLATED_ZDOT/.zshenv" <<EOF
export HISTFILE=/dev/null
printf 'pane=%s\ntoken=%s\nsock=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" "\$BAIA_SOCK" \
  > "$TOKENS/pane-\$\$.env"
EOF

# .zshrc runs after path_helper. whoami is retried: a shell that starts in the
# same turn a sibling is closed can see badToken (exit 13) once, then succeed.
cat > "$ISOLATED_ZDOT/.zshrc" <<EOF
if [ -e "$ISOLATED_OUT/arm-churn" ]; then
  baia close > /dev/null 2>&1
fi
if [ -e "$ISOLATED_OUT/arm-activity" ]; then
  sleep 45
fi

whoami_exit=13
i=0
while [ \$i -lt 15 ]; do
  baia whoami > /dev/null 2>&1
  whoami_exit=\$?
  [ "\$whoami_exit" = "0" ] && break
  sleep 0.2
  i=\$((i + 1))
done

{
  printf 'pane=%s\n' "\$BAIA_PANE"
  printf 'which=%s\n' "\$(command -v baia 2> /dev/null || echo NOT-ON-PATH)"
  printf 'whoami_exit=%s\n' "\$whoami_exit"
} > "$SHELLS/pane-\$\$.env" 2>&1
EOF

isolated_launch
echo "launched isolated baia as pid $ISOLATED_CHILD_PID"

for _ in $(seq 1 60); do
  reported=$(ls "$TOKENS" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$reported" -ge 3 ] && [ -S "$ISOLATED_SOCKET" ]; then break; fi
  sleep 0.5
done
if [ ! -S "$ISOLATED_SOCKET" ]; then
  echo "no socket at $ISOLATED_SOCKET after 30 seconds. The app's own log:"
  cat "$ISOLATED_EVIDENCE/app.log"
  exit 1
fi
if [ "$(ls "$TOKENS" | wc -l | tr -d ' ')" -lt 3 ]; then
  echo "the panes reported fewer than three capabilities after 30 seconds."
  echo "the app's own log:"
  cat "$ISOLATED_EVIDENCE/app.log"
  exit 1
fi

echo
/usr/bin/python3 -u "$HERE/probe.py" \
  "$ISOLATED_SOCKET" "$TOKENS" "$ISOLATED_CONFIG" "$ISOLATED_SESSION" \
  "$SHELLS" "$ISOLATED_OUT"
