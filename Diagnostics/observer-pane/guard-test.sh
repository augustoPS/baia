#!/usr/bin/env bash
# Feeds the guard PreToolUse payloads and asserts its exit code.
# A denied command must exit 2. An allowed one must exit 0.
set -uo pipefail
cd "$(dirname "$0")"

GUARD=./guard-baia-alive.sh
fails=0

check() {                       # check <expected-exit> <command-string>
  local want="$1" cmd="$2" got
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    printf 'FAIL want=%s got=%s  %s\n' "$want" "$got" "$cmd"
    fails=$((fails + 1))
  else
    printf 'ok   %s  %s\n' "$want" "$cmd"
  fi
}

# Denied: every route to killing the app that hosts this run.
check 2 './Diagnostics/control-channel/run.sh'
check 2 'cd ~/Projects/baia && ./Diagnostics/footer-corners/run.sh'
check 2 'make run'
check 2 'make run-attached'
check 2 'pkill -x baia'
check 2 'pkill baia'
check 2 'osascript -e '"'"'quit app "baia"'"'"''
check 2 'open .build/Build/Products/Debug/baia-dev.app'
# Both bundles, because there are two now. The Debug product became
# `baia-dev.app` on 2026-08-02 so a build under test can run beside the installed
# copy, and `baia-dev.app` does not contain the substring `baia.app`: the guard's
# old pattern matched neither the bundle an executor is near nor the one in
# /Applications. Opening either launches an instance that takes a socket.
check 2 'open /Applications/baia.app'
check 2 'echo hi; pkill -x baia'

# Denied behind an rtk prefix. `rtk hook claude` rewrites commands before the
# permission check, so the executors' allowlist carries `Bash(rtk:*)`, and
# `rtk proxy` runs its argument raw with no filtering at all.
#
# Every line here was ALLOWED on 2026-08-01 while its bare form was denied, which
# is the whole deny list bypassed by a nine-character prefix. The bare forms above
# passed the entire time, so this arm is what the guard was missing rather than
# what it had.
check 2 'rtk proxy pkill -x baia'
check 2 'rtk proxy make run'
check 2 'rtk proxy open .build/Build/Products/Debug/baia-dev.app'
check 2 'rtk proxy osascript -e '"'"'quit app "baia"'"'"''
check 2 'rtk make run'
check 2 'echo hi; rtk proxy pkill baia'

# Allowed: the whole verification loop, and things that merely mention the word.
check 0 'make test'
check 0 'swift test --package-path Packages/WorkspaceLayout'
check 0 'git -C . status --short'
check 0 'grep -rn "baia" Sources/'
check 0 'cat Diagnostics/control-channel/README.md'
check 0 'baia list --tree'

# The rewritten forms the executors actually run, measured with `rtk rewrite` on
# 2026-08-01. The prefix arm above must not make ordinary work look dangerous.
check 0 'rtk make test'
check 0 'rtk git status'
check 0 'rtk read Diagnostics/observer-pane/README.md'
check 0 'rtk grep -rn "baia" Sources/'
check 0 'rtk swift test'

if [ "$fails" -gt 0 ]; then printf '\n%d check(s) failed\n' "$fails"; exit 1; fi

# ── Negative control ────────────────────────────────────────────────────
# In the red phase every check above failed at 127, so the allow arm proved
# nothing: a guard that denies everything would have looked identical. This
# damages the guard in the way it is most likely to be wrong, by matching the
# word rather than the command, and asserts the allow arm catches it.
control=$(mktemp)
cat > "$control" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
COMMAND=$(cat | jq -r '.tool_input.command // empty')
printf '%s' "$COMMAND" | grep -qE 'baia' && exit 2
exit 0
EOF
chmod +x "$control"
printf '{"tool_input":{"command":%s}}' "$(printf '%s' 'grep -rn "baia" Sources/' | jq -Rs .)" \
  | "$control" >/dev/null 2>&1
if [ "$?" != 2 ]; then
  printf '\nnegative control did not fail: the allow arm cannot catch an over-broad guard\n'
  rm -f "$control"; exit 1
fi
rm -f "$control"
printf 'ok   ctl  an over-broad guard is caught by the allow arm\n'

printf '\nall checks passed\n'
