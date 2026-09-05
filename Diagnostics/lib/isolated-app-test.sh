#!/usr/bin/env bash
# Static checks for isolated-app.sh. Builds a fake bundle, copies it the way a
# probe would, and never launches baia.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

FAKE=$(mktemp -d "${TMPDIR:-/tmp}/baia-isolated-fake.XXXXXX")
SLEEP_PID=
cleanup_test() {
  if [ -n "${SLEEP_PID:-}" ]; then
    kill -KILL "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  rm -rf "$FAKE" "${FAKE_BAD:-}"
  if [ -n "${ISOLATED_SUPPORT:-}" ]; then
    rm -rf "$ISOLATED_SUPPORT"
  fi
  if [ -n "${ISOLATED_OUT:-}" ]; then
    rm -rf "$ISOLATED_OUT"
  fi
  if [ -n "${ISOLATED_EVIDENCE:-}" ]; then
    rm -rf "$ISOLATED_EVIDENCE"
  fi
  if [ -n "${DECOY_SUPPORT:-}" ]; then
    rm -rf "$DECOY_SUPPORT"
  fi
}
trap cleanup_test EXIT

mkdir -p "$FAKE/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/Contents/MacOS/baia-dev"
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

ISOLATED_LABEL=isolated-test
ISOLATED_SOURCE_APP="$FAKE"
ISOLATED_EVIDENCE=$(mktemp -d "${TMPDIR:-/tmp}/baia-isolated-evidence.XXXXXX")
# shellcheck source=isolated-app.sh
source "$HERE/isolated-app.sh"

parent=$(isolated_scratch_parent)
[ "$parent" = "${parent%/}" ] && [ -n "$parent" ] \
  && pass "scratch parent has no trailing slash" \
  || fail "scratch parent has no trailing slash (got $parent)"
(
  TMPDIR="${parent}/"
  [ "$(isolated_scratch_parent)" = "$parent" ]
) && pass "trailing-slash TMPDIR normalizes to the same parent" \
  || fail "trailing-slash TMPDIR normalizes to the same parent"
(
  TMPDIR="${parent}///"
  ROOT="$ROOT"
  ISOLATED_LABEL=isolated-test
  ISOLATED_SOURCE_APP="$FAKE"
  unset ISOLATED_EVIDENCE
  # shellcheck source=isolated-app.sh
  source "$HERE/isolated-app.sh"
  isolated_prepare
  case "$ISOLATED_OUT" in *//*) exit 1 ;; esac
  case "$ISOLATED_BINARY" in *//*) exit 1 ;; esac
  case "$ISOLATED_EVIDENCE" in *//*) exit 1 ;; esac
  isolated_teardown >/dev/null
) && pass "prepare under trailing-slash TMPDIR keeps a single separator" \
  || fail "prepare under trailing-slash TMPDIR keeps a single separator"

# A PID-only name left behind by an earlier scheme must not be claimed.
DECOY_SUPPORT="$HOME/Library/Application Support/baia-isolated-test-$$"
mkdir -p "$DECOY_SUPPORT"

isolated_prepare

id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$ISOLATED_APP/Contents/Info.plist")
support_name=$(/usr/bin/plutil -extract BAIASupportDirectory raw -o - "$ISOLATED_APP/Contents/Info.plist")
case "$id" in
  pasqualotto.baia.isolated-test.*) pass "copied bundle identifier is unique" ;;
  *) fail "copied bundle identifier is unique (got $id)" ;;
esac
[ "$support_name" != "baia-isolated-test-$$" ] \
  && pass "support directory name is not PID-only" \
  || fail "support directory name is not PID-only (got $support_name)"
[ "$ISOLATED_SUPPORT" != "$DECOY_SUPPORT" ] \
  && pass "prepare does not reuse an existing PID-named support directory" \
  || fail "prepare does not reuse an existing PID-named support directory"
[ "$ISOLATED_SUPPORT" != "$HOME/Library/Application Support/baia-dev" ] \
  && pass "support path is not the Debug directory" \
  || fail "support path is not the Debug directory"
[ "$ISOLATED_CONFIG" != "$HOME/.config/baia/config.json" ] \
  && pass "config path is not the shared config" \
  || fail "config path is not the shared config"
[ -x "$ISOLATED_BINARY" ] \
  && pass "copied executable is present" \
  || fail "copied executable is present"
case "$ISOLATED_OUT" in
  *//*) fail "scratch out has no doubled slash (got $ISOLATED_OUT)" ;;
  *) pass "scratch out has no doubled slash" ;;
esac
case "$ISOLATED_BINARY" in
  *//*) fail "copied binary path has no doubled slash (got $ISOLATED_BINARY)" ;;
  *) pass "copied binary path has no doubled slash" ;;
esac
[ -f "$ISOLATED_SUPPORT/$ISOLATED_MARKER_NAME" ] \
  && pass "support directory carries this run's marker" \
  || fail "support directory carries this run's marker"
rmdir "$DECOY_SUPPORT" 2>/dev/null || rm -rf "$DECOY_SUPPORT"
DECOY_SUPPORT=

isolated_acknowledge
[ -f "$ISOLATED_SUPPORT/command-execution.ack" ] \
  && pass "acknowledgement marker is written under the unique support directory" \
  || fail "acknowledgement marker is written under the unique support directory"

