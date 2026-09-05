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
| `future-schema` | otherwise current-shaped session with schema version 3 | identical after launch/autosave and shutdown |
| `malformed-restore-off` | invalid JSON with session restore disabled | identical after launch/autosave and shutdown |

Two positive controls prove that the fixture reaches the real save path.
`current-valid` starts from a schema version 2 grouped session and `absent`
starts without `session.json`; both require a current grouped autosave containing
the new pane. A separate `legacy-v1` arm requires the readable version 1 shape to
migrate to version 2 and verifies its byte-identical `.v1-backup`. A probe that
merely prevented every save would fail all three controls. Before grading the
autosave, every case uses the Debug self-check to call the production split and
resize handlers. The pane count and tree must change.

Three Debug self-check arms drive the real app handlers without Accessibility
automation. Recovery success verifies the File menu action, a byte-identical
backup, and a current replacement. Recovery refusal makes the disposable support
directory read-only, requires Retry and Keep File, and preserves the source.
Quit failure clicks Cancel Quit on the first save-failure alert, proves a window
remains, restores permission, then clicks Retry and requires a changed current
snapshot before the app exits normally.

## Isolation and cleanup

`run.sh` sources `Diagnostics/lib/isolated-app.sh`. The shared owner gives every
run a unique bundle identifier, executable name, `BAIASupportDirectory`, config,
and `ZDOTDIR`, then ad-hoc signs the copy. The probe launches that exact executable
and records both its PID and executable path for the helper's interruption
cleanup. The Debug self-check clicks Keep File in rejected cases before mutating
the workspace. JXA's AppKit bridge asks `NSRunningApplication` to terminate every
preservation and control case, exercising the app's termination decision and
final session flush. Every process must stop before the ten-second timeout and
exit with status 0.

The shared owner fingerprints the normal config, command-execution
acknowledgement, and session locations for both `baia` and `baia-dev` before and
after the fixture. Any change is a failure, and both snapshots remain in the
evidence directory. Marker-checked cleanup removes only this run's temporary app
and support directory; a process that survives the bounded exact-binary cleanup
causes those paths to be retained instead of deleted underneath it.

Each arm writes its app output beside a machine-readable `report.json` in the
evidence directory printed at the end of the run. This directory persists after
the disposable instance is removed. The report includes the copied executable's
SHA-256, so a result identifies the exact tested build.

For the coordinator-owned live gate, after a successful Debug build and from a
terminal outside a baia pane:

    BAIA_SESSION_RECOVERY_SKIP_BUILD=1 ./Diagnostics/session-recovery/run.sh

The headless fixture and grader checks require no app launch:

    python3 -m unittest discover -s Diagnostics/session-recovery -p 'test_*.py' -v
