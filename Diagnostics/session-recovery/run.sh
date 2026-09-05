#!/bin/bash
# Real-app regression fixture for rejected session preservation. This probe
# activates its disposable app, so run it only outside a baia pane.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/baia-session-recovery.XXXXXX")
EVIDENCE="${TMPDIR:-/tmp}/baia-session-recovery-evidence-$$"
APP="$OUT/baia-session-recovery.app"
SUPPORT_NAME="baia-session-recovery-$$"
SUPPORT="$HOME/Library/Application Support/$SUPPORT_NAME"
CONFIG="$OUT/config.json"
ZDOT="$OUT/zdot"
PROBE_PID=

cleanup() {
  status=$?
  if [ -n "$PROBE_PID" ] && kill -0 "$PROBE_PID" 2> /dev/null; then
    kill -TERM "$PROBE_PID" 2> /dev/null || true
    wait "$PROBE_PID" 2> /dev/null || true
  fi
  # Last-resort interruption cleanup. The file contains only the exact PID
  # started by probe.py and is removed after each normal exit.
  if [ -f "$OUT/app.pid" ]; then
    app_pid=$(cat "$OUT/app.pid")
    case "$app_pid" in
      *[!0-9]*|'') ;;
      *) kill -KILL "$app_pid" 2> /dev/null || true ;;
    esac
  fi
  chmod 700 "$SUPPORT" 2> /dev/null || true
  rm -rf "$SUPPORT" "$OUT"
  echo "session-recovery evidence: $EVIDENCE"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${BAIA_PANE:-}" ]; then
  echo "session-recovery launches an app that takes focus. Run it outside a baia pane."
  exit 1
fi

cd "$ROOT"
if [ "${BAIA_SESSION_RECOVERY_SKIP_BUILD:-0}" != "1" ]; then
  make build
fi

mkdir -p "$ZDOT" "$EVIDENCE"
cat > "$ZDOT/.zshenv" <<'EOF'
export HISTFILE=/dev/null
EOF

# The copy has its own bundle identity and Application Support directory. The
# ad-hoc signature is required after changing the signed Info.plist.
/usr/bin/ditto "$SOURCE_APP" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier pasqualotto.baia.session-recovery.$$" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName baia-session-recovery" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BAIASupportDirectory $SUPPORT_NAME" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null

if [ "${BAIA_SESSION_RECOVERY_HOLD:-0}" = "1" ]; then
  mkdir -p "$SUPPORT"
  printf '%s' '{ broken session, preserve me' > "$SUPPORT/session.json"
  cat > "$CONFIG" <<EOF
{"controlChannelEnabled":false,"notificationsEnabled":false,"projectRoots":["$OUT"],"restoreSession":true}
EOF
  BAIA_CONFIG_FILE="$CONFIG" ZDOTDIR="$ZDOT" \
    "$APP/Contents/MacOS/baia-dev" > "$EVIDENCE/held-app.log" 2>&1 &
  PROBE_PID=$!
  echo "HELD_PID=$PROBE_PID"
  echo "HELD_SUPPORT=$SUPPORT"
  echo "HELD_SESSION=$SUPPORT/session.json"
  echo "HELD_CONFIG=$CONFIG"
  echo "HELD_SOURCE_HEX=7b2062726f6b656e2073657373696f6e2c207072657365727665206d65"
  wait "$PROBE_PID"
  PROBE_PID=
  exit 0
fi

/usr/bin/python3 -u "$HERE/probe.py" \
  "$APP/Contents/MacOS/baia-dev" "$SUPPORT" "$CONFIG" "$ZDOT" "$OUT" "$EVIDENCE" \
  "$HOME/.config/baia/config.json" \
  "$HOME/Library/Application Support/baia/session.json" \
  "$HOME/Library/Application Support/baia-dev/session.json" \
  "$HOME/Library/Application Support/baia/command-execution.ack" \
  "$HOME/Library/Application Support/baia-dev/command-execution.ack" &
PROBE_PID=$!
wait "$PROBE_PID"
PROBE_PID=
