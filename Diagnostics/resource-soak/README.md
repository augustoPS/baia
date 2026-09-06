# resource-soak

Measures whether repeated pane split and close leaves owned resources behind.

`run.sh` builds Debug, launches a disposable copy through
`Diagnostics/lib/isolated-app.sh` with one pane and the control channel on,
and runs `probe.py` against its socket. Each round splits the anchor pane,
waits for the new pane's shell to report its capability, closes the new pane
through that capability, and waits for the layout to show one pane again.
`lsof`, `ps` resident size and the descendant process set are sampled before,
every six rounds, and after a settle at the end. Rounds default to 24
(`BAIA_RESOURCE_SOAK_ROUNDS`).

## Pass criterion

After settling, the open descriptor count is within four of the baseline, no
descendant process outlives the churn, and no mid-churn sample exceeds the
baseline by more than one pane's worth. Resident memory is reported, not
asserted: an allocator's steady state is not a leak. The normal Release and
Debug state fingerprints are unchanged afterwards.

## What it does not prove

Rendering or scrollback cost, subscribe/disconnect churn on the channel, or
long-duration growth beyond the configured rounds. Every control travels on the
socket, so the fixture never takes the keyboard; it does put a window on
screen.
