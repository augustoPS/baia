# busy-close

Measures the close policy (W01, owner decision 2026-09-06): closing a pane,
tab or window, or quitting, asks first when a pane still has a foreground job;
Cancel keeps the job; Confirm ends it with the pane.

`run.sh` builds Debug, copies the app under a unique identity through
`Diagnostics/lib/isolated-app.sh`, and seeds a `.zshrc` that runs `sleep 300`
in the foreground and records its pid while a marker exists. Three launches
drive `Sources/CloseSelfCheck.swift` through the production close actions:

- `busy-pane`: Close Pane shows a sheet naming `sleep`; Cancel keeps the pane
  and the job; the second Close Pane is confirmed, the window closes and the
  app exits. The fixture then checks the recorded sleep pid is gone.
- `busy-quit`: Quit shows the modal alert; Cancel keeps the workspace and the
  job; the second Quit is confirmed.
- `idle-pane`: with no job, Close Pane closes the window without a sheet.

## Pass criterion

Every driver line is `ok`, `self-check failures=0` in every mode, the sleep
pid is absent after each confirmed close, and the normal Release and Debug
state fingerprints are unchanged.

## What it does not prove

Window close through the red button (it goes through the same
`windowShouldClose` path but is not clicked here), Close All, or the
control socket's direct close, which is unchanged by design.

Takes focus: the disposable app activates and opens a window. Do not run from
inside a baia pane.
