# focus-churn

Measures W02: whether moving focus costs more as a window holds more panes.
A focus change re-applies the terminal configuration of the panes whose
cursor colour moved; the question is whether that is two panes or every pane.

`run.sh` builds Debug, then for each pane count (default 2, 6 and 12) seeds a
session with a balanced split tree of that many panes, launches a disposable
copy through `Diagnostics/lib/isolated-app.sh`, waits for every pane's shell
to report its capability, and times `focus` round trips over the control
socket cycling through the panes (default 120 moves, after one warm-up pass).
The response is written after the focus has been applied on the main thread,
so the latency includes the reconfiguration.

## Pass criterion

Every focus request succeeds (the window must be key, which the disposable
copy is after launch), and the median latency at the largest count is within
twice the median at the smallest. Medians, p95 and max are printed and saved
per count. Normal state fingerprints are unchanged afterwards.

## What it does not prove

Frame time or paint cost after the response, and placement derivation for the
Files column, which is not on this path. It puts a window on screen but never
takes the keyboard.
