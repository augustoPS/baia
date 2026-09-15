#!/usr/bin/env bash
# No-app checks for the desktop-acceptance runner. The "app" is a fake bundle
# whose executable blocks on a fifo and presents its own path as its command,
# so the shared helper's exact-pid rules apply to it as they do to a real copy.
# Nothing here builds or launches baia, takes focus, or touches normal state.
set -uo pipefail
if [ -n "${BAIA_PANE:-}" ]; then
  echo "Run this launcher test outside a baia pane." >&2
  exit 2
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RUNNER="$HERE/run.sh"
PHASE="$HERE/phase.py"
PYTHON=/usr/bin/python3
fails=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/baia-desktop-acceptance-runtest.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
FAKE="$WORK/fake.app"
FIFO="$WORK/hold.fifo"
EVIDENCE_ROOT="$WORK/acceptance"
RUNNER_PID=
RUNNER_OUT=

cleanup_test() {
  if [ -n "${RUNNER_PID:-}" ] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$RUNNER_PID" 2>/dev/null || true
  fi
  # Only launch replies made by this test can add a PID to this file.
  local pid binary
  if [ -f "$WORK/owned-processes.tsv" ]; then
    while IFS=$'\t' read -r pid binary; do
      case "$pid" in *[!0-9]*|''|0|1) continue ;; esac
      if [ "$(/bin/ps -p "$pid" -o args= 2>/dev/null)" = "$binary" ]; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done < "$WORK/owned-processes.tsv"
  fi
  for pid in "${OWNED_JOB:-}" "${FOREIGN_JOB:-}"; do
    [ -n "$pid" ] || continue
    if [ "$(/bin/ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')" = "$$" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup_test EXIT

mkdir -p "$FAKE/Contents/MacOS"
mkfifo "$FIFO"
cat > "$FAKE/Contents/MacOS/baia-dev" <<EOF
#!/bin/bash
exec 3<>"$FIFO"
exec -a "\$0" /bin/cat <&3 >/dev/null
EOF
chmod 755 "$FAKE/Contents/MacOS/baia-dev"
cat > "$FAKE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>baia-dev</string>
  <key>CFBundleIdentifier</key>
  <string>pasqualotto.baia.dev</string>
  <key>CFBundleDisplayName</key>
  <string>baia-dev</string>
  <key>BAIASupportDirectory</key>
  <string>baia-dev</string>
</dict>
</plist>
EOF
SOURCE_HASH=$(/usr/bin/shasum -a 256 "$FAKE/Contents/MacOS/baia-dev" "$FAKE/Contents/Info.plist" | awk '{print $1}' | tr '\n' ' ')
source_unchanged() {
  [ "$(/usr/bin/shasum -a 256 "$FAKE/Contents/MacOS/baia-dev" "$FAKE/Contents/Info.plist" | awk '{print $1}' | tr '\n' ' ')" = "$SOURCE_HASH" ]
}

# Normal-state fingerprints are taken by the shared helper on the real normal
# paths. The test never writes them; it only checks before and after agree.
support_dirs() { ls -d "$HOME/Library/Application Support"/baia-desktop-acceptance.* 2>/dev/null | wc -l | tr -d ' '; }
scratch_dirs() { ls -d "$(dirname "$(mktemp -u)")"/baia-desktop-acceptance.* 2>/dev/null | wc -l | tr -d ' '; }
SUPPORT_BEFORE=$(support_dirs)
SCRATCH_BEFORE=$(scratch_dirs)

export BAIA_DESKTOP_ACCEPTANCE_SKIP_BUILD=1
export BAIA_DESKTOP_ACCEPTANCE_SOURCE_APP="$FAKE"
export BAIA_DESKTOP_ACCEPTANCE_EVIDENCE_ROOT="$EVIDENCE_ROOT"
export PYTHONDONTWRITEBYTECODE=1

start_runner() {
  RUNNER_OUT="$WORK/runner-$1.out"
  : > "$RUNNER_OUT"
  bash "$RUNNER" "${@:2}" > "$RUNNER_OUT" 2>&1 &
  RUNNER_PID=$!
}

wait_state() {
  local i
  for i in $(seq 1 120); do
    STATE=$(sed -n 's/^STATE=//p' "$RUNNER_OUT" | head -1)
    [ -n "$STATE" ] && [ -f "$STATE" ] && return 0
    kill -0 "$RUNNER_PID" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

wait_exit() {
  local pid="$1" tries="${2:-80}" i
  for i in $(seq 1 "$tries"); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return $?; }
    sleep 0.25
  done
  return 255
}

state_field() { $PYTHON -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$STATE" "$1"; }
# What phase.py prepare does with a launch result; the test drives the runner
# directly, so it records the pid itself.
set_state_pid() { $PYTHON -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["pid"]=int(sys.argv[2]) if sys.argv[2] else None; d["scenario"]={"scenario":"input","arm":"default","batch":1,"panes":[]}; json.dump(d, open(p,"w"))' "$STATE" "${1:-}"; }
wait_command() {
  local pid="$1" want="$2" i
  for i in $(seq 1 40); do
    [ "$(/bin/ps -p "$pid" -o command= 2>/dev/null)" = "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

# Ask the runner the way phase.py does, through the owned request file.
runner_request() {
  $PYTHON - "$STATE" "$1" "${2:-}" <<'PY'
import importlib.util, json, os, sys
state_path, action, log = sys.argv[1:4]
here = os.path.dirname(os.path.realpath(state_path))
spec = importlib.util.spec_from_file_location("phase", os.environ["PHASE"])
phase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phase)
state = json.load(open(state_path))
try:
    result = phase.request_runner(state, action, seconds=20, extra={"log": log} if log else None)
except phase.FixtureError as error:
    print("ERROR %s" % error)
    sys.exit(1)
if action == "launch" and result.get("ok") and result.get("pid"):
    with open(os.environ["TEST_OWNED_PROCESSES"], "a") as records:
        records.write("%s\t%s\n" % (result["pid"], result["binary"]))
print(json.dumps(result))
PY
}
export PHASE
export TEST_OWNED_PROCESSES="$WORK/owned-processes.tsv"

echo "== forced prepare failure"
ISOLATED_FORCE_PREPARE_FAILURE=1 bash "$RUNNER" > "$WORK/forced.out" 2>&1
status=$?
[ "$status" -ne 0 ] && pass "forced prepare failure exits non-zero ($status)" || fail "forced prepare failure exits non-zero"
! grep -q '^STATE=' "$WORK/forced.out" && pass "forced prepare failure prints no STATE" || fail "forced prepare failure prints no STATE"
[ "$(support_dirs)" = "$SUPPORT_BEFORE" ] && pass "forced failure leaves no support directory" || fail "forced failure leaves no support directory"
[ "$(scratch_dirs)" = "$SCRATCH_BEFORE" ] && pass "forced failure leaves no scratch directory" || fail "forced failure leaves no scratch directory"
source_unchanged && pass "forced failure leaves the source bundle unchanged" || fail "forced failure leaves the source bundle unchanged"

echo "== invalid deadline arguments"
BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS=0 bash "$RUNNER" >/dev/null 2>&1; [ $? -eq 2 ] && pass "batch seconds 0 is refused" || fail "batch seconds 0 is refused"
BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS=abc bash "$RUNNER" >/dev/null 2>&1; [ $? -eq 2 ] && pass "non-numeric batch seconds is refused" || fail "non-numeric batch seconds is refused"
bash "$RUNNER" --resume "$WORK/nowhere" >/dev/null 2>&1; [ $? -eq 2 ] && pass "resume of a missing directory is refused" || fail "resume of a missing directory is refused"
mkdir -p "$WORK/outside-root" && bash "$RUNNER" --resume "$WORK/outside-root" >/dev/null 2>&1; [ $? -eq 2 ] && pass "resume outside the evidence root is refused" || fail "resume outside the evidence root is refused"

echo "== launch, stop, relaunch, interruption"
BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS=30 start_runner live
if wait_state; then
  pass "runner prints STATE and writes fixture.json"
else
  fail "runner prints STATE and writes fixture.json"; cat "$RUNNER_OUT"; exit 1
fi
[ "$(stat -f '%Lp' "$STATE")" = "600" ] && pass "fixture.json is mode 600" || fail "fixture.json is mode 600"
EVIDENCE=$(state_field evidence)
SCRATCH=$(state_field scratch)
SUPPORT=$(state_field support)
BINARY=$(state_field binary)
RUN_ID=$(state_field runId)
[ -z "$(state_field pid)" ] && pass "no app is launched before the first request" || fail "no app is launched before the first request"
case "$EVIDENCE" in "$EVIDENCE_ROOT"/*) pass "evidence lives under the evidence root" ;; *) fail "evidence lives under the evidence root ($EVIDENCE)" ;; esac
[ -f "$EVIDENCE/normal-state-before.$RUN_ID.tsv" ] && pass "normal-state fingerprints saved before any launch" || fail "normal-state fingerprints saved before any launch"
[ "$(state_field binarySha256)" = "$(/usr/bin/shasum -a 256 "$BINARY" | awk '{print $1}')" ] && pass "state records the copied binary SHA-256" || fail "state records the copied binary SHA-256"
[ "$(state_field gitRevision)" = "$(git -C "$ROOT" rev-parse HEAD)" ] && pass "state records the git revision" || fail "state records the git revision"

result=$(runner_request launch app-01-test.log)
PID1=$($PYTHON -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$result" 2>/dev/null)
[ -n "$PID1" ] && kill -0 "$PID1" 2>/dev/null && pass "launch request starts the copied binary (pid $PID1)" || { fail "launch request starts the copied binary ($result)"; }
wait_command "$PID1" "$BINARY" && pass "launched command is exactly the copied binary" || fail "launched command is exactly the copied binary ($(/bin/ps -p "$PID1" -o command=))"
set_state_pid "$PID1"
[ -f "$EVIDENCE/app-01-test.log" ] && pass "launch log lands in evidence" || fail "launch log lands in evidence"
[ "$(stat -f '%Lp' "$SCRATCH")" = "700" ] && pass "scratch directory is mode 700" || fail "scratch directory is mode 700"

result=$(runner_request launch app-02.log)
case "$result" in ERROR*already*) pass "second launch without stop is refused" ;; *) fail "second launch without stop is refused ($result)" ;; esac

result=$(runner_request stop)
case "$result" in ERROR*) fail "stop request is honoured ($result)" ;; *) pass "stop request is honoured" ;; esac
wait_exit "$PID1" 40 >/dev/null; ! kill -0 "$PID1" 2>/dev/null && pass "stop ends exactly the launched pid" || fail "stop ends exactly the launched pid"
[ -d "$SUPPORT" ] && pass "stop keeps the support directory for the next batch" || fail "stop keeps the support directory for the next batch"

result=$(runner_request launch app-02.log)
PID2=$($PYTHON -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$result" 2>/dev/null)
[ -n "$PID2" ] && [ "$PID2" != "$PID1" ] && kill -0 "$PID2" 2>/dev/null && pass "relaunch yields a new live pid ($PID2)" || fail "relaunch yields a new live pid ($result)"
wait_command "$PID2" "$BINARY" >/dev/null
set_state_pid "$PID2"

printf '{"id":"%s","action":"rm -rf /","at":1}\n' "$(uuidgen | tr -d - | tr 'A-F' 'a-f')" > "$SCRATCH/runner-request.json"
for _ in $(seq 1 40); do [ -f "$SCRATCH/runner-result.json" ] && break; sleep 0.25; done
grep -q '"ok": false' "$SCRATCH/runner-result.json" 2>/dev/null && grep -q 'refuses action' "$SCRATCH/runner-result.json" \
  && pass "an unknown action is refused, not executed" || fail "an unknown action is refused, not executed"
rm -f "$SCRATCH/runner-result.json"
kill -0 "$PID2" 2>/dev/null && pass "the refused request left the app running" || fail "the refused request left the app running"

printf 'not json\n' > "$SCRATCH/runner-request.json"
sleep 1
[ ! -f "$SCRATCH/runner-request.json" ] && kill -0 "$RUNNER_PID" 2>/dev/null && pass "an unreadable request is discarded and the runner survives" || fail "an unreadable request is discarded and the runner survives"

printf 'secret=fixture-capability\n' > "$SCRATCH/tokens/pane-TEST.env"
$PYTHON "$PHASE" --state "$STATE" report > "$WORK/report.json" 2>&1
grep -q "fixture-capability" "$WORK/report.json" && fail "report prints no capability" || pass "report prints no capability"
grep -q '"sameProcess": true' "$WORK/report.json" && pass "report sees the live copied pid as the fixture" || fail "report sees the live copied pid as the fixture"

echo "== recorded job ownership"
/bin/sleep 300 >/dev/null 2>&1 &
OWNED_JOB=$!
/bin/sleep 300 >/dev/null 2>&1 &
FOREIGN_JOB=$!
sleep 0.3
OWNED_START=$(/bin/ps -p "$OWNED_JOB" -o lstart=)
# While the copied app lives, a matching record whose pid does not descend
# from that app is refused: the test's own sleep is nobody's pane job.
printf 'pid=%s\nstarted=%s\nshell=1\npane=TEST\n' "$OWNED_JOB" "$OWNED_START" > "$SCRATCH/jobs/sleep-1.job"
result=$(runner_request stop)
sleep 0.5
kill -0 "$OWNED_JOB" 2>/dev/null && pass "stop leaves a matching job that does not descend from the live app" || fail "stop leaves a matching job that does not descend from the live app"
! kill -0 "$PID2" 2>/dev/null && pass "stop ended the copied app (pid $PID2)" || fail "stop ended the copied app"
# With no app alive (orphans after a quit), the recorded start identity decides.
printf 'pid=%s\nstarted=%s\nshell=1\npane=TEST\n' "$OWNED_JOB" "$OWNED_START" > "$SCRATCH/jobs/sleep-1.job"
printf 'pid=%s\nstarted=%s\nshell=2\npane=TEST\n' "$FOREIGN_JOB" "Thu Jan  1 00:00:00 2026" > "$SCRATCH/jobs/sleep-2.job"
result=$(runner_request stop)
wait_exit "$OWNED_JOB" 40 >/dev/null
! kill -0 "$OWNED_JOB" 2>/dev/null && pass "stop ends a recorded job whose start identity matches" || fail "stop ends a recorded job whose start identity matches"
kill -0 "$FOREIGN_JOB" 2>/dev/null && pass "stop leaves a pid whose start identity changed" || fail "stop leaves a pid whose start identity changed"
kill -KILL "$FOREIGN_JOB" 2>/dev/null; wait "$FOREIGN_JOB" 2>/dev/null
[ ! -f "$SCRATCH/jobs/sleep-2.job" ] && pass "a refused job record is discarded" || fail "a refused job record is discarded"

echo "== expected quit and relaunch on the same session"
result=$(runner_request expect-quit)
case "$result" in ERROR*) pass "expect-quit without a launched app is refused" ;; *) fail "expect-quit without a launched app is refused ($result)" ;; esac
result=$(runner_request launch app-03.log)
PID3=$($PYTHON -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$result" 2>/dev/null)
wait_command "$PID3" "$BINARY" >/dev/null
set_state_pid "$PID3"
printf 'marker\n' > "$SUPPORT/session.json"
$PYTHON "$PHASE" --state "$STATE" await-quit --seconds 20 > "$WORK/await.json" 2>&1 &
AWAIT_PID=$!
sleep 1
kill -TERM "$PID3"
wait_exit "$AWAIT_PID" 100; status=$?
[ "$status" -eq 0 ] && grep -q '"quitObserved": true' "$WORK/await.json" && pass "await-quit observes the announced quit" || { fail "await-quit observes the announced quit (status $status)"; cat "$WORK/await.json"; }
sleep 1
kill -0 "$RUNNER_PID" 2>/dev/null && pass "the runner survives an expected quit" || fail "the runner survives an expected quit"
[ -z "$(state_field pid)" ] && pass "state pid is cleared after the quit" || fail "state pid is cleared after the quit"
grep -q "pid=$PID3" "$EVIDENCE/expected-quits.$RUN_ID.log" 2>/dev/null && pass "the expected quit is logged in evidence" || fail "the expected quit is logged in evidence"
result=$(runner_request launch app-04.log)
PID4=$($PYTHON -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$result" 2>/dev/null)
[ -n "$PID4" ] && kill -0 "$PID4" 2>/dev/null && pass "launch after an expected quit starts the same copy again" || fail "launch after an expected quit starts the same copy again ($result)"
[ "$(cat "$SUPPORT/session.json")" = "marker" ] && pass "the session the app left is not reseeded by the runner" || fail "the session the app left is not reseeded by the runner"
wait_command "$PID4" "$BINARY" >/dev/null
set_state_pid "$PID4"
PID2=$PID4

echo "== interruption"
kill -TERM "$RUNNER_PID"
wait_exit "$RUNNER_PID" 80; status=$?
[ "$status" -eq 143 ] && pass "SIGTERM exits 143 through the cleanup trap" || fail "SIGTERM exits 143 through the cleanup trap (got $status)"
! kill -0 "$PID2" 2>/dev/null && pass "interruption ends the launched pid" || fail "interruption ends the launched pid"
[ ! -d "$SCRATCH" ] && pass "interruption removes the scratch directory" || fail "interruption removes the scratch directory"
[ ! -d "$SUPPORT" ] && pass "interruption removes the support directory" || fail "interruption removes the support directory"
[ -f "$STATE" ] && [ -f "$EVIDENCE/app-01-test.log" ] && pass "interruption keeps evidence and the state file" || fail "interruption keeps evidence and the state file"
[ -f "$EVIDENCE/normal-state-after.$RUN_ID.tsv" ] && cmp -s "$EVIDENCE/normal-state-before.$RUN_ID.tsv" "$EVIDENCE/normal-state-after.$RUN_ID.tsv" \
  && pass "normal-state fingerprints are unchanged after interruption" || fail "normal-state fingerprints are unchanged after interruption"
[ "$(support_dirs)" = "$SUPPORT_BEFORE" ] && [ "$(scratch_dirs)" = "$SCRATCH_BEFORE" ] && pass "no isolated directories leak" || fail "no isolated directories leak"
source_unchanged && pass "source bundle unchanged after a live batch" || fail "source bundle unchanged after a live batch"
RUNNER_PID=

echo "== unexpected app exit"
BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS=30 start_runner exit
wait_state || { fail "runner starts for the exit case"; cat "$RUNNER_OUT"; exit 1; }
result=$(runner_request launch)
PIDX=$($PYTHON -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$result" 2>/dev/null)
kill -KILL "$PIDX" 2>/dev/null
wait_exit "$RUNNER_PID" 80; status=$?
[ "$status" -eq 1 ] && pass "an app that exits on its own ends the runner with 1" || fail "an app that exits on its own ends the runner with 1 (got $status)"
[ "$(support_dirs)" = "$SUPPORT_BEFORE" ] && [ "$(scratch_dirs)" = "$SCRATCH_BEFORE" ] && pass "cleanup after unexpected exit" || fail "cleanup after unexpected exit"
RUNNER_PID=

echo "== batch deadline"
BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS=2 start_runner deadline
wait_state || { fail "runner starts for the deadline case"; cat "$RUNNER_OUT"; exit 1; }
wait_exit "$RUNNER_PID" 60; status=$?
[ "$status" -eq 124 ] && pass "a batch with no request times out with 124" || fail "a batch with no request times out with 124 (got $status)"
grep -q "batch deadline" "$RUNNER_OUT" && pass "timeout names the batch deadline" || fail "timeout names the batch deadline"
[ "$(support_dirs)" = "$SUPPORT_BEFORE" ] && [ "$(scratch_dirs)" = "$SCRATCH_BEFORE" ] && pass "cleanup after timeout" || fail "cleanup after timeout"
RUNNER_PID=

echo "== stop marker and resume"
BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS=30 start_runner stop
wait_state || { fail "runner starts for the stop case"; cat "$RUNNER_OUT"; exit 1; }
FIRST_RUN=$(state_field runId)
FIRST_EVIDENCE=$(state_field evidence)
result=$(runner_request launch)
PIDS=$($PYTHON -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$result" 2>/dev/null)
$PYTHON "$PHASE" --state "$STATE" stop --reason "test stop" > "$WORK/stop.json" 2>&1 \
  && pass "phase.py stop writes the owned marker" || { fail "phase.py stop writes the owned marker"; cat "$WORK/stop.json"; }
wait_exit "$RUNNER_PID" 80; status=$?
[ "$status" -eq 0 ] && pass "stop marker ends the runner with 0" || fail "stop marker ends the runner with 0 (got $status)"
! kill -0 "$PIDS" 2>/dev/null && pass "stop ends the launched pid" || fail "stop ends the launched pid"
[ -f "$FIRST_EVIDENCE/ledger.json" ] && pass "ledger survives the runner" || fail "ledger survives the runner"
RUNNER_PID=

BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS=30 start_runner resume --resume "$FIRST_EVIDENCE"
wait_state || { fail "runner resumes an evidence directory"; cat "$RUNNER_OUT"; exit 1; }
[ "$(state_field evidence)" = "$FIRST_EVIDENCE" ] && pass "resume reuses the evidence directory" || fail "resume reuses the evidence directory"
[ "$(state_field runId)" != "$FIRST_RUN" ] && [ "$(state_field previousRunId)" = "$FIRST_RUN" ] && pass "resume gets a new run id and names the previous one" || fail "resume gets a new run id and names the previous one"
[ -f "$FIRST_EVIDENCE/fixture.$FIRST_RUN.json" ] && pass "resume archives the previous fixture.json" || fail "resume archives the previous fixture.json"
$PYTHON "$PHASE" --state "$STATE" report > "$WORK/report2.json" 2>&1
grep -q "\"$FIRST_RUN\"" "$WORK/report2.json" && pass "resumed ledger still lists the first fixture run" || fail "resumed ledger still lists the first fixture run"
$PYTHON "$PHASE" --state "$STATE" stop >/dev/null 2>&1
wait_exit "$RUNNER_PID" 80 >/dev/null
RUNNER_PID=
[ "$(support_dirs)" = "$SUPPORT_BEFORE" ] && [ "$(scratch_dirs)" = "$SCRATCH_BEFORE" ] && pass "cleanup after resume" || fail "cleanup after resume"

echo
if [ "$fails" -ne 0 ]; then
  echo "desktop-acceptance runner checks: $fails failure(s)"
  exit 1
fi
echo "desktop-acceptance runner checks: all passed"
