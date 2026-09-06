#!/usr/bin/env bash
# Live notification-delivery fixture. It launches a disposable app copy and
# pauses for coordinator-owned OS observation, so never run it inside baia.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
HOLD_SECONDS=${BAIA_NOTIFICATION_PERMISSION_HOLD_SECONDS:-1800}

case "$HOLD_SECONDS" in
  *[!0-9]*|'') echo "hold seconds must be an integer from 60 through 3600" >&2; exit 2 ;;
esac
if [ "$HOLD_SECONDS" -lt 60 ] || [ "$HOLD_SECONDS" -gt 3600 ]; then
  echo "hold seconds must be from 60 through 3600" >&2
  exit 2
fi
if [ ! -f "$LIBRARY" ]; then
  echo "notification-permission needs Diagnostics/lib/isolated-app.sh" >&2
  exit 1
fi
if [ ! -x "$LSREGISTER" ]; then
  echo "Launch Services registrar is unavailable at $LSREGISTER" >&2
  exit 1
fi
if [ ! -d /Users/pasqualotto/Applications ]; then
  echo "the proven notification-capable copy location is missing: /Users/pasqualotto/Applications" >&2
  exit 1
fi

ISOLATED_LABEL=notification-permission
ISOLATED_SOURCE_APP=${BAIA_NOTIFICATION_PERMISSION_SOURCE_APP:-$ROOT/.build/Build/Products/Debug/baia-dev.app}
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1
umask 077

# Keep only the app copy under Applications. Evidence stays in the caller's
# ordinary temporary directory, and TMPDIR returns to its prior value as soon
# as the helper function returns.
ISOLATED_EVIDENCE=$(mktemp -d "$(isolated_scratch_parent)/baia-notification-permission-evidence.XXXXXX")
TMPDIR=/Users/pasqualotto/Applications isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.tsv"

NOTIFICATION_REGISTRATION_ATTEMPTED=0
notification_cleanup() {
  local incoming=$?
  local cleanup_status=0
  local stopped=0

  if isolated_stop_owned_process; then
    stopped=1
  else
    cleanup_status=1
  fi
  if [ "$stopped" -eq 1 ] && [ "$NOTIFICATION_REGISTRATION_ATTEMPTED" -eq 1 ] \
      && [ -d "${ISOLATED_APP:-}" ]; then
    "$LSREGISTER" -u "$ISOLATED_APP" >/dev/null 2>&1 || cleanup_status=1
  fi

  if [ -n "${ISOLATED_EVIDENCE:-}" ] && [ -f "${ISOLATED_FINGERPRINTS:-}" ]; then
    while IFS= read -r path; do
      printf '%s\t' "$path"
      isolated_fingerprint_one "$path"
    done > "$ISOLATED_EVIDENCE/normal-state-after.tsv" <<EOF
$(isolated_normal_paths)
EOF
  fi
  isolated_teardown || cleanup_status=1
  if [ "$incoming" -ne 0 ]; then exit "$incoming"; fi
  if [ "$cleanup_status" -ne 0 ]; then exit 1; fi
  exit 0
}
trap notification_cleanup EXIT

SHORT_RUN=$(printf '%s' "$ISOLATED_RUN_ID" | tr -d '-' | cut -c1-12)
PANE=$(/usr/bin/uuidgen)
TAB=$(/usr/bin/uuidgen)
GROUP=$(/usr/bin/uuidgen)
PROJECT_NAME="R12-notification-$SHORT_RUN"
PROJECT="$ISOLATED_OUT/$PROJECT_NAME"
TOKENS="$ISOLATED_OUT/tokens"
mkdir -p "$PROJECT" "$TOKENS"
chmod 700 "$ISOLATED_OUT" "$PROJECT" "$TOKENS"

cat > "$ISOLATED_SESSION" <<EOF
{
  "schemaVersion": 2,
  "groups": [
    {
      "id": "$GROUP",
      "tabs": [
        {
          "id": "$TAB",
          "focusedPane": { "rawValue": "$PANE" },
          "tree": { "leaf": { "_0": { "rawValue": "$PANE" } } }
        }
      ],
      "selectedTab": "$TAB"
    }
  ],
  "activeGroup": "$GROUP",
  "panes": [
    { "id": { "rawValue": "$PANE" }, "workingDirectory": "$PROJECT" }
  ]
}
EOF

