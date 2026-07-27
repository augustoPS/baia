# Pane resize probe

`./run.sh` from anywhere. Ten arms, each printing `ok`/`FAIL` per assertion and
ending in `PASS` or `FAILED n`, then eight negative controls that damage the
shipped code and must fail. The script exits non-zero if any arm fails or any
control passes.

This is the regression test for the bug as reported: dragging a split divider
never persisted, because `PaneSplitController.ratio` was a construction-time
`let` and `viewDidLayout` re-pinned the divider to it, while nothing wrote a
finished drag back into the model. It used to print numbers and always exit 0,
which meant a regression showed up as different output nobody reads.

## The arms

Eight of them are one axis, one mode and one mechanism each: `sidebyside` or
`stacked`, `fixed` or `broken`, `drag` or `set`. Each drags the divider at three
depths to 0.3 of the split and asserts, per depth, that the drag was still there
at mouse-up rather than back where it started, that the layout pass the drag
itself triggers left it there, and that the ratio the model recorded matches the
drawn fraction to within 0.001. Then that the session saw exactly three writes
and no more, and that a window resize keeps every fraction rather than restoring
0.5.

`starve` drags a nested divider to the 96pt stop, shrinks the window past the
point where that fraction fits, and shrinks it twice more. It asserts that the
stored ratio survives every shrink untouched, that the divider never sits below
the stop, that no shrink writes anything, and that re-widening gives the dragged
arrangement back. The second half restores a starving fraction into a small
window with no drag at all, which is the relaunch path. Two of its claims are
carried by the exit status rather than by a number: the divider never sits inside
the minimum's margin, because a position `setPosition` refuses is one the next
layout pass asks for again forever, and the process is still alive to print at
all, because that loop ends in `NSGenericException` and a dead app.

`click` parks a divider off its stored ratio, which is what any window shrunk
after a drag does, and posts one `mouseDown` with no drag behind it. Nothing may
be written, the model must still hold what it held, and re-widening must put the
divider back. It first asserts that the drawn position and the stored ratio
really do disagree, without which the arm is vacuous.

## The controls

Two kinds, and both must fail.

The `broken` mode is built in. It disconnects the write-back the way the code
stood before the fix, and the arm asserts that the bug reproduces: the model
never hears about any drag, nothing is written, the nested dividers refuse to
move at all under a real drag, and every fraction reverts on the next window
resize with the root landing on exactly half. That arm therefore exits 0 while
the pre-fix path still misbehaves and fails if it quietly starts working, which
is the only way an inverted control can be read from a green run.

Why the nested dividers freeze while the root moves and only reverts later: a
nested split's own `viewDidLayout` fires while the tracking loop is resizing its
subviews, so with no write-back it is re-pinned to the construction ratio before
the mouse is even up. Dragging the root dirties its children's layout and not its
own, so the root moves and waits for the next window resize to be undone.

The other six damage the shipped code. `run.sh` already slices
`PaneSplitController` and `PaneSplitView` out of `Sources/PaneTreeController.swift`
with `awk`; each control applies one `sed` to that slice, compiles it, and runs
the arm it should break. The damage lands in the write-back path itself, not in
something it calls: the footer-corners probe was written the other way round
once, verifying a geometry helper while the code consuming it was covered by
nothing, and its controls still failed, which is exactly what made it look sound.
A `sed` that matches nothing is a hard failure, because a mutation that changed
nothing is a control that passes for reasons unrelated to the arm.

| mutation | what it damages | arm it breaks |
|---|---|---|
| `notify` | `recordDrag` no longer calls `onRatioChange` | the drag reaches the model; the session write count |
| `pin` | `recordDrag` no longer updates the stored ratio, which is the original `let` bug | the drag survives to mouse-up and past the layout pass |
| `enforce` | `viewDidLayout` no longer calls `applyRatio` | the pre-fix arms, which have nothing left to re-pin them |
| `moved` | the click test compares against the stored ratio instead of where the gesture began | `click` |
| `reachable` | the position clamp in `reachablePosition` removed | `starve`, fatally |

`reachable` is the one whose damage kills the process instead of printing a wrong
number, which is the whole crash class, so `run.sh` asserts that it was killed by
a signal rather than merely that it exited non-zero. It currently dies with
status 133, SIGTRAP, inside the first layout pass with stdout still buffered,
which is why it prints nothing at all.

## What it does not reach

`PaneTreeController` itself, which owns `TerminalPaneController` and therefore
needs libghostty, a Metal device and a spawned shell. `Harness` in
`dragtest.swift` is a stand-in for the two methods of it that matter,
`makeViewController(for:at:)` and `recordRatio(at:_:)`. Keep them in step by
hand, or the probe will keep passing while the app does not.

Nothing here is part of the app build, and if `PaneSplitController` and
`PaneSplitView` ever move out of `Sources/PaneTreeController.swift`, the `awk`
boundary in `run.sh` is the line to fix.

`firstChildThickness` reads the split view item's own view rather than
`splitView.subviews[0]`, and its doc comment says the two rects differ. In this
headless harness they do not: swapping one for the other changes no measurement
and passes every arm, so that claim is documented but not covered here.

The window is never made key, no mouse moves, and nothing is captured. The `drag`
mechanism posts events into `NSSplitView`'s own tracking loop through
`PaneSplitView.mouseDown`; the `set` mechanism moves the divider with
`setPosition` between `onDragWillBegin` and `onDragFinished`, which is the same
landing point without the event queue. Both halves of that pair are needed: the
controller notes where the divider was on the way in, because whether it moved is
what tells a drag from a click.
