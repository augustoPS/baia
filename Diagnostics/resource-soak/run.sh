#!/usr/bin/env bash
# Resource churn over the control socket of an isolated copy, sampling
# descriptors, resident memory and descendant processes. Launches a disposable
# app but never takes the keyboard: every control travels on the socket.
#
# Two workloads. Split/close churn runs by default (BAIA_RESOURCE_SOAK_ROUNDS,
# 24). Subscription churn runs when BAIA_RESOURCE_SOAK_SUBSCRIBE_BATCHES is set
# above zero: the session is then seeded with four scratch panes beside the
# anchor and each batch parks two `subscribe --wait` clients per scratch pane.
# With batches set, rounds default to zero so the two churns do not share one
# baseline; set both explicitly to run both in one launch.
#
#   BAIA_RESOURCE_SOAK_SKIP_BUILD=1 BAIA_RESOURCE_SOAK_SUBSCRIBE_BATCHES=100 bash Diagnostics/resource-soak/run.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"
if [ ! -f "$LIBRARY" ]; then
  echo "resource-soak needs Diagnostics/lib/isolated-app.sh." >&2
  exit 1
fi

SUBSCRIBE_BATCHES="${BAIA_RESOURCE_SOAK_SUBSCRIBE_BATCHES:-0}"
SUBSCRIBE_WAIT="${BAIA_RESOURCE_SOAK_SUBSCRIBE_WAIT:-2}"
case "$SUBSCRIBE_BATCHES$SUBSCRIBE_WAIT" in
  *[!0-9]*) echo "BAIA_RESOURCE_SOAK_SUBSCRIBE_BATCHES and _WAIT must be whole numbers" >&2; exit 1 ;;
esac
if [ "$SUBSCRIBE_BATCHES" -gt 0 ]; then
  ROUNDS="${BAIA_RESOURCE_SOAK_ROUNDS:-0}"
  SCRATCH_PANES=4
else
  ROUNDS="${BAIA_RESOURCE_SOAK_ROUNDS:-24}"
  SCRATCH_PANES=0
fi
EXPECTED_TOKENS=$((SCRATCH_PANES + 1))

ISOLATED_LABEL=resource-soak
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1

cd "$ROOT"
if [ "${BAIA_RESOURCE_SOAK_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != 1 ]; then
  make build
fi

isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.tsv"

TOKENS="$ISOLATED_OUT/tokens"
mkdir -p "$TOKENS"
chmod 700 "$ISOLATED_OUT" "$TOKENS"
umask 077

# The anchor pane to churn against, plus the scratch panes the subscription
# churn parks on. The ids are fixed in probe.py so it can address them. The
# seed is the current session schema (2), so no first-launch migration lands
# in the samples.
mkdir -p "$ISOLATED_SUPPORT"
/usr/bin/python3 "$HERE/probe.py" seed \
  --session "$ISOLATED_SESSION" --root "$ISOLATED_OUT" --scratch "$SCRATCH_PANES"
cp "$ISOLATED_SESSION" "$ISOLATED_EVIDENCE/session-seed.json"
cat > "$ISOLATED_CONFIG" <<EOF
{"controlChannelEnabled":true,"controlAllowRun":false,"restoreSession":true,"notificationsEnabled":false,"projectRoots":["$ISOLATED_OUT"],"sidebar":"off"}
EOF

# Every pane's shell reports its capability the moment it starts, which is how
# the probe learns the token of a pane it just split off.
cat > "$ISOLATED_ZDOT/.zshenv" <<EOF
export HISTFILE=/dev/null
printf 'pane=%s\ntoken=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" > "$TOKENS/pane-\$\$.env"
EOF

# The one arm. A shell started while `arm-linger` exists holds a known child
# for the leftover-child failure control; the probe plants and removes the file
# around a single split, so no other pane is affected.
cat > "$ISOLATED_ZDOT/.zshrc" <<EOF
if [ -e "$ISOLATED_OUT/arm-linger" ]; then
  sleep 600
fi
EOF

isolated_launch "$ISOLATED_EVIDENCE/app.log"
PID="$ISOLATED_CHILD_PID"
echo "isolated pid $PID"
for _ in $(seq 1 60); do
  [ -S "$ISOLATED_SOCKET" ] && [ "$(ls "$TOKENS" | wc -l | tr -d ' ')" -ge "$EXPECTED_TOKENS" ] && break
  sleep 0.5
done
if [ ! -S "$ISOLATED_SOCKET" ]; then
  echo "no socket after 30 seconds; app log:"; cat "$ISOLATED_EVIDENCE/app.log"; exit 1
fi

status=0
/usr/bin/python3 -u "$HERE/probe.py" run \
  "$ISOLATED_SOCKET" "$TOKENS" "$PID" "$ISOLATED_EVIDENCE" \
  --scratch-dir "$ISOLATED_OUT" \
  --rounds "$ROUNDS" \
  --subscribe-batches "$SUBSCRIBE_BATCHES" \
  --subscribe-wait "$SUBSCRIBE_WAIT" || status=$?

isolated_stop_owned_process || status=1
while IFS= read -r path; do
  printf '%s\t' "$path"
  isolated_fingerprint_one "$path"
done > "$ISOLATED_EVIDENCE/normal-state-after.tsv" <<EOF
$(isolated_normal_paths)
EOF
isolated_fingerprint_check || status=1

if [ "$status" -ne 0 ]; then
  echo "resource-soak evidence: $ISOLATED_EVIDENCE"
  exit "$status"
fi
echo "resource-soak: all checks passed"
echo "resource-soak evidence: $ISOLATED_EVIDENCE"
