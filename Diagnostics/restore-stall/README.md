# restore-stall

Measures what the app does when the launch-time session restore cannot get an
answer from the filesystem, which is the case of a recorded pane on a slow or
unmounted volume.

The question: with the restore's directory checks and anchor walks stalled,
does the main thread stay live, is the session file left alone, and does the
saved session still land, beside whatever the owner opened while waiting, once
the filesystem answers?

## How it runs

`run.sh` builds Debug, copies the app under a unique identity through
`Diagnostics/lib/isolated-app.sh`, seeds one saved group in the current
schema, and launches the copy with two Debug-only variables:

- `BAIA_RESTORE_STALL_FILE`: a path the restore's first directory check waits
  for on the filesystem lane. Honoured only when the support directory name
  starts with `baia-restore-stall.` and `BAIA_CONFIG_FILE` is set.
- `BAIA_RESTORE_SELFCHECK_OUTPUT`: where `Sources/RestoreSelfCheck.swift`
  writes its events.

The driver runs from a main-thread timer at 0.3 s. Firing at all is the first
check: before 2026-09-06 the stat calls ran on the main thread before the first
window existed, so the timer would not have fired until the stall cleared. It
then opens a window as an owner would, asks for the save that window arms, and
expects a refusal with the seeded bytes untouched. It releases the stall, waits
for the restore to apply, and checks that the seeded group opened beside the
owner's window, that the keys stayed in the owner's window, and that the next
autosave wrote both groups. `run.sh` grades the written file again from
outside, then checks the normal Release and Debug state fingerprints.

## Pass criterion

Every driver line is `ok`, `self-check failures=0`, the durable file holds
two groups including the seeded tab, and normal state is unchanged.

## What it does not prove

Behaviour of the real daily-driver bundle or a real network mount. The stall
is a file wait inside the same closure the syscalls run in, on the same lane;
it is not a stalled kernel call. Quit during the stall is covered by
`SessionRestoreGateTests` in WorkspaceLayout, not here.

Takes focus: the disposable app activates and opens windows. Do not run from
inside a baia pane.
