# Control channel probe

`./run.sh` from anywhere **outside a baia pane**. It launches a disposable copy
of the Debug app, exercises the control channel over that copy's real socket,
and exits non-zero naming any check that failed. One hundred and one checks,
each printing `ok` or `FAIL`, ending in `PASS` or `FAILED n of m`.

The coordinator builds first (`make build`) or this script builds. Skip the
build with `BAIA_CONTROL_CHANNEL_SKIP_BUILD=1` or `BAIA_ISOLATED_SKIP_BUILD=1`.

This probe caught a real bug on 2026-07-30 by being unable to pass. Activity in
an event is the activity `list` reports for the same pane answered `[None,
None]`: `TerminalPaneController` gated all three pollers on `isKeyWindow` in
`viewDidAppear`, so a pane in a window that never becomes key never started
reporting activity. The isolated app here is launched from a script and is
never key.

It does not quit a running baia. The copy has its own bundle identifier,
Application Support directory, socket, config, and `ZDOTDIR`, so it can sit
beside the daily driver and the Debug app. Cleanup kills only the recorded PID.

## Isolation

`run.sh` sources `Diagnostics/lib/isolated-app.sh`. The copy is ad-hoc signed
after `Info.plist` changes. Pane tokens are written under the run's temporary
directory (mode 0700) and deleted with it. Before the first write and after
teardown, the probe fingerprints:

- `~/.config/baia/config.json`
- `~/Library/Application Support/baia/session.json`
- `~/Library/Application Support/baia-dev/session.json`
- `~/Library/Application Support/baia/command-execution.ack`
- `~/Library/Application Support/baia-dev/command-execution.ack`

Any change is a failure. There is no backup/restore of those files and no
fixed `/tmp/baia-control-channel-probe` scratch.

## Acknowledgement

`run` is `disabled` until **both** `controlAllowRun` and this installation's
`command-execution.ack` are set (`AppDelegate.effectiveAllowRun`). An isolated
support directory is empty, so the launcher seeds the marker. That is the
current contract the 101 checks encode: flipping the key then moves `disabled`
→ `refused`. An unacknowledged copy would keep `disabled` and is not a Settings
regression.

## Shell readiness

`.zshrc` retries `baia whoami` before recording the exit. A live pane must
reach 0. A pane already closed (the layout-export child, a churned split) may
record `badToken` (13); that is not a helper-PATH failure.

## Everything is on the wire

`probe.py` opens the isolated socket, writes bytes, and reads bytes. It imports
nothing the app is built from. One check goes through literal `nc -U`. Every
expectation is a code or a field read out of parsed JSON.

## Where the pane capabilities come from

A pane's token is minted per pane per run and injected as `$BAIA_TOKEN`. The
isolated `ZDOTDIR` `.zshenv` copies `$BAIA_PANE` and `$BAIA_TOKEN` into the
scratch token directory. That is a readout, not a forgery. Probe panes start
with none of the owner's shell configuration.

## How a pane is made to do something

The probe writes a file, splits, and `.zshrc` of any shell started while that
file exists obeys it. `arm-churn` closes the pane; `arm-activity` runs a long
`sleep` as a child of the shell (not `exec`, because the classifier excludes
the shell's own pid).

## Checking that a control can fail

Damage `PaneGraph.authorize` so it also resolves a pane id, run this, put it
back. Both pane-id controls then answer `ok` and the script exits 1 naming
them. The recipe is in `run.sh`'s header.

## What it cannot check

Nothing here types into a pane, so nothing here proves that `baia` works from a
pane the owner opened by hand. Those are the live pass.

The run launches a real app, which takes the front for about twenty seconds.
It is **not** a `SAFE_PROBES` member.
