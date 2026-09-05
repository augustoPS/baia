# Native window-group regression fixture

Run `./run.sh` from any directory outside a baia pane. The fixture uses the
already-built Debug app by default when `BAIA_WINDOW_GROUPS_SKIP_BUILD=1`; omit
that variable to let the runner build before it creates the isolated copy.

When this child worktree does not contain the shared isolation library, point at
the root checkout that owns it:

```bash
BAIA_DIAGNOSTICS_LIBRARY_ROOT=/Users/pasqualotto/Projects/baia \
BAIA_WINDOW_GROUPS_SKIP_BUILD=1 \
/Users/pasqualotto/orca/workspaces/baia/baia-window-groups/Diagnostics/window-groups/run.sh
```

## Design

The fixture has four launches of one disposable app. The runner creates a unique
bundle identifier, executable name, config file, Application Support directory,
and shell environment through `Diagnostics/lib/isolated-app.sh`. The Debug-only
self-check then works against `AppDelegate`'s real `WorkspaceWindowController`
objects and `NSWindowTabGroup` instances. Its only production seam calls the same
private capture and save methods used by autosave and termination. Restore is the
normal `applicationDidFinishLaunching` path, not a test reconstruction.

1. A version 1 session restores as one native four-tab group. The self-check uses
   `NSWindowTabGroup.removeWindow`, `NSWindow.addTabbedWindow`, and native
   selection to detach, merge, detach again, and reorder it into two groups. It
   assigns distinct frames and sidebar geometries, leaves different selected tabs,
   makes the second group active, then makes Settings key before production capture
   and save.
2. The next launch restores the saved version 2 document. The self-check reads
   actual native membership, selection, frame, sidebar geometry, preferred tabbing
   mode, and the key group. It then merges both groups and detaches/reorders them
   into a different two-group arrangement before another production save.
3. The third launch verifies that second arrangement after another real restore.
4. The runner replaces only the disposable session with a version 2 fixture whose
   selected tab and active group point at missing directories. The last launch
   requires production reconciliation to keep the surviving tab, drop the empty
   group, and repair both selection and active group.

Between launches, the external Python grader reads the durable file. It requires
schema version 2, stable group identity, the expected membership and tab-bar
order within each group, selected tabs, active group, distinct per-group frames
and sidebar geometries, and a byte-identical version 1 migration backup. The
outer group-array order is not asserted because it comes from controller
traversal and has no user-facing meaning. The grader stores each phase's durable
JSON beside the event log, and the in-process log records native, captured and
durable group ids, tabs, selection, frames and sidebar values. These checks
prevent an in-process-only proxy from passing while the on-disk contract is wrong.

## Isolation and cleanup

The shared helper fingerprints the normal Release and Debug config, session, and
command-acknowledgement paths before the first launch and after the last. It records
the exact copied executable and PID, requests termination only from that process,
and removes only marker-owned scratch and support directories. Evidence, including
the copied executable hash, app logs, self-check events, and `report.json`, remains
at the path printed by the runner.

This probe takes focus and refuses to run inside a baia pane. It does not use
Accessibility automation and makes no VoiceOver or AX claim. External visual,
keyboard, drag, Window menu, VoiceOver, and Full Keyboard Access observations stay
in the owner live-check queue.

## Regression sensitivity

`test_probe.py` feeds deliberately flattened, wrongly selected, same-frame, and
wrong-sidebar documents into the external grader. Run it with:

```bash
/usr/bin/python3 -m unittest Diagnostics/window-groups/test_probe.py
```

The live fixture must fail if production capture flattens groups, production
restore selects the wrong tab or active group, a restored first window remains
`.disallowed`, migration omits the v1 backup, or missing-directory reconciliation
leaves an empty group.
