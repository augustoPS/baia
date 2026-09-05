#!/usr/bin/env bash
# Real-app regression fixture for rejected session preservation. This probe
# activates its disposable app, so run it only outside a baia pane.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"

if [ ! -f "$LIBRARY" ]; then
  echo "session-recovery needs Diagnostics/lib/isolated-app.sh." >&2
  echo "Set BAIA_DIAGNOSTICS_LIBRARY_ROOT to the checkout that owns the shared helper." >&2
  exit 1
fi

# The longer label keeps SessionSelfCheck's existing baia-session-recovery-
# safety prefix while the helper adds a unique suffix for every run.
ISOLATED_LABEL=session-recovery-probe
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1

cd "$ROOT"
if [ "${BAIA_SESSION_RECOVERY_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != 1 ]; then
  make build
fi

isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.tsv"

if [ "${BAIA_SESSION_RECOVERY_HOLD:-0}" = 1 ]; then
  printf '%s' '{ broken session, preserve me' > "$ISOLATED_SESSION"
  cat > "$ISOLATED_CONFIG" <<EOF
{"controlChannelEnabled":false,"notificationsEnabled":false,"projectRoots":["$ISOLATED_OUT"],"restoreSession":true}
EOF
  isolated_launch "$ISOLATED_EVIDENCE/held-app.log"
  echo "HELD_PID=$ISOLATED_CHILD_PID"
  echo "HELD_SUPPORT=$ISOLATED_SUPPORT"
  echo "HELD_SESSION=$ISOLATED_SESSION"
  echo "HELD_CONFIG=$ISOLATED_CONFIG"
  echo "HELD_SOURCE_HEX=7b2062726f6b656e2073657373696f6e2c207072657365727665206d65"
  wait "$ISOLATED_CHILD_PID"
  exit 0
fi

probe_status=0
/usr/bin/python3 -u "$HERE/probe.py" \
  "$ISOLATED_BINARY" "$ISOLATED_SUPPORT" "$ISOLATED_CONFIG" \
  "$ISOLATED_ZDOT" "$ISOLATED_OUT" "$ISOLATED_EVIDENCE" || probe_status=$?

while IFS= read -r path; do
  printf '%s\t' "$path"
  isolated_fingerprint_one "$path"
done > "$ISOLATED_EVIDENCE/normal-state-after.tsv" <<EOF
$(isolated_normal_paths)
EOF
fingerprint_status=0
isolated_fingerprint_check || fingerprint_status=$?

if [ "$probe_status" -ne 0 ]; then
  exit "$probe_status"
fi
if [ "$fingerprint_status" -ne 0 ]; then
  exit "$fingerprint_status"
fi

echo "session-recovery: all native and durable checks passed"
echo "session-recovery evidence: $ISOLATED_EVIDENCE"
