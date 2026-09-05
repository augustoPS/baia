#!/usr/bin/env bash
# Reusable disposable baia instance for Diagnostics probes.
#
# Sourced, not run. The caller sets ROOT to the repository and ISOLATED_LABEL
# to a short name (control-channel, settings-window), then:
#
#   source "$ROOT/Diagnostics/lib/isolated-app.sh"
#   isolated_install_traps
#   isolated_prepare
#
# Traps are installed before prepare so a failure or interrupt during copy still
# removes this run's directories. A static test sources the file and calls
# isolated_prepare / isolated_teardown itself, and must not install the EXIT trap
# (isolated_cleanup exits the process).
#
# The copy gets a unique bundle identifier, a uniquely renamed executable,
# and matching CFBundleExecutable / CFBundleName / CFBundleDisplayName (so AX
# process name and every display/localized identity are not `baia-dev` and not
# shared with another copy), plus an exclusively created Application Support
# directory (mktemp, never a PID-only name). The source app is never rewritten.
# Cleanup signals only a recorded PID whose live command still matches this
# copy's binary, TERM then bounded wait, KILL only if it is still that binary,
# then a bounded wait to reap. It never blocks on wait after the KILL bound
# fails. It deletes only directories this invocation created, identified by a
# per-run marker. It never names a process and never writes the owner's config,
# session, or acknowledgement.
#
# Exports:
#   ISOLATED_OUT ISOLATED_APP ISOLATED_BINARY ISOLATED_SUPPORT
#   ISOLATED_SUPPORT_NAME ISOLATED_CONFIG ISOLATED_SESSION ISOLATED_SOCKET
#   ISOLATED_ZDOT ISOLATED_EVIDENCE ISOLATED_PID_FILE ISOLATED_RUN_ID
#   ISOLATED_SOURCE_APP
#
# Functions: isolated_install_traps, isolated_prepare, isolated_acknowledge,
# isolated_record_child, isolated_launch, isolated_relaunch, isolated_default_config,
# isolated_refuse_pane, isolated_app_is_running, isolated_fingerprint_save,
# isolated_fingerprint_check, isolated_teardown, isolated_cleanup.
set -uo pipefail

: "${ROOT:?isolated-app.sh needs ROOT set to the repository root}"
: "${ISOLATED_LABEL:?isolated-app.sh needs ISOLATED_LABEL set to a probe name}"

ISOLATED_SOURCE_APP="${ISOLATED_SOURCE_APP:-$ROOT/.build/Build/Products/Debug/baia-dev.app}"
ISOLATED_MARKER_NAME=".baia-isolated-run"

