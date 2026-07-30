#!/usr/bin/env bash
# Installs and uninstalls the agent hook against a fixture home, never yours.
#
#   ./Diagnostics/agent-integration/run.sh
#
# Launches nothing. It drives the real `baia` binary from the app bundle with
# `HOME` pointed at a scratch directory, so every path the installer resolves
# lands inside it.
#
# **The sandbox is the point of this probe, and it is the thing that failed
# first.** `NSHomeDirectory()` reads `getpwuid` and ignores the environment, so
# the first version of the installer wrote into the owner's real `~/.claude`
# while a run believed itself sandboxed. `Layout.home()` now takes `$HOME`, and
# the last check below is that this is still true: the owner's own settings file
# is fingerprinted before anything runs and compared after everything has, so a
# regression fails here rather than quietly editing somebody's config.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN="$ROOT/.build/Build/Products/Debug/baia.app/Contents/Helpers/baia"
SCRATCH="${TMPDIR:-/tmp}/baia-agent-integration-probe"
REAL_SETTINGS="$HOME/.claude/settings.json"

pass=0
fail=0
ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; echo "        $2"; fail=$((fail + 1)); }

[ -x "$BIN" ] || { echo "ABORT: no baia at $BIN. Run make build first." >&2; exit 2; }

# Taken before anything runs, compared after everything has.
real_before=""
[ -f "$REAL_SETTINGS" ] && real_before=$(shasum -a 256 "$REAL_SETTINGS" | cut -d' ' -f1)

if [ -d "$SCRATCH" ]; then rm -r "$SCRATCH"; fi
mkdir -p "$SCRATCH/.claude/hooks"

# A settings file holding hooks baia knows nothing about: one in an event baia
# also wants, one in an event it does not, and a key baia has never heard of.
cat > "$SCRATCH/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(git:*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/scan-secrets.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "prettier",
            "async": true
          }
        ]
      }
    ]
  },
  "theme": "dark"
}
JSON
cp "$SCRATCH/.claude/settings.json" "$SCRATCH/original.json"

echo "-- install"
HOME="$SCRATCH" "$BIN" install-hooks > "$SCRATCH/install.log" 2>&1
status=$?
[ $status -eq 0 ] && ok "install exits 0" || bad "install exits 0" "exit $status"

if [ -f "$SCRATCH/.claude/hooks/baia-agent-state.sh" ]; then
    ok "the script landed inside the fixture home"
else
    bad "the script landed inside the fixture home" "nothing under $SCRATCH/.claude/hooks/"
fi

grep -q "baia-agent-state.sh" "$SCRATCH/.claude/settings.json" \
    && ok "the fixture settings gained baia's hook" \
    || bad "the fixture settings gained baia's hook" "no reference to the script"

grep -q "scan-secrets.sh" "$SCRATCH/.claude/settings.json" \
    && ok "a foreign hook in a shared event survived" \
    || bad "a foreign hook in a shared event survived" "scan-secrets.sh is gone"

grep -q "prettier" "$SCRATCH/.claude/settings.json" \
    && ok "a foreign hook in an untouched event survived" \
    || bad "a foreign hook in an untouched event survived" "prettier is gone"

python3 - "$SCRATCH" <<'PY'
import json, sys

scratch = sys.argv[1]
before = json.load(open(scratch + "/original.json"))
after = json.load(open(scratch + "/.claude/settings.json"))

print("ok    top-level key order held" if list(before) == list(after)
      else "FAIL  top-level key order held")
print("ok    everything outside hooks is untouched"
      if all(before[k] == after[k] for k in before if k != "hooks")
      else "FAIL  everything outside hooks is untouched")

# The async key is baia's canary: it is a field baia knows nothing about, sitting
# inside a hook object baia had to walk past.
kept = after["hooks"]["PostToolUse"][0]["hooks"][0]
print("ok    an unknown key inside a foreign hook survived" if kept.get("async") is True
      else "FAIL  an unknown key inside a foreign hook survived")
PY

echo
echo "-- install again"
HOME="$SCRATCH" "$BIN" install-hooks > "$SCRATCH/second.log" 2>&1
grep -q "already installed" "$SCRATCH/second.log" \
    && ok "a second install reports nothing to do" \
    || bad "a second install reports nothing to do" "$(cat "$SCRATCH/second.log")"

echo
echo "-- uninstall"
HOME="$SCRATCH" "$BIN" install-hooks --uninstall > "$SCRATCH/uninstall.log" 2>&1
status=$?
[ $status -eq 0 ] && ok "uninstall exits 0" || bad "uninstall exits 0" "exit $status"

if diff -q "$SCRATCH/original.json" "$SCRATCH/.claude/settings.json" > /dev/null 2>&1; then
    ok "the settings file is byte-identical to what it was"
else
    bad "the settings file is byte-identical to what it was" \
        "$(diff "$SCRATCH/original.json" "$SCRATCH/.claude/settings.json" | head -6)"
fi

if [ -f "$SCRATCH/.claude/hooks/baia-agent-state.sh" ]; then
    bad "the script is gone" "still under $SCRATCH/.claude/hooks/"
else
    ok "the script is gone"
fi

if [ -f "$SCRATCH/.claude/settings.json.baia-backup" ]; then
    ok "the oldest backup survived both runs"
    diff -q "$SCRATCH/original.json" "$SCRATCH/.claude/settings.json.baia-backup" > /dev/null 2>&1 \
        && ok "and it holds the pre-install state, not a later one" \
        || bad "and it holds the pre-install state, not a later one" "it was overwritten"
else
    bad "the oldest backup survived both runs" "no .baia-backup beside the settings"
fi

echo
echo "-- a malformed file is refused, not repaired"
printf '{ "hooks": ' > "$SCRATCH/.claude/settings.json"
HOME="$SCRATCH" "$BIN" install-hooks > "$SCRATCH/broken.log" 2>&1
[ "$(cat "$SCRATCH/.claude/settings.json")" = '{ "hooks": ' ] \
    && ok "the broken file was left exactly as it was" \
    || bad "the broken file was left exactly as it was" "$(cat "$SCRATCH/.claude/settings.json")"
grep -q "not valid JSON" "$SCRATCH/broken.log" \
    && ok "and the refusal says why" \
    || bad "and the refusal says why" "$(cat "$SCRATCH/broken.log")"

echo
echo "-- the owner's own settings"
real_after=""
[ -f "$REAL_SETTINGS" ] && real_after=$(shasum -a 256 "$REAL_SETTINGS" | cut -d' ' -f1)
if [ "$real_before" = "$real_after" ]; then
    ok "unchanged by this run"
else
    bad "unchanged by this run" "THE SANDBOX LEAKED: $REAL_SETTINGS was modified"
fi

if [ -d "$SCRATCH" ]; then rm -r "$SCRATCH"; fi

echo
if [ $fail -ne 0 ]; then
    echo "FAILED $fail of $((pass + fail)) checks"
    exit 1
fi
echo "PASS: all $pass checks"
