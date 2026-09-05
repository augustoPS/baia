# Report expiry probe

Run `./run.sh` from any directory outside a baia pane. It builds a disposable
copy of the Debug app unless `BAIA_REPORT_EXPIRY_SKIP_BUILD=1` is set, drives the
copy only through its real Unix control socket, and exits non-zero naming each
failed assertion.

## Measured property

A pane report owns attention only until its TTL. The one effective revision used
by list/chrome, explain and subscriptions must change at expiry without a focus,
process or visibility event. Renewal replaces the earlier deadline, a superseded
sequence cannot install its TTL, release cancels its deadline, and closing a pane
cancels pending work rather than keeping the pane alive or crashing later.

The Q04 arm establishes the related view-lifetime condition before exercising
expiry. Alpha zooms, detaching Bravo's view, and only then the fixture starts a
real `sleep` child in Bravo. Bravo must publish both the child's arrival and exit
while hidden. The fixture then starts a second stable foreground `sleep`, waits
until its activity is published, and changes the disposable config's activity
poll from one second to thirty. Every expiry TTL is shorter than that interval;
the expiry, renewal, supersession and release arms run with neither process nor
visibility changes available to publish them accidentally.

The primary expiry arm records both sides through all shipped readers available
on the socket:

- `list` moves from `attention: asking` to no attention;
- `explain` moves the held report to `live: false` and authority to `none`;
- `subscribe` contains exactly one `attentionRaised` and one `attentionCleared`.

## Isolation and cleanup

`run.sh` uses the shared `Diagnostics/lib/isolated-app.sh` owner committed in
`c43b0a1`. It copies `baia-dev.app`, assigns a unique bundle identifier and an
exclusively created `BAIASupportDirectory`, and ad-hoc signs the copy. Its config,
session, shell fixture and capability readouts live under a marked `mktemp`
directory. Cleanup validates the exact PID against this copy's binary before
signalling it, and deletes only directories bearing this run's ownership marker.
No process-name kill is used.

The helper fingerprints normal Release and Debug config, session and
command-acknowledgement paths before launch and during teardown; a change fails
the run. The disposable app, support directory and capability files are removed
on success, failure, interruption or termination. Machine-readable evidence and
the app log remain at the evidence path printed on exit.

This task was based before `c43b0a1`. Until the helper is integrated into this
checkout, run with
`BAIA_DIAGNOSTICS_LIBRARY_ROOT=/Users/pasqualotto/Projects/baia`; the launcher
still sets `ISOLATED_SOURCE_APP` to this worktree's Debug build.

This probe launches a real app window and is intentionally absent from
`Diagnostics/observer-pane/guard-baia-alive.sh`'s `SAFE_PROBES`; never run it from
inside baia. The coordinator owns the live run. This worker wrote the fixture but
did not build, launch or execute it.
