#!/bin/bash
# Builds baia, launches it, and exercises the control channel over its real
# socket. Output goes to a scratch directory; the only things this writes outside
# it are `config.json` and `session.json`, both of which are backed up before the
# first write and restored on the way out however the run ends.
#
# **Every control goes through the socket.** Not one of them calls a Swift
# function, and that is the lesson this directory already paid for: a probe that
# verified a helper directly stayed green while the integration it was protecting
# was deleted. `probe.py` writes bytes to `$BAIA_SOCK` and reads bytes back, so a
# control here fails when the wire stops behaving, which is the only claim worth
# making about a wire.
#
# **Where the pane capabilities come from, and why that is a readout rather than
# a forgery.** A pane's token is minted per pane per run and injected into its
# shell's environment as `$BAIA_TOKEN`; it is never written to disk and there is
# no verb that hands one out. Nothing here can type into a pane, so the shells
# are asked to report their own environment instead: the app is launched with
# `ZDOTDIR` pointing at a directory this script writes, whose `.zshenv` copies
# `$BAIA_PANE` and `$BAIA_TOKEN` into the scratch directory. The values are the
# app's own, issued by the app to the pane, and they reach the socket the way a
# pane's `baia` would. The panes of a probe run therefore start with none of the
# owner's shell configuration, deliberately: what a pane's dotfiles do must not
# be able to change what this run proves.
#
# **How to check that a control can fail**, which is the only thing that makes a
# green run mean anything. Damage the protection in the source, run this, watch
# it go red, and put it back. For the finding that must not silently come back:
#
#   in Packages/PaneControl/Sources/PaneControl/PaneGraph.swift, in `authorize`,
#   replace the two guards
#
#       guard secret.parsesAsPaneID == false else { return .denied(.badToken) }
#       guard let actor = registry[secret] else { return .denied(.badToken) }
#
#   with a resolver that also accepts a pane id, which is the mistake the plan
#   names: one `if let` that lets the read verbs "keep working with the ids they
#   return"
#
#       let actor: ControlPaneID
#       if let resolved = registry[secret] {
#           actor = resolved
#       } else if let byID = registry.values.first(where: { $0.description == token }) {
#           actor = byID
#       } else {
#           return .denied(.badToken)
#       }
#
#   Both pane-id controls then answer `ok` and this script exits 1 naming them.
#
# Exits non-zero if any arm or any control fails.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-control-channel-probe
TOKENS="$OUT/tokens"
SHELLS="$OUT/shells"
ZDOT="$OUT/zdot"
BACKUP="$OUT/backup"

CONFIG="$HOME/.config/baia/config.json"
SESSION="$HOME/Library/Application Support/baia/session.json"
SOCKET="$HOME/Library/Application Support/baia/control.sock"
BINARY="$ROOT/.build/Build/Products/Debug/baia.app/Contents/MacOS/baia"

# A second baia would own the socket, and the instance this script launches would
# then run with no channel at all and inject no `$BAIA_TOKEN`, which surfaces as
# a probe that never sees a capability. Refused up front with the reason, rather
# than killing an app somebody is using.
if pgrep -f "baia.app/Contents/MacOS/baia" > /dev/null; then
  echo "a baia is already running, and it owns $SOCKET."
  echo "quit it before running this probe: the instance launched here would get"
  echo "no control channel and no pane would receive a capability."
  exit 1
fi

rm -rf "$OUT"
# 077 for the whole run, because `$TOKENS` holds live `$BAIA_TOKEN` values read
# out of the panes' own shells. Mode is the weaker half of the answer and the
# teardown is the stronger one: a same-uid process is the adversary this channel
# is designed against, so 0700 excludes nobody who matters. What keeps the window
# short is that the file dies with the run.
umask 077
mkdir -p "$TOKENS" "$SHELLS" "$ZDOT" "$BACKUP"
chmod 700 "$OUT" "$TOKENS" "$SHELLS"
cd "$ROOT"

# The probe is worth nothing against a build that is not the source in the tree.
make build