isolated_install_traps() {
  trap isolated_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

isolated_normal_paths() {
  printf '%s\n' \
    "$HOME/.config/baia/config.json" \
    "$HOME/Library/Application Support/baia/session.json" \
    "$HOME/Library/Application Support/baia-dev/session.json" \
    "$HOME/Library/Application Support/baia/command-execution.ack" \
    "$HOME/Library/Application Support/baia-dev/command-execution.ack"
}

isolated_fingerprint_one() {
  local path="$1"
  if [ -f "$path" ]; then
    printf 'present\t%s\n' "$(/usr/bin/shasum -a 256 "$path" | awk '{print $1}')"
  else
    printf 'absent\t\n'
  fi
}

isolated_fingerprint_save() {
  : > "$ISOLATED_FINGERPRINTS"
  local path
  while IFS= read -r path; do
    printf '%s\t' "$path" >> "$ISOLATED_FINGERPRINTS"
    isolated_fingerprint_one "$path" >> "$ISOLATED_FINGERPRINTS"
  done <<EOF
$(isolated_normal_paths)
EOF
}

isolated_fingerprint_check() {
  local path saved now
  local failed=0
  while IFS= read -r path; do
    saved=$(awk -F '\t' -v p="$path" '$1 == p { print $2 "\t" $3 }' "$ISOLATED_FINGERPRINTS")
    now=$(isolated_fingerprint_one "$path")
    if [ "$saved" != "$now" ]; then
      echo "FAIL normal state changed: $path" >&2
      failed=1
    fi
  done <<EOF
$(isolated_normal_paths)
EOF
  return $failed
}

# macOS TMPDIR is `/var/folders/…/T/` with a trailing slash. Concatenating
# `$TMPDIR/baia-…` produces `T//baia-…`, which reaches PATH as a doubled
# separator and fails the control-channel helper assertion.
isolated_scratch_parent() {
  local parent="${TMPDIR:-/tmp}"
  while [ "$parent" != "/" ] && [ "${parent%/}" != "$parent" ]; do
    parent="${parent%/}"
  done
  printf '%s' "$parent"
}

isolated_new_run_id() {
  if [ -x /usr/bin/uuidgen ]; then
    /usr/bin/uuidgen
  else
    mktemp -u XXXXXXXX
  fi
}

isolated_mark() {
  printf '%s\n' "$ISOLATED_RUN_ID" > "$1/$ISOLATED_MARKER_NAME"
}

isolated_owned_dir() {
  local path="$1"
  [ -n "$path" ] && [ -d "$path" ] || return 1
  [ -f "$path/$ISOLATED_MARKER_NAME" ] || return 1
  [ "$(cat "$path/$ISOLATED_MARKER_NAME")" = "$ISOLATED_RUN_ID" ] || return 1
  return 0
}

# Delete only a directory this invocation created. Refuses baia, baia-dev, and
# any path whose marker is missing or belongs to another run.
isolated_rm_owned() {
  local path="$1" expected="$2"
  [ -n "$path" ] || return 0
  [ -e "$path" ] || return 0
  if [ -n "$expected" ] && [ "$path" != "$expected" ]; then
    echo "refusing to delete $path: not this invocation's path" >&2
    return 1
  fi
  local base
  base=$(basename "$path")
  case "$base" in
    baia|baia-dev)
      echo "refusing to delete product support directory $path" >&2
      return 1
      ;;
  esac
  if ! isolated_owned_dir "$path"; then
    echo "refusing to delete $path: missing or foreign isolation marker" >&2
    return 1
  fi
  chmod -R u+w "$path" 2>/dev/null || true
  rm -rf "$path"
}

# One-time confirmation the isolated install has read what controlAllowRun
# means. Without this file, flipping the key leaves `run` answering `disabled`
# because AppDelegate.effectiveAllowRun requires both the key and the marker.
isolated_acknowledge() {
  mkdir -p "$ISOLATED_SUPPORT"
  isolated_mark "$ISOLATED_SUPPORT"
  printf 'acknowledged 2026-01-01T00:00:00Z\n' > "$ISOLATED_SUPPORT/command-execution.ack"
  chmod 600 "$ISOLATED_SUPPORT/command-execution.ack"
}

isolated_process_args() {
  /bin/ps -p "$1" -www -o args= 2>/dev/null | sed 's/^ *//'
}

