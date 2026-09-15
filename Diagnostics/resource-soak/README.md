# resource-soak

Measures whether repeated pane split and close, or repeated subscription churn
on the control channel, leaves owned resources behind.

`run.sh` builds Debug, launches a disposable copy through
`Diagnostics/lib/isolated-app.sh` with the control channel on, and runs
`probe.py run` against its socket. The session is seeded by `probe.py seed` at
the current schema (2), so no first-launch migration lands in the samples.
Migration is verified in `session-recovery`, not here.

## Split/close churn (default)

Each round splits the anchor pane, waits for the new pane's shell to report its
capability, closes the new pane through that capability, and waits for the
layout to show one pane again. `lsof`, `ps` resident size and the descendant
process set are sampled before, every six rounds, and after a settle at the
end. Rounds default to 24 (`BAIA_RESOURCE_SOAK_ROUNDS`).

Pass: after settling, the open descriptor count is within four of the plateau
low, no descendant process outlives the churn, and no mid-churn sample exceeds
the plateau by more than four. Mid-churn samples land every six rounds, so a
run of fewer than six rounds is warmup: it still splits, closes, and checks
that descendants return, but it does not grade plateau growth (a one-point
range is tautological) and is recorded as `splitCloseWarmup`.

## Subscription churn (`BAIA_RESOURCE_SOAK_SUBSCRIBE_BATCHES`)

```sh
BAIA_RESOURCE_SOAK_SKIP_BUILD=1 BAIA_RESOURCE_SOAK_SUBSCRIBE_BATCHES=100 bash Diagnostics/resource-soak/run.sh
```

The session is seeded with four scratch panes beside the anchor. Each batch
parks eight `subscribe --wait` clients, two per scratch pane, from the ring head
with `kinds=[paneOpened]` so nothing but the deadline can wake them. That is
below the per-pane quota of four connections and the pool of sixteen
(`ControlWire.maxConnectionsPerPane`, `ControlWire.maxConnections`), so no
client is evicted to make room. The probe confirms all eight are parked (none
readable within 0.3 s), times a `whoami` served while they are parked, then
ends the batch: odd batches close every client before the wait elapses, even
batches read the server's deadline answer first and require it to be an empty
batch arriving no earlier than the wait. An early answer is graded as a
defect, never counted as a concurrently parked client. The wait is
`BAIA_RESOURCE_SOAK_SUBSCRIBE_WAIT` (default 2, clamped to 1..5 s). With
batches set, rounds default to zero so the two churns do not share a baseline.

One split/close round pays the dynamic surface cost, then two subscription
warm-up batches run before the warm baseline is settled. If a full split/close
soak already ran in the same launch, that warmup split is skipped so the
N-round `splitClose` evidence is kept; otherwise the one-round warmup is
recorded as `splitCloseWarmup`. A census (numeric `lsof` descriptors and type
breakdown, RSS, descendants with command names, the last ten latencies) is
taken every ten batches and after the churn. Each graded census requires two
samples 1.5 seconds apart within 15 seconds that agree on numeric descriptor
count, unix socket count, and descendant set. All raw observations are
retained, including sockets awaiting asynchronous close. Mapped `txt` files
and `cwd` are reported separately from descriptors. Then a fresh subscription
is parked on the anchor and must be woken by the anchor's next split with an
advanced sequence.

Pass: descriptors after settling within four of the warm baseline; the range
across warm, censuses and settled within four; no sustained growth (the second
half of the censuses does not exceed the first half by more than two); the
descendant set is the warm set; every batch parked all eight with no early
answer; every timeout batch answered empty within the wait plus five seconds;
every timed request succeeds in under two seconds; no settle deadline expires. RSS is reported, not asserted.

### Live failure controls

Run in the same launch after the churn, so the grader is shown rejecting real
censuses before it is trusted to accept one:

1. Eight retained sockets: parked and held while a census is taken. The grader
   must reject on descriptors, the growth must be `unix` descriptors, and the
   descendant checks must still pass.
2. A known leftover child: the probe plants `arm-linger`, splits one pane whose
   `.zshrc` runs `sleep 600`, and takes a census. The grader must reject on the
   new descendant and the recorded `sleep` pid must be in it.
3. Cleanup: sockets closed in `finally`, the linger pane closed through its own
   capability. Closing must reap the child; if it does not, the exact recorded
   pid is signalled only while its command is still `sleep` under the app, and
   the check fails. The settled census must then pass again.

## Evidence

`resource-soak-report.json` in the evidence directory carries every sample
(with raw `lsof` lines and `censusObservations`), per-batch records (mode, parked count, early answers,
latency, deadline timings), the post-churn wake, and the control censuses with
the grader's verdicts. `session-seed.json` is the seed that was launched.

## Tests without an app

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v Diagnostics/resource-soak/test_probe.py
```

Importing `probe.py` runs nothing; `main()` is behind the entry-point guard.
The tests drive the seed builder and the graders on synthetic samples: flat
passes, steadily retained descriptors fail, a leftover owned child fails, and
the retained-socket shape rejects on descriptors alone. Settle refuses to
freeze while unix counts still move; a one-round warmup does not emit a
plateau pass and does not overwrite a completed `splitClose` report.

## What it does not prove

Rendering or scrollback cost, quota eviction (a separate arm if this churn ever
exposes one), or long-duration growth beyond the configured rounds and batches.
Every control travels on the socket, so the fixture never takes the keyboard;
it does put a window on screen, and `isolated_refuse_pane` refuses to start
inside a baia pane.
