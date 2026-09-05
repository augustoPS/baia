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
SOURCE_EXEC="$FAKE/Contents/MacOS/baia-dev"
SOURCE_PLIST="$FAKE/Contents/Info.plist"
SOURCE_EXEC_HASH=$(/usr/bin/shasum -a 256 "$SOURCE_EXEC" | awk '{print $1}')
SOURCE_PLIST_HASH=$(/usr/bin/shasum -a 256 "$SOURCE_PLIST" | awk '{print $1}')
source_unchanged() {
  [ "$(/usr/bin/shasum -a 256 "$SOURCE_EXEC" | awk '{print $1}')" = "$SOURCE_EXEC_HASH" ] \
    && [ "$(/usr/bin/shasum -a 256 "$SOURCE_PLIST" | awk '{print $1}')" = "$SOURCE_PLIST_HASH" ]
}
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
exec_name=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$ISOLATED_APP/Contents/Info.plist")
bundle_name=$(/usr/bin/plutil -extract CFBundleName raw -o - "$ISOLATED_APP/Contents/Info.plist")
display_name=$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$ISOLATED_APP/Contents/Info.plist")
[ "$exec_name" != "baia-dev" ] && [ "$exec_name" != "baia" ] \
  && pass "copied CFBundleExecutable is not the Debug process name" \
  || fail "copied CFBundleExecutable is not the Debug process name (got $exec_name)"
[ "$(basename "$ISOLATED_BINARY")" = "$exec_name" ] \
  && pass "copied binary basename matches CFBundleExecutable" \
  || fail "copied binary basename matches CFBundleExecutable"
[ ! -e "$ISOLATED_APP/Contents/MacOS/baia-dev" ] \
  && pass "copied MacOS directory no longer contains baia-dev" \
  || fail "copied MacOS directory no longer contains baia-dev"
[ "$bundle_name" = "$exec_name" ] \
  && pass "CFBundleName matches the unique executable" \
  || fail "CFBundleName matches the unique executable (got $bundle_name vs $exec_name)"
[ "$display_name" = "$exec_name" ] \
  && pass "CFBundleDisplayName matches the unique executable" \
  || fail "CFBundleDisplayName matches the unique executable (got $display_name vs $exec_name)"
source_unchanged \
  && pass "prepare leaves the source app bytes unchanged" \
  || fail "prepare leaves the source app bytes unchanged"
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

exec1=$exec_name
copy2=$(
  ROOT="$ROOT"
  ISOLATED_LABEL=isolated-test
  ISOLATED_SOURCE_APP="$FAKE"
  ISOLATED_EVIDENCE=$(mktemp -d "${TMPDIR:-/tmp}/baia-isolated-evidence-exec.XXXXXX")
  # shellcheck source=isolated-app.sh
  source "$HERE/isolated-app.sh"
  isolated_prepare
  plist="$ISOLATED_APP/Contents/Info.plist"
  printf '%s\t%s\t%s' \
    "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist")" \
    "$(/usr/bin/plutil -extract CFBundleName raw -o - "$plist")" \
    "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$plist")"
  isolated_teardown >/dev/null
  rm -rf "$ISOLATED_EVIDENCE"
)
exec2=$(printf '%s' "$copy2" | awk -F '\t' '{print $1}')
bundle2=$(printf '%s' "$copy2" | awk -F '\t' '{print $2}')
display2=$(printf '%s' "$copy2" | awk -F '\t' '{print $3}')
[ -n "$exec2" ] && [ "$exec1" != "$exec2" ] && [ "$exec2" != "baia-dev" ] \
  && pass "two live copies receive distinct CFBundleExecutable names" \
  || fail "two live copies receive distinct CFBundleExecutable names ($exec1 vs $exec2)"
[ "$bundle2" = "$exec2" ] && [ "$display2" = "$exec2" ] \
  && pass "second copy Name and DisplayName match its unique executable" \
  || fail "second copy Name and DisplayName match its unique executable"
[ "$display_name" != "$display2" ] \
  && pass "two live copies receive distinct CFBundleDisplayName values" \
  || fail "two live copies receive distinct CFBundleDisplayName values ($display_name vs $display2)"
source_unchanged \
  && pass "a second prepare still leaves the source app bytes unchanged" \
  || fail "a second prepare still leaves the source app bytes unchanged"

if (
  ROOT="$ROOT"
  ISOLATED_LABEL=isolated-force
  ISOLATED_SOURCE_APP="$FAKE"
  ISOLATED_FORCE_PREPARE_FAILURE=1
  unset ISOLATED_EVIDENCE
  # shellcheck source=isolated-app.sh
  source "$HERE/isolated-app.sh"
  isolated_prepare
); then
  fail "forced prepare failure is honoured"
else
  pass "forced prepare failure is honoured"
fi
source_unchanged \
  && pass "forced prepare failure leaves the source app bytes unchanged" \
  || fail "forced prepare failure leaves the source app bytes unchanged"

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

# New helpers: default config, pane refusal, launch of the copied fake binary.
isolated_prepare
cfg_saved=$ISOLATED_CONFIG
unset ISOLATED_CONFIG
if isolated_default_config files 2>/dev/null; then
  fail "default_config fails when ISOLATED_CONFIG is unset"
else
  pass "default_config fails when ISOLATED_CONFIG is unset"
fi
ISOLATED_CONFIG=$cfg_saved
isolated_default_config files
grep -q '"sidebar": "files"' "$ISOLATED_CONFIG" \
  && [ "$ISOLATED_CONFIG" != "$HOME/.config/baia/config.json" ] \
  && pass "default config writes the isolated file" \
  || fail "default config writes the isolated file"
bin_saved=$ISOLATED_BINARY
ISOLATED_BINARY="/no/such/isolated-binary-$$"
if isolated_launch 2>/dev/null; then
  fail "launch fails when the copied executable is missing"
else
  pass "launch fails when the copied executable is missing"
fi
ISOLATED_BINARY=$bin_saved
printf 'x\n' > "$ISOLATED_OUT/not-a-dir"
if isolated_launch "$ISOLATED_OUT/not-a-dir/app.log" 2>/dev/null; then
  fail "launch fails when the log directory cannot be created"
else
  pass "launch fails when the log directory cannot be created"
fi
mkdir -p "$ISOLATED_OUT/log-is-dir"
if isolated_launch "$ISOLATED_OUT/log-is-dir" 2>/dev/null; then
  fail "launch fails when the log file cannot be opened"
else
  pass "launch fails when the log file cannot be opened"
fi
(
  BAIA_PANE=probe-pane
  isolated_refuse_pane
) && fail "refuse_pane fails when BAIA_PANE is set" \
  || pass "refuse_pane fails when BAIA_PANE is set"
unset BAIA_PANE
isolated_refuse_pane \
  && pass "refuse_pane succeeds outside a pane" \
  || fail "refuse_pane succeeds outside a pane"

cat > "$ISOLATED_OUT/pause.c" <<'EOF'
#include <unistd.h>
int main(void) { for (;;) pause(); }
EOF
cc -o "$ISOLATED_BINARY" "$ISOLATED_OUT/pause.c"
isolated_launch
if isolated_app_is_running; then
  pass "launch records a live copied-binary child"
else
  fail "launch records a live copied-binary child"
fi
isolated_stop_owned_process || true
if isolated_app_is_running; then
  fail "stop ends the launched child"
else
  pass "stop ends the launched child"
fi
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
