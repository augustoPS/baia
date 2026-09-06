#!/usr/bin/env bash
# Focus latency over the control socket at several pane counts, for W02: does
# moving focus cost more as the window holds more panes? Launches disposable
# copies; every control travels on the socket, so it never takes the keyboard.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"
[ -f "$LIBRARY" ] || { echo "focus-churn needs Diagnostics/lib/isolated-app.sh." >&2; exit 1; }

ISOLATED_LABEL=focus-churn
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1

cd "$ROOT"
if [ "${BAIA_FOCUS_CHURN_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != 1 ]; then
  make build
fi

isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.tsv"

TOKENS="$ISOLATED_OUT/tokens"
mkdir -p "$TOKENS"
chmod 700 "$ISOLATED_OUT" "$TOKENS"
umask 077
cat > "$ISOLATED_CONFIG" <<EOF
{"controlChannelEnabled":true,"controlAllowRun":false,"restoreSession":true,"notificationsEnabled":false,"projectRoots":["$ISOLATED_OUT"],"sidebar":"off"}
EOF
cat > "$ISOLATED_ZDOT/.zshenv" <<EOF
export HISTFILE=/dev/null
printf 'pane=%s\ntoken=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" > "$TOKENS/pane-\$\$.env"
EOF

status=0
LAUNCHES=0
for count in ${BAIA_FOCUS_CHURN_PANES:-2 6 12}; do
  rm -f "$TOKENS"/*.env
  /usr/bin/python3 "$HERE/probe.py" seed "$ISOLATED_SESSION" "$ISOLATED_OUT" "$count"
  log="$ISOLATED_EVIDENCE/panes-$count-app.log"
  if [ "$LAUNCHES" -eq 0 ]; then isolated_launch "$log"; else isolated_relaunch "$log"; fi
  LAUNCHES=$((LAUNCHES + 1))
  for _ in $(seq 1 80); do
    [ -S "$ISOLATED_SOCKET" ] && [ "$(ls "$TOKENS" | wc -l | tr -d ' ')" -ge "$count" ] && break
    sleep 0.5
  done
  echo "== $count panes (pid $ISOLATED_CHILD_PID)"
  /usr/bin/python3 -u "$HERE/probe.py" measure "$ISOLATED_SOCKET" "$TOKENS" "$count" \
    "$ISOLATED_EVIDENCE/panes-$count-report.json" "${BAIA_FOCUS_CHURN_MOVES:-120}" || status=1
done
isolated_stop_owned_process || status=1

/usr/bin/python3 "$HERE/probe.py" compare "$ISOLATED_EVIDENCE" ${BAIA_FOCUS_CHURN_PANES:-2 6 12} || status=1

while IFS= read -r path; do
  printf '%s\t' "$path"
  isolated_fingerprint_one "$path"
done > "$ISOLATED_EVIDENCE/normal-state-after.tsv" <<EOF
$(isolated_normal_paths)
EOF
isolated_fingerprint_check || status=1

if [ "$status" -ne 0 ]; then
  echo "focus-churn evidence: $ISOLATED_EVIDENCE"
  exit "$status"
fi
echo "focus-churn: all checks passed"
echo "focus-churn evidence: $ISOLATED_EVIDENCE"
