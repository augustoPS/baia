#!/usr/bin/env bash
# Bounded, resumable disposable baia instance for coordinator-driven desktop
# acceptance. Prints STATE=<owned fixture.json>, then supervises the copied app
# until the owned stop marker appears or the batch deadline passes. The copied
# app takes focus once launched, so never run this inside a baia pane.
#
#   run.sh [--resume <evidence-dir>]
#
# Environment:
#   BAIA_DESKTOP_ACCEPTANCE_SKIP_BUILD=1 or BAIA_ISOLATED_SKIP_BUILD=1  skip make build
#   BAIA_DESKTOP_ACCEPTANCE_SOURCE_APP   app to copy (default the Debug build)
#   BAIA_DESKTOP_ACCEPTANCE_EVIDENCE_ROOT  where per-run evidence lives
#   BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS  deadline renewed by every request (900)
#   BAIA_DESKTOP_ACCEPTANCE_MAX_SECONDS    absolute cap for one runner (10800)
#
# The runner is the only process owner. phase.py never signals anything; it
# writes an owned request file (stop, launch, or expect-quit) and the runner
# answers in an owned result file. The app is launched by the first `prepare`,
# not here. An app exit is a failure (exit 1) unless the coordinator announced
# it through expect-quit first, in which case the pid is reaped and the next
# launch request starts the same copy on the session it wrote itself.
#
# Interrupt a backgrounded runner with SIGTERM. A job started with `&` from a
# non-interactive shell has SIGINT ignored, and bash cannot trap an ignored
# signal, so Ctrl-C semantics only exist for a foreground runner.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"
PYTHON=/usr/bin/python3
BATCH_SECONDS=${BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS:-900}
MAX_SECONDS=${BAIA_DESKTOP_ACCEPTANCE_MAX_SECONDS:-10800}
EVIDENCE_ROOT=${BAIA_DESKTOP_ACCEPTANCE_EVIDENCE_ROOT:-$ROOT/.superpowers/sdd/roadmap/acceptance}
RESUME_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --resume)
      [ $# -ge 2 ] || { echo "--resume needs an evidence directory" >&2; exit 2; }
      RESUME_DIR="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

for value in "$BATCH_SECONDS" "$MAX_SECONDS"; do
  case "$value" in
    *[!0-9]*|'') echo "deadline seconds must be a positive integer" >&2; exit 2 ;;
  esac
done
if [ "$BATCH_SECONDS" -lt 1 ] || [ "$BATCH_SECONDS" -gt 3600 ]; then
  echo "batch seconds must be from 1 through 3600" >&2
  exit 2
fi
if [ "$MAX_SECONDS" -lt "$BATCH_SECONDS" ]; then
  echo "max seconds must not be below batch seconds" >&2
  exit 2
fi
if [ ! -f "$LIBRARY" ]; then
  echo "desktop-acceptance needs Diagnostics/lib/isolated-app.sh" >&2
  exit 1
fi
if [ ! -f "$HERE/phase.py" ] || [ ! -f "$ROOT/Diagnostics/control-channel/probe.py" ]; then
  echo "desktop-acceptance needs phase.py and Diagnostics/control-channel/probe.py" >&2
  exit 1
fi

ISOLATED_LABEL=desktop-acceptance
ISOLATED_SOURCE_APP=${BAIA_DESKTOP_ACCEPTANCE_SOURCE_APP:-$ROOT/.build/Build/Products/Debug/baia-dev.app}
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1
umask 077

