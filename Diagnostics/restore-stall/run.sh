#!/usr/bin/env bash
# Real-app fixture for launch-time restore against a filesystem that does not
# answer. Activates a disposable app, so run it only outside a baia pane.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIBRARY_ROOT=${BAIA_DIAGNOSTICS_LIBRARY_ROOT:-$ROOT}
LIBRARY="$LIBRARY_ROOT/Diagnostics/lib/isolated-app.sh"

if [ ! -f "$LIBRARY" ]; then
  echo "restore-stall needs Diagnostics/lib/isolated-app.sh." >&2
  echo "Set BAIA_DIAGNOSTICS_LIBRARY_ROOT to the checkout that owns the shared helper." >&2
  exit 1
fi

# The support directory becomes baia-restore-stall.XXXXXX, which is the prefix
# RestoreSelfCheck requires before it will hold a restore.
ISOLATED_LABEL=restore-stall
ISOLATED_SOURCE_APP="$ROOT/.build/Build/Products/Debug/baia-dev.app"
# shellcheck source=../lib/isolated-app.sh
source "$LIBRARY"
isolated_install_traps
isolated_refuse_pane || exit 1

cd "$ROOT"
if [ "${BAIA_RESTORE_STALL_SKIP_BUILD:-${BAIA_ISOLATED_SKIP_BUILD:-0}}" != 1 ]; then
  make build
fi

isolated_prepare || exit 1
cp "$ISOLATED_FINGERPRINTS" "$ISOLATED_EVIDENCE/normal-state-before.tsv"

cat > "$ISOLATED_CONFIG" <<EOF
{"controlChannelEnabled":false,"notificationsEnabled":false,"projectRoots":["$ISOLATED_OUT"],"restoreSession":true}
EOF

# One saved group with one pane at the scratch root, in the current schema.
/usr/bin/python3 -c '
import pathlib, sys
sys.path.insert(0, sys.argv[3])
import session_oracle
pathlib.Path(sys.argv[1]).write_bytes(session_oracle.current_session(sys.argv[2]))
' "$ISOLATED_SESSION" "$ISOLATED_OUT" "$ROOT/Diagnostics/session-recovery"
SEEDED_SHA=$(shasum -a 256 "$ISOLATED_SESSION" | cut -d' ' -f1)
echo "seeded session sha256 $SEEDED_SHA"

RELEASE="$ISOLATED_OUT/release-restore"
EVENTS="$ISOLATED_EVIDENCE/restore-events.log"
rm -f "$RELEASE"
export BAIA_RESTORE_STALL_FILE="$RELEASE"
export BAIA_RESTORE_SELFCHECK_OUTPUT="$EVENTS"
isolated_launch "$ISOLATED_EVIDENCE/app.log"
PID="$ISOLATED_CHILD_PID"
echo "isolated pid $PID"

# External view of the stall: the driver inside releases it at about 0.3 s.
# Until then the process is alive and the seeded bytes are untouched. This
# sample is taken early enough to land inside that window on a normal machine
# and is recorded rather than asserted, because the driver owns the timing.
sleep 0.15
if kill -0 "$PID" 2>/dev/null && [ ! -e "$RELEASE" ]; then
  echo "external sample: process alive, stall unreleased, session sha256 $(shasum -a 256 "$ISOLATED_SESSION" | cut -d' ' -f1)"
fi

status=0
for _ in $(seq 1 160); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$PID" 2>/dev/null; then
  echo "FAIL restore-stall: isolated app did not finish within 40 seconds" >&2
  isolated_stop_owned_process || true
  status=1
else
  wait "$PID" || status=$?
  [ "$status" -eq 0 ] || echo "FAIL restore-stall: isolated app exited $status" >&2
fi
unset BAIA_RESTORE_STALL_FILE BAIA_RESTORE_SELFCHECK_OUTPUT

if [ -f "$EVENTS" ]; then
  sed 's/^/  /' "$EVENTS"
else
  echo "FAIL restore-stall: no driver events at $EVENTS" >&2
  status=1
fi
if [ "$status" -eq 0 ] && ! grep -q '^self-check failures=0$' "$EVENTS"; then
  echo "FAIL restore-stall: Debug driver did not finish cleanly" >&2
  status=1
fi

# Durable grade from outside the process: the written file holds the seeded
# group and the one opened while the restore was pending.
if [ "$status" -eq 0 ]; then
  /usr/bin/python3 - "$ISOLATED_SESSION" "$SEEDED_SHA" <<'EOF' || status=1
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if hashlib.sha256(data).hexdigest() == sys.argv[2]:
    print("FAIL durable: session file still the seeded bytes")
    sys.exit(1)
document = json.loads(data)
groups = document.get("groups", [])
tabs = [tab.get("id") for group in groups for tab in group.get("tabs", [])]
failures = []
if document.get("schemaVersion") != 2:
    failures.append("schemaVersion is not 2")
if len(groups) != 2:
    failures.append("expected 2 groups, found %d" % len(groups))
if "BA1AC0DE-0000-4000-8000-0000000000AA" not in tabs:
    failures.append("seeded tab missing: %r" % (tabs,))
if len(document.get("panes", [])) != 2:
    failures.append("expected 2 panes, found %d" % len(document.get("panes", [])))
for failure in failures:
    print("FAIL durable: " + failure)
print("durable: %d groups, tabs %r" % (len(groups), tabs))
sys.exit(1 if failures else 0)
EOF
fi

while IFS= read -r path; do
  printf '%s\t' "$path"
  isolated_fingerprint_one "$path"
done > "$ISOLATED_EVIDENCE/normal-state-after.tsv" <<EOF
$(isolated_normal_paths)
EOF
isolated_fingerprint_check || status=1

if [ "$status" -ne 0 ]; then
  echo "restore-stall evidence: $ISOLATED_EVIDENCE"
  exit "$status"
fi
echo "restore-stall: all native and durable checks passed"
echo "restore-stall evidence: $ISOLATED_EVIDENCE"