# Backed up before the first write, and restored by the trap below however this
# ends. Absence is recorded rather than papered over: a machine that has never
# run baia has neither file, and leaving the probe's own copies behind would be
# this script inventing a workspace the owner never had.
CONFIG_EXISTED=no
SESSION_EXISTED=no
mkdir -p "$(dirname "$CONFIG")" "$(dirname "$SESSION")"
if [ -f "$CONFIG" ]; then cp "$CONFIG" "$BACKUP/config.json"; CONFIG_EXISTED=yes; fi
if [ -f "$SESSION" ]; then cp "$SESSION" "$BACKUP/session.json"; SESSION_EXISTED=yes; fi

APP_PID=

teardown() {
  local status=$?
  if [ -n "$APP_PID" ]; then
    kill -TERM "$APP_PID" 2> /dev/null || true
    # Long enough for the app to drop its socket, short enough that a wedged
    # instance does not hold the run open.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$APP_PID" 2> /dev/null || break
      sleep 0.3
    done
    kill -KILL "$APP_PID" 2> /dev/null || true
    wait "$APP_PID" 2> /dev/null || true
  fi
  if [ "$CONFIG_EXISTED" = yes ]; then cp "$BACKUP/config.json" "$CONFIG"; else rm -f "$CONFIG"; fi
  if [ "$SESSION_EXISTED" = yes ]; then cp "$BACKUP/session.json" "$SESSION"; else rm -f "$SESSION"; fi
  # The probe's instance was killed rather than quit, so the socket file outlives
  # it. baia unlinks a socket nobody answers on when it next binds, but leaving a
  # dead one behind is one more thing for the next reader to wonder about.
  rm -f "$SOCKET"
  # Last, and after the restores above have read their copies out of `$BACKUP`.
  # `$TOKENS` holds live pane capabilities, and a probe that leaves capabilities
  # in a file is the test harness breaking the rule it was written to enforce.
  # They are already worthless by now, since the app they belong to was killed at
  # the top of this function and every secret is minted per run, but "worthless
  # because of something that happened three lines ago" is not a property to
  # leave a reader to reconstruct.
  rm -rf "$OUT"
  return $status
}
trap teardown EXIT
# The two signals a run is stopped with, named so an interrupted probe
# still puts the owner's two files back rather than leaving its own behind.
trap 'exit 130' INT
trap 'exit 143' TERM

# Three panes, because the scope arms need panes that alpha is not entitled to
# see. The ids are fixed so a failure names something a reader can grep for, and
# they are read back out of this file by the probe: the pane-id-as-token control
# has to use an id that a same-uid process could find on disk.
ALPHA=BA1AC0DE-0000-4000-8000-000000000001
BRAVO=BA1AC0DE-0000-4000-8000-000000000002
CHARLIE=BA1AC0DE-0000-4000-8000-000000000003
cat > "$SESSION" <<EOF
{
  "panes": [
    { "id": { "rawValue": "$ALPHA" }, "workingDirectory": "$OUT" },
    { "id": { "rawValue": "$BRAVO" }, "workingDirectory": "$OUT" },
    { "id": { "rawValue": "$CHARLIE" }, "workingDirectory": "$OUT" }
  ],
  "schemaVersion": 1,
  "sidebar": { "splitHeight": 48, "width": 320 },
  "workspace": {
    "tabs": [
      {
        "id": "BA1AC0DE-0000-4000-8000-0000000000AA",
        "focusedPane": { "rawValue": "$ALPHA" },
        "tree": {
          "split": {
            "axis": "horizontal",
            "ratio": 0.5,
            "first": { "leaf": { "_0": { "rawValue": "$ALPHA" } } },
            "second": {
              "split": {
                "axis": "vertical",
                "ratio": 0.5,
                "first": { "leaf": { "_0": { "rawValue": "$BRAVO" } } },
                "second": { "leaf": { "_0": { "rawValue": "$CHARLIE" } } }
              }
            }
          }
        }
      }
    ],
    "focusedTabIndex": 0
  },
  "windowFrame": { "x": 120, "y": 120, "width": 1100, "height": 720 }
}
EOF

# The channel on and `run` off, which is the shipped default and the state the
# config controls start from. Written whole rather than edited, so the run does
# not depend on what the owner's file happens to contain.
cat > "$CONFIG" <<EOF
{
  "controlChannelEnabled": true,
  "controlAllowRun": false,
  "restoreSession": true,
  "notificationsEnabled": false
}
EOF

