#!/usr/bin/env bash
# Real-app fixture for the close policy (W01): closing over a running job asks
# first, Cancel keeps the job, Confirm ends it. Activates a disposable app, so
# run it only outside a baia pane.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"
if [ ! -f "$LIBRARY" ]; then
  echo "busy-close needs Diagnostics/lib/isolated-app.sh." >&2
  exit 1
fi

# The support directory becomes baia-busy-close.XXXXXX, the prefix
# CloseSelfCheck requires.
ISOLATED_LABEL=busy-close
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1

cd "$ROOT"
if [ "${BAIA_BUSY_CLOSE_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != 1 ]; then
  make build
fi

isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.tsv"
cat > "$ISOLATED_CONFIG" <<EOF
{"controlChannelEnabled":false,"notificationsEnabled":false,"projectRoots":["$ISOLATED_OUT"],"restoreSession":false,"sidebar":"off"}
EOF

# The job under test. While the marker exists every new shell runs a foreground
# sleep and records its pid, so the fixture can check from outside that a
# confirmed close ended it.
JOBS="$ISOLATED_OUT/jobs"
mkdir -p "$JOBS"
cat > "$ISOLATED_ZDOT/.zshrc" <<EOF
if [ -e "$ISOLATED_OUT/arm-busy" ]; then
  sleep 300 &
  echo \$! > "$JOBS/sleep-\$\$.pid"
  fg %1 > /dev/null 2>&1
fi
EOF

status=0
LAUNCHES=0
run_phase() {
  local mode="$1" arm="$2"
  local events="$ISOLATED_EVIDENCE/$mode-events.log"
  rm -f "$JOBS"/*.pid
  if [ "$arm" = 1 ]; then touch "$ISOLATED_OUT/arm-busy"; else rm -f "$ISOLATED_OUT/arm-busy"; fi
  export BAIA_CLOSE_SELFCHECK_MODE="$mode"
  export BAIA_CLOSE_SELFCHECK_OUTPUT="$events"
  if [ "$LAUNCHES" -eq 0 ]; then isolated_launch "$ISOLATED_EVIDENCE/$mode-app.log"; else isolated_relaunch "$ISOLATED_EVIDENCE/$mode-app.log"; fi
  LAUNCHES=$((LAUNCHES + 1))
  local pid="$ISOLATED_CHILD_PID" exit_status=0
  for _ in $(seq 1 160); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "FAIL $mode: isolated app did not finish within 40 seconds" >&2
    isolated_stop_owned_process || true
    exit_status=1
  else
    wait "$pid" || exit_status=$?
  fi
  unset BAIA_CLOSE_SELFCHECK_MODE BAIA_CLOSE_SELFCHECK_OUTPUT
  echo "== $mode (exit $exit_status)"
  sed 's/^/  /' "$events" 2>/dev/null || { echo "FAIL $mode: no events" >&2; return 1; }
  [ "$exit_status" -eq 0 ] || return 1
  grep -q '^self-check failures=0$' "$events" || { echo "FAIL $mode: driver reported failures" >&2; return 1; }
  # The job the shell recorded must be gone once the app exited.
  local job
  for job in "$JOBS"/*.pid; do
    [ -f "$job" ] || continue
    local jpid
    jpid=$(cat "$job")
    if kill -0 "$jpid" 2>/dev/null; then
      echo "FAIL $mode: foreground job $jpid survived the confirmed close" >&2
      kill -TERM "$jpid" 2>/dev/null || true
      return 1
    fi
    echo "  job $jpid ended with the pane"
  done
}

run_phase busy-pane 1 || status=1
grep -q '^window-closed$' "$ISOLATED_EVIDENCE/busy-pane-events.log" || { echo "FAIL busy-pane: confirmed close did not close the window" >&2; status=1; }
run_phase busy-quit 1 || status=1
run_phase idle-pane 0 || status=1
grep -q '^closed-without-sheet$' "$ISOLATED_EVIDENCE/idle-pane-events.log" || { echo "FAIL idle-pane: an idle pane asked before closing" >&2; status=1; }
grep -q '^window-closed$' "$ISOLATED_EVIDENCE/idle-pane-events.log" || { echo "FAIL idle-pane: the window did not close" >&2; status=1; }

while IFS= read -r path; do
  printf '%s\t' "$path"
  isolated_fingerprint_one "$path"
done > "$ISOLATED_EVIDENCE/normal-state-after.tsv" <<EOF
$(isolated_normal_paths)
EOF
isolated_fingerprint_check || status=1

if [ "$status" -ne 0 ]; then
  echo "busy-close evidence: $ISOLATED_EVIDENCE"
  exit "$status"
fi
echo "busy-close: all native and durable checks passed"
echo "busy-close evidence: $ISOLATED_EVIDENCE"
