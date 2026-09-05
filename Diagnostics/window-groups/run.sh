#!/usr/bin/env bash
# Drive the Debug-only native window-group self-check through four real launches.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"

if [ ! -f "$LIBRARY" ]; then
  echo "window-groups needs Diagnostics/lib/isolated-app.sh." >&2
  echo "Set BAIA_DIAGNOSTICS_LIBRARY_ROOT to the checkout that owns the shared helper." >&2
  exit 1
fi

ISOLATED_LABEL=window-groups
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane

cd "$ROOT"
if [ "${BAIA_WINDOW_GROUPS_SKIP_BUILD:-0}" != 1 ]; then
  make build
fi

isolated_prepare
isolated_default_config files

V1_SOURCE="$ISOLATED_EVIDENCE/v1-source.json"
BACKUP="$ISOLATED_SESSION.v1-backup"
LAUNCH_NUMBER=0

run_phase() {
  local name="$1" mode="$2"
  local events="$ISOLATED_EVIDENCE/$name-events.log"
  local log="$ISOLATED_EVIDENCE/$name-app.log"
  export BAIA_WINDOW_GROUP_SELFCHECK_MODE="$mode"
  export BAIA_WINDOW_GROUP_SELFCHECK_OUTPUT="$events"
  if [ "$LAUNCH_NUMBER" -eq 0 ]; then
    isolated_launch "$log"
  else
    isolated_relaunch "$log"
  fi
  LAUNCH_NUMBER=$((LAUNCH_NUMBER + 1))
  local pid="$ISOLATED_CHILD_PID" status=0
  local attempt
  for attempt in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "FAIL $name: isolated app did not finish within 30 seconds" >&2
    isolated_stop_owned_process || true
    unset BAIA_WINDOW_GROUP_SELFCHECK_MODE BAIA_WINDOW_GROUP_SELFCHECK_OUTPUT
    return 1
  fi
  wait "$pid" || status=$?
  unset BAIA_WINDOW_GROUP_SELFCHECK_MODE BAIA_WINDOW_GROUP_SELFCHECK_OUTPUT
  if [ "$status" -ne 0 ]; then
    echo "FAIL $name: isolated app exited $status" >&2
    return "$status"
  fi
  if ! grep -q '^self-check failures=0$' "$events"; then
    echo "FAIL $name: Debug self-check did not finish cleanly" >&2
    return 1
  fi
}

grade_phase() {
  local phase="$1" events="$2"
  local extra=()
  if [ "$phase" = arranged ]; then
    extra=(--source "$V1_SOURCE" --backup "$BACKUP")
  fi
  /usr/bin/python3 "$HERE/probe.py" grade \
    --phase "$phase" \
    --session "$ISOLATED_SESSION" \
    --events "$ISOLATED_EVIDENCE/$events-events.log" \
    --evidence "$ISOLATED_EVIDENCE" \
    "${extra[@]}"
}

/usr/bin/python3 "$HERE/probe.py" seed-v1 \
  --session "$ISOLATED_SESSION" \
  --source "$V1_SOURCE" \
  --root "$ISOLATED_OUT"

run_phase arrange arrange
grade_phase arranged arrange

run_phase mutate verify-arranged-and-mutate
grade_phase mutated mutate

run_phase restored verify-mutated
grade_phase restored restored

/usr/bin/python3 "$HERE/probe.py" seed-missing \
  --session "$ISOLATED_SESSION" \
  --root "$ISOLATED_OUT"
run_phase missing verify-missing-repair
grade_phase missing missing

/usr/bin/python3 "$HERE/probe.py" finalize \
  --binary "$ISOLATED_BINARY" \
  --evidence "$ISOLATED_EVIDENCE"

echo "window-groups: all native and durable checks passed"
echo "window-groups evidence: $ISOLATED_EVIDENCE"