isolated_process_is_binary() {
  local pid="$1" want="$2"
  [ -n "$want" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local args
  args=$(isolated_process_args "$pid")
  [ -n "$args" ] || return 1
  [ "$args" = "$want" ] && return 0
  local rest="${args#"$want "}"
  [ "$rest" != "$args" ] && return 0
  return 1
}

isolated_wait_exit() {
  local pid="$1" tries="${2:-20}"
  local i=0
  while [ "$i" -lt "$tries" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

isolated_record_child() {
  ISOLATED_CHILD_PID="$1"
  printf '%s\n%s\n' "$ISOLATED_CHILD_PID" "$ISOLATED_BINARY" > "$ISOLATED_PID_FILE"
}

isolated_refuse_pane() {
  if [ -n "${BAIA_PANE:-}" ]; then
    echo "$ISOLATED_LABEL launches an app that takes focus. Run it outside a baia pane." >&2
    return 1
  fi
  return 0
}

isolated_default_config() {
  local sidebar="${1:-off}"
  if [ -z "${ISOLATED_CONFIG:-}" ]; then
    echo "isolated_default_config: ISOLATED_CONFIG is not set" >&2
    return 1
  fi
  cat > "$ISOLATED_CONFIG" <<EOF
{
  "notificationsEnabled": false,
  "restoreSession": true,
  "controlChannelEnabled": true,
  "controlAllowRun": false,
  "sidebar": "$sidebar",
  "projectRoots": ["$ISOLATED_OUT"]
}
EOF
}

# Launch the copied binary with this run's config and ZDOTDIR. Does not go
# through `open`, which would drop ZDOTDIR. Optional first argument is the
# app log path. mkdir and log-file open are checked synchronously before
# spawning, so a permission or path failure does not leave a child running
# with a closed stdout. Returns 1 if the binary is missing, the log cannot
# be opened, or the child pid is already gone, so callers without `set -e`
# can abort before driving the UI.
#
# The kill -0 after spawn is immediate liveness only: the pid still exists.
# It is not readiness. The copy may not yet have a window, a socket, or an
# AX process.
isolated_launch() {
  local log="${1:-$ISOLATED_EVIDENCE/app.log}"
  if [ -z "${ISOLATED_BINARY:-}" ] || [ ! -x "$ISOLATED_BINARY" ]; then
    echo "isolated_launch: no executable at ${ISOLATED_BINARY:-}" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$log")" "$ISOLATED_EVIDENCE"; then
    echo "isolated_launch: cannot create log directory for $log" >&2
    return 1
  fi
  if ! : >>"$log"; then
    echo "isolated_launch: cannot open log file $log" >&2
    return 1
  fi
  BAIA_CONFIG_FILE="$ISOLATED_CONFIG" ZDOTDIR="$ISOLATED_ZDOT" \
    "$ISOLATED_BINARY" >>"$log" 2>&1 &
  isolated_record_child "$!"
  # Immediate liveness only, not readiness (window / socket / AX).
  if ! kill -0 "$ISOLATED_CHILD_PID" 2>/dev/null; then
    wait "$ISOLATED_CHILD_PID" 2>/dev/null || true
    echo "isolated_launch: copied binary exited immediately" >&2
    return 1
  fi
  return 0
}

isolated_relaunch() {
  isolated_stop_owned_process || {
    if [ "${ISOLATED_PROCESS_RETAINED:-0}" = 1 ]; then
      echo "previous isolated process still alive; not relaunching" >&2
      return 1
    fi
  }
  sleep 1.5
  isolated_launch "$@"
}

isolated_app_is_running() {
  [ -n "${ISOLATED_CHILD_PID:-}" ] && kill -0 "$ISOLATED_CHILD_PID" 2>/dev/null
}

# Signal only if the live command still is this copy's binary. TERM, bounded
# wait, KILL only while that is still true, then a bounded wait. A dead pid is
# reaped and never killed. If it is still this binary after the KILL bound,
# return 1 and leave the pid file so teardown retains the app and support.
isolated_stop_owned_process() {
  ISOLATED_PROCESS_RETAINED=0
  local pid="" want="${ISOLATED_BINARY:-}"
  if [ -f "${ISOLATED_PID_FILE:-}" ]; then
    pid=$(sed -n '1p' "$ISOLATED_PID_FILE")
    local recorded
    recorded=$(sed -n '2p' "$ISOLATED_PID_FILE")
    [ -n "$recorded" ] && want="$recorded"
  fi
  if [ -z "$pid" ] && [ -n "${ISOLATED_CHILD_PID:-}" ]; then
    pid="$ISOLATED_CHILD_PID"
  fi
  case "$pid" in
    *[!0-9]*|'') 
      rm -f "${ISOLATED_PID_FILE:-}"
      return 0
      ;;
  esac

  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    rm -f "${ISOLATED_PID_FILE:-}"
    return 0
  fi

  if ! isolated_process_is_binary "$pid" "$want"; then
    echo "refusing to signal pid $pid: live command is not the isolated binary" >&2
    rm -f "${ISOLATED_PID_FILE:-}"
    return 0
  fi

  kill -TERM "$pid" 2>/dev/null || true
  if isolated_wait_exit "$pid" 20; then
    rm -f "${ISOLATED_PID_FILE:-}"
    return 0
  fi

  if isolated_process_is_binary "$pid" "$want"; then
    kill -KILL "$pid" 2>/dev/null || true
    if isolated_wait_exit "$pid" 8; then
      rm -f "${ISOLATED_PID_FILE:-}"
      return 0
    fi
    echo "pid $pid still alive after SIGKILL wait bound" >&2
    ISOLATED_PROCESS_RETAINED=1
    return 1
  fi
  echo "refusing to KILL pid $pid: no longer the isolated binary" >&2
  rm -f "${ISOLATED_PID_FILE:-}"
}

isolated_teardown() {
  local status=0
  ISOLATED_PROCESS_RETAINED=0
  isolated_stop_owned_process || status=1
  ISOLATED_FINGERPRINT_STATUS=0
  if [ -f "${ISOLATED_FINGERPRINTS:-}" ]; then
    isolated_fingerprint_check || { ISOLATED_FINGERPRINT_STATUS=1; status=1; }
  fi
  if [ "${ISOLATED_PROCESS_RETAINED:-0}" = 1 ]; then
    echo "retaining isolated app and support while pid still lives" >&2
    if [ -n "${ISOLATED_EVIDENCE:-}" ]; then
      echo "$ISOLATED_LABEL evidence: $ISOLATED_EVIDENCE"
    fi
    return 1
  fi
  isolated_rm_owned "${ISOLATED_OUT:-}" "${ISOLATED_CREATED_OUT:-}" || status=1
  isolated_rm_owned "${ISOLATED_SUPPORT:-}" "${ISOLATED_CREATED_SUPPORT:-}" || status=1
  ISOLATED_CREATED_OUT=
  ISOLATED_CREATED_SUPPORT=
  if [ -n "${ISOLATED_EVIDENCE:-}" ]; then
    echo "$ISOLATED_LABEL evidence: $ISOLATED_EVIDENCE"
  fi
  return "$status"
}

isolated_cleanup() {
  local status=$?
  local tear=0
  isolated_teardown || tear=1
  if [ "$status" -eq 0 ] && [ "$tear" -ne 0 ]; then
    exit 1
  fi
  exit "$status"
}

isolated_claim_support() {
  local parent="$HOME/Library/Application Support"
  mkdir -p "$parent"
  local dir
  dir=$(mktemp -d "$parent/baia-${ISOLATED_LABEL}.XXXXXX") || return 1
  local base
  base=$(basename "$dir")
  case "$base" in
    baia|baia-dev)
      rmdir "$dir" 2>/dev/null || true
      echo "refusing product support directory name $base" >&2
      return 1
      ;;
  esac
  if [ -d "$HOME/Library/Application Support/baia" ] && [ "$dir" = "$HOME/Library/Application Support/baia" ]; then
    echo "refusing to reuse the Release support directory" >&2
    return 1
  fi
  if [ -d "$HOME/Library/Application Support/baia-dev" ] && [ "$dir" = "$HOME/Library/Application Support/baia-dev" ]; then
    echo "refusing to reuse the Debug support directory" >&2
    return 1
  fi
  ISOLATED_SUPPORT="$dir"
  ISOLATED_CREATED_SUPPORT="$dir"
  ISOLATED_SUPPORT_NAME="$base"
  isolated_mark "$dir"
}

isolated_prepare_body() {
  if [ ! -d "$ISOLATED_SOURCE_APP" ]; then
    echo "no Debug app at $ISOLATED_SOURCE_APP. Coordinator builds first, or run make build." >&2
    return 1
  fi

  ISOLATED_RUN_ID=$(isolated_new_run_id)
  local scratch
  scratch=$(isolated_scratch_parent)
  ISOLATED_OUT=$(mktemp -d "$scratch/baia-${ISOLATED_LABEL}.XXXXXX")
  ISOLATED_CREATED_OUT="$ISOLATED_OUT"
  isolated_mark "$ISOLATED_OUT"

  ISOLATED_EVIDENCE="${ISOLATED_EVIDENCE:-$scratch/baia-${ISOLATED_LABEL}-evidence-$$}"
  mkdir -p "$ISOLATED_EVIDENCE"
  ISOLATED_APP="$ISOLATED_OUT/${ISOLATED_LABEL}.app"
  ISOLATED_CONFIG="$ISOLATED_OUT/config.json"
  ISOLATED_ZDOT="$ISOLATED_OUT/zdot"
  ISOLATED_PID_FILE="$ISOLATED_OUT/app.pid"
  ISOLATED_FINGERPRINTS="$ISOLATED_OUT/normal-fingerprints.tsv"

  isolated_claim_support || return 1
  ISOLATED_SESSION="$ISOLATED_SUPPORT/session.json"
  ISOLATED_SOCKET="$ISOLATED_SUPPORT/control.sock"

  isolated_fingerprint_save

  mkdir -p "$ISOLATED_ZDOT"
  cat > "$ISOLATED_ZDOT/.zshenv" <<'EOF'
export HISTFILE=/dev/null
EOF

  /usr/bin/ditto "$ISOLATED_SOURCE_APP" "$ISOLATED_APP" || return 1

  # Test hook: fail after the copy exists so teardown must delete it without
  # touching the source app. Callers without `set -e` still have to abort.
  if [ "${ISOLATED_FORCE_PREPARE_FAILURE:-0}" = 1 ]; then
    echo "forced prepare failure" >&2
    return 1
  fi

  local plist="$ISOLATED_APP/Contents/Info.plist"
  local macos_dir="$ISOLATED_APP/Contents/MacOS"
  local original_exec new_exec short
  original_exec=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist") || return 1
  if [ ! -x "$macos_dir/$original_exec" ]; then
    echo "copied bundle has no executable at $macos_dir/$original_exec" >&2
    return 1
  fi
  short=$(printf '%s' "$ISOLATED_RUN_ID" | tr -d '-' | cut -c1-12)
  new_exec="baia-${ISOLATED_LABEL}-${short}"
  case "$new_exec" in
    baia|baia-dev)
      echo "refusing product executable name $new_exec" >&2
      return 1
      ;;
  esac
  if [ "$new_exec" = "$original_exec" ]; then
    echo "isolated executable name collided with the source name $original_exec" >&2
    return 1
  fi
  if [ "$new_exec" != "$original_exec" ]; then
    mv "$macos_dir/$original_exec" "$macos_dir/$new_exec" || return 1
  fi

  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier pasqualotto.baia.${ISOLATED_LABEL}.${ISOLATED_RUN_ID}" \
    "$plist" || return 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $new_exec" \
    "$plist" || return 1
  if /usr/libexec/PlistBuddy -c "Print :CFBundleName" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $new_exec" "$plist" || return 1
  else
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string $new_exec" "$plist" || return 1
  fi
  if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $new_exec" "$plist" || return 1
  else
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $new_exec" "$plist" || return 1
  fi
  /usr/libexec/PlistBuddy -c "Set :BAIASupportDirectory $ISOLATED_SUPPORT_NAME" \
    "$plist" || return 1
  /usr/bin/codesign --force --deep --sign - "$ISOLATED_APP" >/dev/null || return 1

  ISOLATED_BINARY="$macos_dir/$new_exec"
  if [ ! -x "$ISOLATED_BINARY" ]; then
    echo "copied bundle has no executable at $ISOLATED_BINARY" >&2
    return 1
  fi
}

isolated_prepare() {
  if isolated_prepare_body; then
    return 0
  fi
  isolated_teardown
  return 1
}
