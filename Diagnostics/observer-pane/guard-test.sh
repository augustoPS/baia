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

# Denied for taking the screen rather than for killing anything. Both open a key
# window and activate; `fullscreen-strip` also runs an event loop and drives its
# window in and out of full screen twice. Neither quits baia, so these two are
# the reason the deny message names focus as well as launching.
check 2 'cd ~/Projects/baia && ./Diagnostics/footer-corners/run.sh'
check 2 './Diagnostics/fullscreen-strip/run.sh'
# Denied for the same focus reason, and pinned here because its safe sibling
# `cluster-wires` is allowed below: the card probe's subject is the cluster
# cards' key discipline, so like `design-panel-key` it takes the keyboard on
# purpose and no version of it could qualify.
check 2 './Diagnostics/cluster-card-key/run.sh'

# The five that take no focus are allowed, and a command pairing one with a real
# driver is not. Without that last pair the carve-out is a hole: naming a safe
# probe anywhere in the command would clear the whole line.
#
# `clip-layout`, `theme-refresh` and `pane-resize` each build an `NSWindow`, and
# are allowed anyway because each sets an `.accessory` or `.prohibited`
# activation policy before showing anything, so the window never becomes key. If
# one of them ever calls `makeKeyAndOrderFront`, it belongs above with the other
# two and this line should start failing.
check 0 './Diagnostics/theme-catalog/run.sh'
check 0 './Diagnostics/app-icon/run.sh'
check 0 'cd ~/Projects/baia && ./Diagnostics/app-icon/run.sh'
check 0 './Diagnostics/clip-layout/run.sh'
check 0 './Diagnostics/theme-refresh/run.sh'
check 0 'cd ~/Projects/baia && ./Diagnostics/pane-resize/run.sh'
# The three members added since this block was written. None had a check, so
# adding a probe to SAFE_PROBES was invisible to this file until 2026-08-11.
check 0 './Diagnostics/glass-backdrop/run.sh'
check 0 './Diagnostics/override-wires/run.sh'
check 0 './Diagnostics/cluster-wires/run.sh'
check 0 './Diagnostics/footer-accessory/run.sh'
check 2 './Diagnostics/app-icon/run.sh; ./Diagnostics/path-picker/run.sh'
check 2 './Diagnostics/theme-catalog/run.sh && ./Diagnostics/control-channel/run.sh'
check 2 './Diagnostics/clip-layout/run.sh; ./Diagnostics/footer-corners/run.sh'
# `make run` and the dev bundle were unblocked 2026-08-07 (owner's call,
# recorded in the guard): since the product split, `make run` is a bare
# detached `open` of `baia-dev.app`, which owns its own bundle id, support
# directory and socket, so launching it kills nothing and takes nothing.
# These five expected deny until 2026-08-11 — the guard had been taught the
# ruling and this file had not, so every run reported five failures against
# behavior that was correct.
check 0 'make run'
check 0 'open .build/Build/Products/Debug/baia-dev.app'
check 2 'make run-attached'
check 2 'pkill -x baia'
check 2 'pkill baia'
check 2 'osascript -e '"'"'quit app "baia"'"'"''
# The installed bundle stays denied, because there are two now. The Debug
# product became `baia-dev.app` on 2026-08-02 so a build under test can run
# beside the installed copy, and `baia-dev.app` does not contain the substring
# `baia.app`: the guard's old pattern matched neither. Opening the installed
# copy activates the daily driver and pulls focus off its panes.
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
# The rtk-prefixed forms of the two 2026-08-07 unblocks follow the bare forms:
# the prefix must never widen what is allowed, and these show it does not
# narrow it either.
check 0 'rtk proxy make run'
check 0 'rtk proxy open .build/Build/Products/Debug/baia-dev.app'
check 2 'rtk proxy osascript -e '"'"'quit app "baia"'"'"''
check 0 'rtk make run'
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