cat > "$ISOLATED_CONFIG" <<EOF
{
  "notificationsEnabled": true,
  "restoreSession": true,
  "controlChannelEnabled": true,
  "controlAllowRun": false,
  "controlAllowRead": true,
  "projectRoots": ["$PROJECT"],
  "sidebar": "off"
}
EOF

# Capabilities are captured only from this copy's shell environment into its
# mode-0700 scratch directory. Neither normal token paths nor normal sessions
# are consulted by the phase driver.
cat > "$ISOLATED_ZDOT/.zshenv" <<EOF
umask 077
printf 'pane=%s\ntoken=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" > "$TOKENS/pane-\$BAIA_PANE.env"
chmod 600 "$TOKENS/pane-\$BAIA_PANE.env"
export HISTFILE=/dev/null
EOF

BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$ISOLATED_APP/Contents/Info.plist")
NOTIFICATION_REGISTRATION_ATTEMPTED=1
"$LSREGISTER" -f "$ISOLATED_APP" >/dev/null
DELIVERY_COMMAND="$ISOLATED_OUT/delivery-command.json"
DELIVERY_RESULT="$ISOLATED_OUT/delivery-result.json"
export BAIA_NOTIFICATION_DELIVERY_COMMAND="$DELIVERY_COMMAND"
export BAIA_NOTIFICATION_DELIVERY_RESULT="$DELIVERY_RESULT"
isolated_launch "$ISOLATED_EVIDENCE/app.log"

STATE="$ISOLATED_EVIDENCE/fixture.json"
REPORT="$ISOLATED_EVIDENCE/report.json"
STOP_MARKER="$ISOLATED_OUT/coordinator-stop"
CONTROL_PROBE="$ROOT/Diagnostics/control-channel/probe.py"

/usr/bin/python3 - "$STATE" "$REPORT" "$ISOLATED_RUN_ID" "$ISOLATED_CHILD_PID" \
  "$ISOLATED_BINARY" "$ISOLATED_APP" "$BUNDLE_ID" "$PROJECT_NAME" "$PANE" \
  "$ISOLATED_SOCKET" "$TOKENS" "$ISOLATED_SESSION" "$ISOLATED_CONFIG" \
  "$ISOLATED_OUT" "$ISOLATED_EVIDENCE" "$STOP_MARKER" "$CONTROL_PROBE" \
  "$DELIVERY_COMMAND" "$DELIVERY_RESULT" <<'PY'
import json
import os
import sys

(state_path, report, run_id, pid, binary, app, bundle_id, project_name, pane,
 socket_path, token_dir, session, config, scratch, evidence, stop_marker,
 control_probe, delivery_command, delivery_result) = sys.argv[1:]
document = {
    "version": 1,
    "runId": run_id,
    "pid": int(pid),
    "binary": binary,
    "app": app,
    "bundleId": bundle_id,
    "projectName": project_name,
    "pane": pane,
    "socket": socket_path,
    "tokenDir": token_dir,
    "session": session,
    "config": config,
    "scratch": scratch,
    "evidence": evidence,
    "report": report,
    "stopMarker": stop_marker,
    "controlProbe": control_probe,
    "deliveryCommand": delivery_command,
    "deliveryResult": delivery_result,
    "nextSequence": 1,
}
descriptor = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

echo "STATE=$STATE"
echo "PID=$ISOLATED_CHILD_PID"
echo "BUNDLE_ID=$BUNDLE_ID"
echo "PROJECT=$PROJECT_NAME"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -u "$HERE/phase.py" --state "$STATE" ready
echo "READY: background PID $ISOLATED_CHILD_PID before every trigger or release-new phase"
echo "PAUSED: use phase.py --state '$STATE' stop when OS observation is complete"

deadline=$((SECONDS + HOLD_SECONDS))
while [ ! -e "$STOP_MARKER" ]; do
  if ! isolated_app_is_running; then
    echo "copied app exited before the coordinator stopped the fixture" >&2
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "coordinator pause exceeded ${HOLD_SECONDS}s; cleaning the exact fixture process" >&2
    exit 124
  fi
  sleep 0.25
done

echo "notification-permission report: $REPORT"
echo "notification-permission evidence: $ISOLATED_EVIDENCE"
