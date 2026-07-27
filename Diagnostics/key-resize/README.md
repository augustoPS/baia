# Keyboard resize probe

`./run.sh` from anywhere. Three cases, one process each, all under `set -e`.

The question this exists to answer is not "does the key work". It is whether a key
that writes ratios many times a second can reach the layout loop that used to kill
the process. A mouse writes one ratio per gesture; a held ⌃⌘← writes one every
80ms, and the same value can arrive on hundreds of consecutive layout passes.

`model` is pure `WorkspaceLayout`, no window. It hammers 400 random trees with
120,000 random presses and asserts that every ratio stored anywhere in the tree,
after every press, is one `PaneTree.clampedRatio(_:)` admits. That is the whole
argument: if the keyboard can only reach ratios the drag path already reaches,
then it can only reach arrangements `reachablePosition(in:)` already survives. It
also asserts the stops are genuinely reached, so the claim is not vacuous, that a
held key terminates in the number of presses `keyboardResizeStep` implies and
stops *on* the stop rather than a step short of it, and that a ratio decoded from
an older session file is normalised by the first press instead of carried forward.

`push` is the positive control, and without it `starve` passes for free: a resize
that did nothing would also fail to crash. One press moves the divider the focused
pane touches, to within a point of where the model says, leaves the divider it
does not touch alone, and shows up in the session snapshot. Then 200 presses, and
the assertions that matter for the shape of the fix: the same leaf view objects
are still in the window and the first responder never moved. Routing this through
`rebuild()` would fail both, and the cost of failing them is silent, since
`AppTerminalView.performKeyEquivalent` opens by checking that it is the first
responder and a pane that lost it answers no ghostty binding at all.

`starve` is the crash class. Four window sizes per axis, down to one where three
panes on a spine cannot all have their 96pt minimum, and at each size 160 presses
that *hold* one direction rather than alternating: alternating cancels out and
leaves every divider near the middle, which is the one place this cannot fail. The
focused pane is switched between the two sides of the innermost divider, because
the pane below it can only push it up. Each burst is asserted to have pinned that
divider on both stops, and the case asserts nothing else by comparing numbers: the
proof is that the process is still there to print.

## The negative control

Run once out of tree, on 2026-07-27, not checked in because it requires breaking
the fix. `reachablePosition(in:)`'s `return min(max(thickness * ratio, lowest),
highest)` was replaced with `return thickness * ratio` in the extracted copy and
the `starve` case rebuilt against it:

    sed 's|return min(max(thickness \* ratio, lowest), highest)|return thickness * ratio|' \
      "$TMPDIR/baia-key-resize-probe/panesplit_extracted.swift" > neutered.swift

It died with `SIGTRAP` and no output, inside `_NSViewLayout` under
`+[NSApplication _crashOnException:]`, with `postWindowNeedsUpdateConstraints` and
`NSException exceptionWithName` on the stack: the update-constraints pass count,
which is the abort the guard exists to prevent. So the case can fail, and the
guard is what makes it pass.

## Limits

Nothing here is part of the app build. `run.sh` slices `PaneSplitController` and
`PaneSplitView` out of `Sources/PaneTreeController.swift` with `awk` and compiles
that text, so the probe tests what ships. If those classes move, the `awk`
boundary is the line to fix.

`PaneTreeController` itself is out of reach: it owns `TerminalPaneController`,
which needs libghostty, a Metal device and a spawned shell. `Harness` mirrors the
three methods of it that matter, `resizeFocusedPane(_:)`, `equalizePanes()` and
`pushRatios()`, and they have to be kept in step by hand or the probe will keep
passing while the app does not.

The window is never made key and no mouse moves. The keys are not synthesized as
`NSEvent`s either: what the probe drives is everything downstream of the menu item
firing, which is where all of the behaviour is. That an ⌃⌘← actually reaches
`AppDelegate.growPaneLeft` is the menu bar's contract, not this one's.
