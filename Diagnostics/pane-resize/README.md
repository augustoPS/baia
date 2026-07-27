# Pane resize probe

`./run.sh` from anywhere. It prints, for each split at three depths on both axes,
where the divider was, where a drag put it, where it sat after the layout pass the
drag triggers, and what the model ended up holding. Then it resizes the window and
prints whether each fraction survived.

Every case runs twice: once with the drag write-back disconnected, which is the
code as it stood before the fix, and once with it live. The first arm is what
makes the second arm mean anything, and its failure signature is the bug as
reported: nested dividers refuse to move at all, and the root moves but snaps back
to half the thickness on the next window resize.

Two more cases follow, and both are about what a stored ratio may cost once
dragging can put a value other than 0.5 into the tree.

`starve` drags a nested divider to the 96pt stop, shrinks the window past the
point where that fraction fits, and shrinks it twice more. If `applyRatio` ever
asks for a position `NSSplitViewItem.minimumThickness` refuses, the request is
never granted, the next layout pass asks again, and a nested split never
converges: AppKit raises `NSGenericException` about the update constraints pass
count and the process aborts. So the case asserts nothing by comparing numbers.
It prints, and `run.sh` runs under `set -e`. The second half of it restores a
starving fraction into a small window with no drag at all, which is the relaunch
path, where the same abort lands during construction and every launch reads the
same session file back.

`click` parks a divider off its stored ratio, which is what any window shrunk
after a drag does, and posts one `mouseDown` with no drag behind it. Nothing may
be written. Comparing the measured fraction against the stored ratio instead of
against where the divider was when the gesture started turns that click into a
silent, unrecoverable rewrite of the arrangement.

Nothing here is part of the app build. `run.sh` slices `PaneSplitController` and
`PaneSplitView` out of `Sources/PaneTreeController.swift` with `awk` and compiles
that text, so the probe tests what ships rather than a copy that has drifted. If
those two classes ever move out of that file, the `awk` boundary is the line to
fix.

What it cannot reach: `PaneTreeController` itself, which owns
`TerminalPaneController` and therefore needs libghostty, a Metal device and a
spawned shell. `Harness` in `dragtest.swift` is a stand-in for the two methods of
it that matter, `makeViewController(for:at:)` and `recordRatio(at:_:)`. Keep them
in step by hand, or the probe will keep passing while the app does not.

The window is never made key, no mouse moves, and nothing is captured. The `drag`
mechanism posts events into `NSSplitView`'s own tracking loop through
`PaneSplitView.mouseDown`; the `set` mechanism moves the divider with
`setPosition` between `onDragWillBegin` and `onDragFinished`, which is the same
landing point without the event queue. Both halves of that pair are needed: the
controller notes where the divider was on the way in, because whether it moved is
what tells a drag from a click.
