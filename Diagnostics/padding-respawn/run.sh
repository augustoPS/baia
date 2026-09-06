#!/usr/bin/env bash
# Live padding and material edits against an isolated copy, checking that the
# existing pane keeps its shell (no respawn) while a new pane still opens. Launches a disposable
# app but never takes the keyboard: every control travels on the socket.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"
if [ ! -f "$LIBRARY" ]; then
  echo "padding-respawn needs Diagnostics/lib/isolated-app.sh." >&2
  exit 1
fi

ISOLATED_LABEL=padding-respawn
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1

cd "$ROOT"
if [ "${BAIA_PADDING_RESPAWN_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != 1 ]; then
  make build
fi

isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.tsv"

TOKENS="$ISOLATED_OUT/tokens"
mkdir -p "$TOKENS"
chmod 700 "$ISOLATED_OUT" "$TOKENS"
umask 077

# One pane to churn against. The id is fixed so the probe can address it.
ALPHA=BA1AC0DE-0000-4000-8000-000000000001
mkdir -p "$ISOLATED_SUPPORT"
cat > "$ISOLATED_SESSION" <<EOF
{
  "panes": [ { "id": { "rawValue": "$ALPHA" }, "workingDirectory": "$ISOLATED_OUT" } ],
  "schemaVersion": 1,
  "workspace": {
    "tabs": [ { "id": "BA1AC0DE-0000-4000-8000-0000000000AA",
                "focusedPane": { "rawValue": "$ALPHA" },
                "tree": { "leaf": { "_0": { "rawValue": "$ALPHA" } } } } ],
    "focusedTabIndex": 0
  },
  "windowFrame": { "x": 120, "y": 120, "width": 1000, "height": 640 }
}
EOF
cat > "$ISOLATED_CONFIG" <<EOF
{"controlChannelEnabled":true,"controlAllowRun":false,"restoreSession":true,"notificationsEnabled":false,"projectRoots":["$ISOLATED_OUT"],"sidebar":"off"}
EOF

# Every pane's shell reports its capability the moment it starts, which is how
# the probe learns the token of a pane it just split off.
cat > "$ISOLATED_ZDOT/.zshenv" <<EOF
export HISTFILE=/dev/null
printf 'pane=%s\ntoken=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" > "$TOKENS/pane-\$\$.env"
EOF

isolated_launch "$ISOLATED_EVIDENCE/app.log"
PID="$ISOLATED_CHILD_PID"
echo "isolated pid $PID"
for _ in $(seq 1 60); do
  [ -S "$ISOLATED_SOCKET" ] && [ "$(ls "$TOKENS" | wc -l | tr -d ' ')" -ge 1 ] && break
  sleep 0.5
done
if [ ! -S "$ISOLATED_SOCKET" ]; then
  echo "no socket after 30 seconds; app log:"; cat "$ISOLATED_EVIDENCE/app.log"; exit 1
fi

status=0
/usr/bin/python3 -u "$HERE/probe.py" \
  "$ISOLATED_SOCKET" "$TOKENS" "$PID" "$ALPHA" "$ISOLATED_EVIDENCE" \
  "$ISOLATED_CONFIG" || status=$?

isolated_stop_owned_process || status=1
while IFS= read -r path; do
  printf '%s\t' "$path"
  isolated_fingerprint_one "$path"
done > "$ISOLATED_EVIDENCE/normal-state-after.tsv" <<EOF
$(isolated_normal_paths)
EOF
isolated_fingerprint_check || status=1

if [ "$status" -ne 0 ]; then
  echo "padding-respawn evidence: $ISOLATED_EVIDENCE"
  exit "$status"
fi
echo "padding-respawn: all checks passed"
echo "padding-respawn evidence: $ISOLATED_EVIDENCE"
