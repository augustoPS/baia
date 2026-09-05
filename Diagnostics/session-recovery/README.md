# Session recovery probe

Run `./run.sh` from any directory outside a baia pane. The probe builds and
activates a disposable copy of `baia-dev.app`, so it takes keyboard focus while
each case starts.

## The question

**Can a session file this build rejects survive the fresh workspace's launch
autosave and process shutdown byte for byte?**

`SessionStore.load()` used to collapse four states into `nil`: absent, unreadable,
malformed, and unknown schema. `AppDelegate` then opened a fresh workspace and
scheduled the same save for all four. A malformed or newer file was overwritten
about one second after launch, before its owner could recover it.

The three regression arms write distinctive source bytes and compare bytes rather
than parsed values:

| arm | source | required result |
|---|---|---|
| `malformed` | invalid JSON | identical after launch/autosave and graceful shutdown |
| `future-schema` | otherwise valid session with schema version 2 | identical after launch/autosave and shutdown |
| `malformed-restore-off` | invalid JSON with session restore disabled | identical after launch/autosave and shutdown |

Two positive controls prove that the fixture reaches the real save path. `valid`
starts from a schema version 1 session and requires a current, valid autosave.
`absent` starts without `session.json` and requires the app to create one. A probe
that merely prevented every save would fail both controls. Before grading the
autosave, every case uses the Debug self-check to call the production split and
resize handlers. The pane count and tree must change. The positive
controls also require the saved snapshot to contain the new pane, so a
preexisting valid document cannot make the fixture pass without a write.

Three Debug self-check arms drive the real app handlers without Accessibility
automation. Recovery success verifies the File menu action, a byte-identical
backup, and a current replacement. Recovery refusal makes the disposable support
directory read-only, requires Retry and Keep File, and preserves the source.
Quit failure clicks Cancel Quit on the first save-failure alert, proves a window
remains, restores permission, then clicks Retry and requires a changed current
snapshot before the app exits normally.

## Isolation and cleanup

`run.sh` copies the built app, gives the copy a unique bundle identifier and a
unique `BAIASupportDirectory`, and ad-hoc signs it after changing `Info.plist`.
Its config file and `ZDOTDIR` also live in the run's temporary directory. The
probe launches the copied executable directly and records its exact PID. The
Debug self-check clicks Keep File in rejected cases before mutating the workspace.
JXA's AppKit bridge asks `NSRunningApplication` to terminate every preservation
and control case, which exercises the app's termination decision and final session
flush. Every process must stop before the ten-second timeout and exit with status
0. Cleanup uses an exact-PID kill only after
reporting a timeout.

Before the first case and after the last, the probe fingerprints the normal
config, command-execution acknowledgement, and session locations for both `baia`
and `baia-dev`. Any change is a failure. The unique Application Support directory
and temporary app are removed on success, failure, interruption, or termination.

Each arm writes its app output beside a machine-readable `report.json` in the
evidence directory printed at the end of the run. This directory persists after
the disposable instance is removed. The report includes the copied executable's
SHA-256, so a result identifies the exact tested build. `BAIA_SESSION_RECOVERY_SKIP_BUILD=1`
uses an already-built Debug app, for a coordinator that serialized the build separately.