# The readout. `.zshenv` is read by every zsh, login or not, before anything
# else, so a pane reports its capability the moment its shell starts and without
# anybody typing.
cat > "$ZDOT/.zshenv" <<EOF
printf 'pane=%s\ntoken=%s\nsock=%s\n' "\$BAIA_PANE" "\$BAIA_TOKEN" "\$BAIA_SOCK" \
  > "$TOKENS/pane-\$\$.env"
EOF

# The second plant, and it has to be `.zshrc` rather than `.zshenv`. zsh reads
# `.zshenv` before `/etc/zprofile`, which is where `path_helper` runs, so the
# readout above sees a PATH that nothing has rebuilt yet. `.zshrc` is read after
# zprofile for a login shell, which is the only place the real question can be
# asked: does the injected `Contents/Helpers` survive `login -flp` plus
# `path_helper` plus whatever the owner's own startup files do.
#
# It does not stop at looking. It RUNS the helper, so the same check also proves
# the embedded tool executes under hardened runtime with an ad-hoc signature,
# from inside a real pane, through the whole spawn chain. Both were on the
# by-hand list until it turned out a plant could answer them.
#
# It also carries the probe's two arms, and they come first. Nothing here can
# type into a pane, so a check that needs a pane to DO something plants a file
# and splits: a shell started while the file is there obeys it, and the probe
# removes it again so only the panes it means to steer are steered. The arms sit
# above the readout because an armed pane is not being asked the PATH question,
# and running `baia` in one would put a second activity through the ring under
# the event the check is reading.
#
#   arm-churn     the pane closes itself, which is the cheapest pair of ring
#                 events a script can cause: one open and one close per split.
#   arm-activity  the pane runs a long `sleep` as a child of its shell, which is
#                 what `activityChanged` is supposed to notice. A child and not
#                 an `exec`, because the classifier excludes the shell's own pid
#                 and an exec'd sleep would read as an idle shell.
cat > "$ZDOT/.zshrc" <<EOF
if [ -e "$OUT/arm-churn" ]; then
  baia close > /dev/null 2>&1
fi
if [ -e "$OUT/arm-activity" ]; then
  sleep 45
fi

{
  printf 'pane=%s\n' "\$BAIA_PANE"
  printf 'which=%s\n' "\$(command -v baia 2> /dev/null || echo NOT-ON-PATH)"
  printf 'whoami_exit=%s\n' "\$(baia whoami > /dev/null 2>&1; echo \$?)"
} > "$SHELLS/pane-\$\$.env" 2>&1
EOF

# The binary rather than "open", which would hand the app LaunchServices'
# environment and lose the ZDOTDIR the readout depends on.
ZDOTDIR="$ZDOT" "$BINARY" > "$OUT/app.log" 2>&1 &
APP_PID=$!
# Off the job table, so bash does not print its own "Terminated" line under the
# probe's last assertion when the teardown kills it.
disown "$APP_PID" 2> /dev/null || true
echo "launched baia as pid $APP_PID; its stderr is at $OUT/app.log"

# Waiting on the capabilities rather than on the socket: a socket that binds but
# hands out nothing is the failure mode of an instance that found the channel
# already owned, and the message below is the one that explains it.
for _ in $(seq 1 60); do
  reported=$(ls "$TOKENS" 2> /dev/null | wc -l | tr -d ' ')
  if [ "$reported" -ge 3 ] && [ -S "$SOCKET" ]; then break; fi
  sleep 0.5
done
if [ ! -S "$SOCKET" ]; then
  echo "no socket at $SOCKET after 30 seconds. The app's own log:"
  cat "$OUT/app.log"
  exit 1
fi
if [ "$(ls "$TOKENS" | wc -l | tr -d ' ')" -lt 3 ]; then
  echo "the panes reported fewer than three capabilities after 30 seconds, so"
  echo "either the panes came up without a channel or the readout is broken."
  echo "the app's own log:"
  cat "$OUT/app.log"
  exit 1
fi

echo
/usr/bin/python3 "$HERE/probe.py" "$SOCKET" "$TOKENS" "$CONFIG" "$SESSION" "$SHELLS" "$OUT"
