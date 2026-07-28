# Control channel probe

`./run.sh` from anywhere. It builds baia, launches it, exercises the control
channel over the real socket, and exits non-zero naming any check that failed.
Thirty-five checks, each printing `ok` or `FAIL`, ending in `PASS` or
`FAILED n of m`.

Quit any running baia first. A second instance owns the socket, and the one this
launches would run with no channel and hand its panes no capability; the script
refuses up front rather than killing an app somebody is using.

## Everything is on the wire

`probe.py` opens `$BAIA_SOCK`, writes bytes, and reads bytes. It imports nothing
the app is built from and calls no Swift. That is the whole design, and it is the
lesson this directory already paid for once: the footer-corners probe verified a
geometry helper directly and stayed green while the code consuming it was covered
by nothing. A control that reached `PaneGraph.authorize` would keep passing while
the socket in front of it was deleted.

One check goes through literal `nc -U`, because `ControlWire`'s own reasoning for
newline-delimited JSON over a length-prefixed frame is that the channel stays
debuggable by hand, and a claim nothing exercises stops being true quietly.

**Every expectation is a code or a field read out of parsed JSON.** Key order in
a response is `JSONEncoder`'s to choose and is stable only within a process, and
paths come back with their solidi escaped, so a control that grepped for
`{"v":1,"ok":false` would pass on the run it was written against and fail on the
next one for a reason nobody would find quickly. The single check that looks at
bytes is the over-cap frame, whose assertion is that there were none.

## Where the pane capabilities come from

A pane's token is minted per pane per run, injected into its shell as
`$BAIA_TOKEN`, never written to disk, and returned by no verb. Nothing in a
script can type into a pane, so the panes are asked to report their own
environment instead: the app is launched with `ZDOTDIR` pointing at a directory
the script writes, whose `.zshenv` copies `$BAIA_PANE` and `$BAIA_TOKEN` into the
scratch directory as each pane's shell starts.

That is a readout and not a forgery. The values are the app's own, issued by the
app to that pane, and they reach the socket the way that pane's `baia` would.
The side effect is that a probe run's panes start with none of the owner's shell
configuration, which is deliberate: what a pane's dotfiles do must not be able to
change what the run proves.

## The checks

**A token is a capability and nothing else is.** A token that was never issued is
`badToken`. Then the finding that must not silently come back, twice: the
caller's own pane id and another live pane's id, both read out of `session.json`
rather than invented, both belonging to panes that hold a live capability at that
moment, are each `badToken` when sent as a token. An implementation that let
`authorize` fall back to a pane id "so the read verbs keep working with the ids
they return" answers `ok` to both.

**The version field.** `v: 0` and `v: 2` are `badVersion`.

**The frame cap.** A line over 256 KiB with no newline in it is closed on with no
response at all, which is the read loop deciding on bytes as they arrive rather
than on a line that ended.

**Scope, asserted on contents rather than on refusal.** A read leak fails by
over-succeeding and a refusal-shaped harness structurally cannot see it, so the
scope checks assert what came back. The session has three panes; one of them
splits a child through the channel, and its `list` must name exactly itself and
that child. A pane that created nothing lists only itself. `whoami` still names
one pane after that pane has created another. `send` to a live pane that is not a
peer is `unauthorized`, and `send` to a pane that does not exist answers the same
code, so a caller cannot enumerate the workspace one id at a time.

**The two settings keys have consumers.** `controlChannelEnabled` is flipped to
false live and every one of the fifteen verbs must answer `disabled`, then flipped
back and `whoami` must work again. `controlAllowRun` is flipped and `run`'s code
must move from `disabled` to `refused` and back. Each flip is waited on by polling
the channel rather than by sleeping, so a key with no consumer fails on the
deadline instead of passing on a race.

## Checking that a control can fail

The controls here cannot be built in the way `pane-resize`'s are, because each
one would need its own build of the app rather than its own compile of an
extracted file. So the check is run by hand, and the recipe is in `run.sh`'s
header: damage `PaneGraph.authorize` so that it also resolves a pane id, run the
script, and put it back. Both pane-id checks then answer `ok`, the script names
them and exits 1.

## What it touches

`~/.config/baia/config.json` and `~/Library/Application Support/baia/session.json`
are backed up before the first write and restored on the way out however the run
ends, including when a check fails or the run is interrupted. A machine that has
never run baia has neither file, and the restore removes the probe's copies
rather than leaving a workspace the owner never had. Everything else lives in
`$TMPDIR/baia-control-channel-probe`.

The run launches a real baia, which takes the front for about twenty seconds.

## What it cannot check

Nothing here types into a pane, so nothing here proves that `baia` works from a
pane's shell: that `command -v baia` finds the embedded helper after `login` and
`path_helper` have rebuilt PATH, that the response arrives before the shell dies
on `baia close`, that `recv --wait 60` leaves the UI responsive, that a mutation
in a background window does not raise it, or that a pane opened by hand with ⌘D
appears in no other pane's `list`. Those are the live pass, and they are run by
hand.