cd "$ROOT"
if [ "${BAIA_DESKTOP_ACCEPTANCE_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != 1 ]; then
  make build
fi

RUN_ID=$(/usr/bin/uuidgen)
mkdir -p "$EVIDENCE_ROOT"
EVIDENCE_ROOT=$(cd "$EVIDENCE_ROOT" && pwd -P)
PREVIOUS_RUN_ID=""
if [ -n "$RESUME_DIR" ]; then
  if [ ! -d "$RESUME_DIR" ]; then
    echo "resume directory does not exist: $RESUME_DIR" >&2
    exit 2
  fi
  RESUME_DIR=$(cd "$RESUME_DIR" && pwd -P)
  case "$RESUME_DIR" in
    "$EVIDENCE_ROOT"/*) ;;
    *) echo "resume directory is not under $EVIDENCE_ROOT" >&2; exit 2 ;;
  esac
  if [ ! -f "$RESUME_DIR/ledger.json" ]; then
    echo "resume directory has no ledger.json: $RESUME_DIR" >&2
    exit 2
  fi
  ISOLATED_EVIDENCE="$RESUME_DIR"
  if [ -f "$RESUME_DIR/fixture.json" ]; then
    PREVIOUS_RUN_ID=$($PYTHON -c 'import json,sys; print(json.load(open(sys.argv[1])).get("runId",""))' "$RESUME_DIR/fixture.json" 2>/dev/null || true)
    mv "$RESUME_DIR/fixture.json" "$RESUME_DIR/fixture.${PREVIOUS_RUN_ID:-previous}.json"
  fi
else
  ISOLATED_EVIDENCE="$EVIDENCE_ROOT/$RUN_ID"
fi
mkdir -p "$ISOLATED_EVIDENCE"
chmod 700 "$ISOLATED_EVIDENCE"

isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.$RUN_ID.tsv"

LAUNCHED=0
LAUNCHES=0
TOKENS="$ISOLATED_OUT/tokens"
JOBS="$ISOLATED_OUT/jobs"
PROJECTS="$ISOLATED_OUT/projects"
STOP_MARKER="$ISOLATED_OUT/coordinator-stop"
REQUEST="$ISOLATED_OUT/runner-request.json"
RESULT="$ISOLATED_OUT/runner-result.json"
STATE="$ISOLATED_EVIDENCE/fixture.json"
LEDGER="$ISOLATED_EVIDENCE/ledger.json"
mkdir -p "$TOKENS" "$JOBS" "$PROJECTS"
chmod 700 "$ISOLATED_OUT" "$TOKENS" "$JOBS" "$PROJECTS"

# True when pid descends from the live copied app within six hops.
descends_from_app() {
  local pid="$1" hops=0 parent
  [ -n "${ISOLATED_CHILD_PID:-}" ] || return 1
  while [ "$hops" -lt 6 ]; do
    parent=$(/bin/ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    case "$parent" in *[!0-9]*|''|0|1) return 1 ;; esac
    [ "$parent" = "$ISOLATED_CHILD_PID" ] && return 0
    pid="$parent"
    hops=$((hops + 1))
  done
  return 1
}

# End only the foreground jobs this fixture's own .zshrc recorded. A record
# names the pid and the start time ps reported when the shell recorded it; a
# pid is signalled only while its live start time and command still match
# (a reused pid has another start time), and, while the copied app is alive,
# only when it descends from that app. Orphans after an app quit keep the
# start-time rule.
stop_owned_jobs() {
  local file pid started args live_started
  for file in "$JOBS"/*.job; do
    [ -f "$file" ] || continue
    pid=$(sed -n 's/^pid=//p' "$file" | head -1)
    started=$(sed -n 's/^started=//p' "$file" | head -1 | sed 's/[[:space:]]*$//')
    case "$pid" in *[!0-9]*|''|0|1) rm -f "$file"; continue ;; esac
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$file"; continue; fi
    args=$(isolated_process_args "$pid")
    live_started=$(/bin/ps -p "$pid" -o lstart= 2>/dev/null | sed 's/[[:space:]]*$//')
    case "$args" in
      "sleep 300"|"/bin/sleep 300") ;;
      *) echo "refusing to signal recorded job $pid: live command is $args" >&2; rm -f "$file"; continue ;;
    esac
    if [ -z "$started" ] || [ "$live_started" != "$started" ]; then
      echo "refusing to signal recorded job $pid: start time changed (pid reused)" >&2
      rm -f "$file"
      continue
    fi
    if [ "${LAUNCHED:-0}" -eq 1 ] && isolated_app_is_running && ! descends_from_app "$pid"; then
      echo "refusing to signal recorded job $pid: not a descendant of the copied app" >&2
      rm -f "$file"
      continue
    fi
    kill -TERM "$pid" 2>/dev/null || true
    isolated_wait_exit "$pid" 8 || true
    rm -f "$file"
  done
}

acceptance_cleanup() {
  local incoming=$?
  local cleanup_status=0
  stop_owned_jobs
  isolated_stop_owned_process || cleanup_status=1
  if [ -n "${ISOLATED_SUPPORT:-}" ] && [ -d "$ISOLATED_SUPPORT" ]; then
    chmod -R u+w "$ISOLATED_SUPPORT" 2>/dev/null || true
  fi
  if [ -n "${ISOLATED_EVIDENCE:-}" ] && [ -f "${ISOLATED_FINGERPRINTS:-}" ]; then
    while IFS= read -r path; do
      printf '%s\t' "$path"
      isolated_fingerprint_one "$path"
    done > "$ISOLATED_EVIDENCE/normal-state-after.$RUN_ID.tsv" <<EOF
$(isolated_normal_paths)
EOF
  fi
  isolated_teardown || cleanup_status=1
  if [ "$incoming" -ne 0 ]; then exit "$incoming"; fi
  if [ "$cleanup_status" -ne 0 ]; then exit 1; fi
  exit 0
}
trap acceptance_cleanup EXIT

cat > "$ISOLATED_ZDOT/.zshenv" <<EOF
umask 077
printf 'pane=%s\ntoken=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" > "$TOKENS/pane-\$BAIA_PANE.env"
chmod 600 "$TOKENS/pane-\$BAIA_PANE.env"
export HISTFILE=/dev/null
EOF

BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$ISOLATED_APP/Contents/Info.plist")
SOURCE_EXEC=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$ISOLATED_SOURCE_APP/Contents/Info.plist")
SOURCE_BINARY="$ISOLATED_SOURCE_APP/Contents/MacOS/$SOURCE_EXEC"
BINARY_SHA=$(/usr/bin/shasum -a 256 "$ISOLATED_BINARY" | awk '{print $1}')
SOURCE_SHA=$(/usr/bin/shasum -a 256 "$SOURCE_BINARY" | awk '{print $1}')
GIT_REVISION=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
GIT_DIRTY=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
NOW=$(date +%s)

$PYTHON - "$STATE" <<PY
import json, os, sys
document = {
    "version": 1,
    "runId": "$RUN_ID",
    "previousRunId": "$PREVIOUS_RUN_ID" or None,
    "isolationRunId": "$ISOLATED_RUN_ID",
    "label": "$ISOLATED_LABEL",
    "repoRoot": "$ROOT",
    "gitRevision": "$GIT_REVISION",
    "gitDirty": int("$GIT_DIRTY" or 0),
    "sourceApp": "$ISOLATED_SOURCE_APP",
    "sourceBinarySha256": "$SOURCE_SHA",
    "app": "$ISOLATED_APP",
    "binary": "$ISOLATED_BINARY",
    "binarySha256": "$BINARY_SHA",
    "bundleId": "$BUNDLE_ID",
    "pid": None,
    "batches": 0,
    "scratch": "$ISOLATED_OUT",
    "support": "$ISOLATED_SUPPORT",
    "session": "$ISOLATED_SESSION",
    "socket": "$ISOLATED_SOCKET",
    "config": "$ISOLATED_CONFIG",
    "zdot": "$ISOLATED_ZDOT",
    "tokenDir": "$TOKENS",
    "jobsDir": "$JOBS",
    "projectsDir": "$PROJECTS",
    "evidenceRoot": "$EVIDENCE_ROOT",
    "evidence": "$ISOLATED_EVIDENCE",
    "ledger": "$LEDGER",
    "fingerprintsBefore": "$ISOLATED_EVIDENCE/normal-state-before.$RUN_ID.tsv",
    "stopMarker": "$STOP_MARKER",
    "runnerRequest": "$REQUEST",
    "runnerResult": "$RESULT",
    "controlProbe": "$ROOT/Diagnostics/control-channel/probe.py",
    "recorder": "$HERE/recorder.py",
    "batchSeconds": $BATCH_SECONDS,
    "maxSeconds": $MAX_SECONDS,
    "startedAt": $NOW,
    "deadlineAt": $NOW + $BATCH_SECONDS,
    "nextSequence": 1,
    "scenario": None,
}
descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

echo "STATE=$STATE"
echo "RUN_ID=$RUN_ID"
echo "EVIDENCE=$ISOLATED_EVIDENCE"
echo "BUNDLE_ID=$BUNDLE_ID"
echo "SCRATCH=$ISOLATED_OUT"
echo "READY: prepare a scenario with phase.py --state '$STATE' prepare <scenario>; the app launches then"
echo "PAUSED: batch deadline ${BATCH_SECONDS}s, renewed by every request; stop with phase.py --state '$STATE' stop"

write_result() {
  # id action ok pid log error deadline
  $PYTHON - "$RESULT" "$@" <<'PY'
import json, os, sys, tempfile, time
path, request_id, action, ok, pid, log, error, deadline, binary = sys.argv[1:10]
document = {
    "id": request_id, "action": action, "ok": ok == "1",
    "pid": int(pid) if pid else None, "log": log or None,
    "error": error or None, "deadlineAt": int(deadline) if deadline else None,
    "binary": binary or None, "at": time.time(),
}
descriptor, temporary = tempfile.mkstemp(prefix="runner-result.", dir=os.path.dirname(path))
os.fchmod(descriptor, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, path)
PY
}

parse_request() {
  $PYTHON - "$REQUEST" <<'PY'
import json, re, sys
try:
    document = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(3)
if not isinstance(document, dict):
    sys.exit(3)
request_id = document.get("id")
action = document.get("action")
log = document.get("log") or ""
if not isinstance(request_id, str) or not re.match(r"^[0-9a-f]{32}$", request_id):
    sys.exit(3)
if action not in ("stop", "launch", "expect-quit"):
    print("%s\t%s\t" % (request_id, action if isinstance(action, str) else "invalid"))
    sys.exit(4)
if log and not re.match(r"^[A-Za-z0-9._-]+\.log$", log):
    print("%s\t%s\t" % (request_id, action))
    sys.exit(4)
print("%s\t%s\t%s" % (request_id, action, log))
PY
}

handle_request() {
  local parsed status=0 request_id action log deadline
  parsed=$(parse_request) || status=$?
  if [ "$status" -eq 3 ]; then
    echo "ignoring an unreadable runner request" >&2
    rm -f "$REQUEST"
    return 0
  fi
  IFS=$'\t' read -r request_id action log <<<"$parsed"
  if [ "$status" -ne 0 ]; then
    write_result "$request_id" "$action" 0 "" "" "runner refuses action $action" "" ""
    rm -f "$REQUEST"
    return 0
  fi
  NOW=$(date +%s)
  deadline=$((NOW + BATCH_SECONDS))
  DEADLINE=$((SECONDS + BATCH_SECONDS))
  # Every request but expect-quit ends the expectation; an app that quits
  # after that is again an unexpected exit.
  [ "$action" = expect-quit ] || EXPECT_QUIT=0
  case "$action" in
    expect-quit)
      if [ "$LAUNCHED" -eq 1 ] && isolated_app_is_running; then
        EXPECT_QUIT=1
        write_result "$request_id" expect-quit 1 "$ISOLATED_CHILD_PID" "" "" "$deadline" "$ISOLATED_BINARY"
      else
        write_result "$request_id" expect-quit 0 "" "" "no launched app to expect a quit from" "$deadline" "$ISOLATED_BINARY"
      fi
      ;;
    stop)
      stop_owned_jobs
      if isolated_stop_owned_process; then
        LAUNCHED=0
        write_result "$request_id" stop 1 "" "" "" "$deadline" "$ISOLATED_BINARY"
      else
        write_result "$request_id" stop 0 "" "" "isolated process still alive after the KILL bound" "$deadline" "$ISOLATED_BINARY"
      fi
      ;;
    launch)
      if [ "$LAUNCHED" -eq 1 ] && isolated_app_is_running; then
        write_result "$request_id" launch 0 "$ISOLATED_CHILD_PID" "" "already launched; request stop first" "$deadline" "$ISOLATED_BINARY"
      else
        # A previous copy that quit on its own is reaped, never signalled.
        isolated_stop_owned_process || true
        LAUNCHED=0
        [ -n "$log" ] || log="app-$((LAUNCHES + 1)).log"
        if isolated_launch "$ISOLATED_EVIDENCE/$log"; then
          LAUNCHED=1
          LAUNCHES=$((LAUNCHES + 1))
          write_result "$request_id" launch 1 "$ISOLATED_CHILD_PID" "$ISOLATED_EVIDENCE/$log" "" "$deadline" "$ISOLATED_BINARY"
        else
          LAUNCHED=0
          write_result "$request_id" launch 0 "" "" "isolated_launch failed" "$deadline" "$ISOLATED_BINARY"
        fi
      fi
      ;;
  esac
  rm -f "$REQUEST"
}

EXPECT_QUIT=0
QUITS="$ISOLATED_EVIDENCE/expected-quits.$RUN_ID.log"
DEADLINE=$((SECONDS + BATCH_SECONDS))
HARD_DEADLINE=$((SECONDS + MAX_SECONDS))
while [ ! -e "$STOP_MARKER" ]; do
  if [ -f "$REQUEST" ]; then
    handle_request
    continue
  fi
  if [ "$LAUNCHED" -eq 1 ] && ! isolated_app_is_running; then
    if [ "$EXPECT_QUIT" -eq 1 ]; then
      # The coordinator announced this quit (A03 Retry, C02 quit/relaunch).
      # Reap the exact pid, keep the fixture, and wait for the next request.
      isolated_stop_owned_process || true
      stop_owned_jobs
      printf '%s\tpid=%s\texpected-quit\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ISOLATED_CHILD_PID" >> "$QUITS"
      LAUNCHED=0
      EXPECT_QUIT=0
      continue
    fi
    echo "copied app exited before the coordinator stopped the fixture" >&2
    exit 1
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "batch deadline of ${BATCH_SECONDS}s passed with no request; cleaning the exact fixture process" >&2
    exit 124
  fi
  if [ "$SECONDS" -ge "$HARD_DEADLINE" ]; then
    echo "runner cap of ${MAX_SECONDS}s passed; cleaning the exact fixture process" >&2
    exit 124
  fi
  sleep 0.25
done

echo "desktop-acceptance ledger: $LEDGER"
echo "desktop-acceptance evidence: $ISOLATED_EVIDENCE"
