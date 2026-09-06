# Repository event watcher

This fixture compiles `Sources/RepositoryEvents.swift` as a standalone binary
and drives it with real local Git repositories under one `mktemp` directory.
It launches no app, touches no normal configuration or session state, and
removes only its own temporary directory.

From a terminal outside a baia pane:

    ./Diagnostics/repository-events/run.sh

The fixture checks recursive nested create, rename, and delete events; a linked
worktree's real index and HEAD; common refs; rejection of the main worktree's
unrelated index; root deletion, recreation, and reattachment; dropped-event
classification; and callback silence after explicit stop or watcher release.

`RepositoryEvents` reports the canonical worktree root plus a typed reason:
working-tree writes versus gitdir HEAD/index, common refs, or dropped/root-change
rescan. The observer invalidates status and the tree for both; only metadata,
rescan, and explicit refresh relearn the default branch. Event-triggered status
is bounded by the configured poll cadence. Call `stop()` when the last
subscription releases.
Construct it off the main thread because initial path resolution and stream
startup are synchronous. The adapter never reads Git status and owns no polling,
coalescing, or repository-read retry policy. If FSEvents cannot be reattached,
the adapter retries only that attachment every 250 milliseconds while it is
owned; `stop()` or release cancels the retry and retains cleanup ownership until
the stream is stopped and invalidated.

Each positive arm prints observed callback latency and the run prints the
minimum, median, and maximum for its local APFS fixture. The fixture's bounded
wait is only a test failure limit; neither it nor the measured numbers are a
universal one-second delivery promise.