# Second live prepare must get a different support identity while the first exists.
name1=$ISOLATED_SUPPORT_NAME
name2=$(
  ROOT="$ROOT"
  ISOLATED_LABEL=isolated-test
  ISOLATED_SOURCE_APP="$FAKE"
  ISOLATED_EVIDENCE=$(mktemp -d "${TMPDIR:-/tmp}/baia-isolated-evidence2.XXXXXX")
  # shellcheck source=isolated-app.sh
  source "$HERE/isolated-app.sh"
  isolated_prepare
  printf '%s' "$ISOLATED_SUPPORT_NAME"
  isolated_teardown >/dev/null
  rm -rf "$ISOLATED_EVIDENCE"
)
[ -n "$name2" ] && [ "$name1" != "$name2" ] \
  && pass "two live prepares receive distinct support directory names" \
  || fail "two live prepares receive distinct support directory names ($name1 vs $name2)"

printf 'secret=probe-token\n' > "$ISOLATED_OUT/capability.env"

# Mismatch: a live sleep is recorded as the isolated pid. Cleanup must not signal it.
/bin/sleep 30 &
SLEEP_PID=$!
isolated_record_child "$SLEEP_PID"
isolated_teardown >/dev/null
if kill -0 "$SLEEP_PID" 2>/dev/null; then
  pass "mismatch pid is not signalled"
else
  fail "mismatch pid is not signalled"
  SLEEP_PID=
fi
if [ -n "$SLEEP_PID" ]; then
  kill -KILL "$SLEEP_PID" 2>/dev/null || true
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=
fi

# Exited child: the fake binary returns immediately. After wait, cleanup must
# reap without signalling a replacement.
isolated_prepare
"$ISOLATED_BINARY" &
exited_pid=$!
isolated_record_child "$exited_pid"
wait "$exited_pid"
isolated_teardown >/dev/null
if kill -0 "$exited_pid" 2>/dev/null; then
  fail "exited child was reaped"
else
  pass "exited child was reaped without a post-exit KILL"
fi

# Refuses to delete a support directory this run did not mark.
isolated_prepare
foreign=$(mktemp -d "$HOME/Library/Application Support/baia-isolated-test.XXXXXX")
if isolated_rm_owned "$foreign" "$foreign" 2>/dev/null; then
  fail "unmarked support directory is not deleted"
else
  [ -d "$foreign" ] && pass "unmarked support directory is not deleted" \
    || fail "unmarked support directory is not deleted"
fi
rm -rf "$foreign"
isolated_teardown >/dev/null

# A recorded process that outlives SIGKILL must fail teardown and keep its trees.
isolated_prepare
if (
  isolated_stop_owned_process() { ISOLATED_PROCESS_RETAINED=1; return 1; }
  isolated_teardown
); then
  fail "teardown fails when the recorded process is still alive"
else
  pass "teardown fails when the recorded process is still alive"
fi
[ -d "$ISOLATED_OUT" ] \
  && pass "alive process retains the app tree" \
  || fail "alive process retains the app tree"
[ -d "$ISOLATED_SUPPORT" ] \
  && pass "alive process retains the support directory" \
  || fail "alive process retains the support directory"
isolated_teardown >/dev/null

# Partial prepare: copy succeeds, executable is missing, created dirs go away.
FAKE_BAD=$(mktemp -d "${TMPDIR:-/tmp}/baia-isolated-fake-bad.XXXXXX")
mkdir -p "$FAKE_BAD/Contents/MacOS"
cat > "$FAKE_BAD/Contents/Info.plist" <<'EOF'
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
ISOLATED_SOURCE_APP="$FAKE_BAD"
rm -rf "$ISOLATED_EVIDENCE"
ISOLATED_EVIDENCE=$(mktemp -d "${TMPDIR:-/tmp}/baia-isolated-evidence-bad.XXXXXX")
if isolated_prepare; then
  fail "prepare fails when the copied executable is missing"
  isolated_teardown >/dev/null
else
  pass "prepare fails when the copied executable is missing"
fi
[ ! -d "${ISOLATED_CREATED_OUT:-}" ] && [ ! -d "${ISOLATED_OUT:-}" ] \
  && pass "partial prepare deletes its temporary tree" \
  || fail "partial prepare deletes its temporary tree"
[ -z "${ISOLATED_CREATED_SUPPORT:-}" ] \
  && pass "partial prepare forgets the claimed support directory" \
  || fail "partial prepare forgets the claimed support directory"

# Restore a successful instance for the remaining hash assertion.
ISOLATED_SOURCE_APP="$FAKE"
rm -rf "$ISOLATED_EVIDENCE"
ISOLATED_EVIDENCE=$(mktemp -d "${TMPDIR:-/tmp}/baia-isolated-evidence-final.XXXXXX")
isolated_prepare
isolated_teardown >/dev/null
[ "${ISOLATED_FINGERPRINT_STATUS:-1}" -eq 0 ] \
  && pass "normal config/session/ack fingerprints were unchanged" \
  || fail "normal config/session/ack fingerprints were unchanged"

if [ "$fails" -ne 0 ]; then
  echo "$fails isolated-app check(s) failed"
  exit 1
fi
echo "all isolated-app checks passed"
