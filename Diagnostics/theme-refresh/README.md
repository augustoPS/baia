# Theme refresh probe

`./run.sh` from anywhere. It builds two split levels on both axes over three
stand-in panes, changes the terminal theme, and prints each `PaneSplitView`'s
`dividerColor` before and after, along with whether any view was rebuilt or
reparented to get there.

Three arms, in one process each.

`noop` is the code as it stood. `refreshTheme()` called `rebuild()`, whose first
statement is `guard renderedTree != current || renderedZoom != zoomedPane else {
return }`. A config-file theme change moves neither, so it returned before
touching anything and the dividers kept the old theme's colour until an unrelated
split happened to rebuild them. The arm prints `UNCHANGED` on every divider, which
is the bug.

`rebuild` is the fix that was rejected: force the rebuild past its guard. The
colour lands. The line to read is `terminal views reparented`, which names every
pane: `rebuild()` calls `removeFromSuperview` on each child and builds a fresh
hierarchy over the same pane controllers, so every live ghostty surface moves to a
new parent. In the app that resizes the grid and sends `SIGWINCH` to whatever is
running in each pane, for a colour change.

`push` is what ships. The theme goes into the views that are already there, and
the arm asserts all of it: every divider is the new theme's colour, no terminal
view was rebuilt, none was reparented, and no split view was rebuilt. It exits
non-zero on any of those, so `run.sh` under `set -e` is the test.

What makes the repaint free is that `super.drawDivider(in:)` re-reads
`dividerColor` on every draw, so a stored `paneTheme` and a `needsDisplay` are the
entire update.

Nothing here is part of the app build. `run.sh` slices `PaneSplitController` and
`PaneSplitView` out of `Sources/PaneTreeController.swift` with `awk` and compiles
that text, so the probe tests what ships rather than a copy that has drifted. If
those two classes ever move out of that file, the `awk` boundary is the line to
fix. The recursion under test, `PaneSplitController.applyTheme(_:to:)`, is a
static method on that class rather than a private method on `PaneTreeController`
for exactly this reason: inside the sliced region it can be run, outside it could
only be retyped.

What this cannot reach: `PaneTreeController` itself, which owns
`TerminalPaneController` and therefore needs libghostty, a Metal device and a
spawned shell. `Harness` stands in for `makeViewController(for:at:)` and for
`refreshTheme()`'s one-line loop over `children`; `HostVC.teardown()` stands in
for `rebuild()`'s teardown. Keep them in step by hand.

The window is never made key and nothing is captured. The rendered pixel is
deliberately not asserted: `bitmapImageRepForCachingDisplay` did not capture the
one-point divider fill in two separate attempts during the investigation that
produced this fix. What is asserted is the colour the draw call reads. **The last
step, that the line on screen is that colour, cannot be proven without looking.**
