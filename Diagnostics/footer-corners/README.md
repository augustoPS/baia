# Footer corners probe

`./run.sh` from anywhere. It measures the window's own rounded corner, measures
the ones the footer and the attention frame draw, checks that rounding a corner
did not move the bar or its text, and checks that the footer stops curving when
the window does. Seven arms, one process each, and every arm is followed by a
`break` variant that damages the thing under test and is expected to fail.
`run.sh` inverts those, so a control that stops failing fails the run as loudly as
an arm that stops passing.

Nothing is captured from the screen. `screencapture` needs a screen-recording
grant that a headless run cannot answer, and it is not needed: every reading here
comes either from geometry AppKit hands over or from a bitmap this process
rasterizes itself. The phase-one investigation established that the two agree to
0.002 pt.

Six of the seven arms run as an accessory app and never take focus. `fullscreen`
cannot: an accessory app's window refuses `toggleFullScreen(_:)` outright, so
that arm activates and drives a window into full screen and back, twice. It runs
last for that reason, and it is why `run.sh` is not something to fire off in the
middle of a call.

`Sources/WindowCorner.swift`, `Sources/PaneStatusBarView.swift` and
`Sources/PaneOverlayView.swift` are compiled verbatim by `run.sh`, not sliced and
not retyped, so the shapes measured are the ones the app draws. That works because
the two views reach nothing outside `BaiaSettings`, `PaneChrome`,
`WorkspaceLayout` and `WindowCorner`; if either ever grows a dependency on another
file in `Sources/`, the `swiftc` line is where that shows up.

## radius

The point of the whole probe. `WindowCorner.radius` is a constant because macOS
publishes no API for the window corner radius, so the only thing standing between
the footer and a corner that quietly stops matching is a check that re-derives the
number.

Three readings of the same corner, all of which have to agree:

- `NSWindow._cornerRadius`, the scalar AppKit stores.
- the length of the corner in `NSThemeFrame._getCachedWindowCornerPath`, which for
  a continuous corner is 1.5287 radii rather than one. 24.45864 pt for a 16 pt
  radius.
- that path rasterized at 2x and read row by row against
  `RoundedRectangle(cornerRadius: 16, style: .continuous)`. This is the reading
  that says *continuous*: an OS that kept the radius and changed the curve family
  passes the other two. The same row-by-row read against a circular arc of the
  same radius is printed beside it, currently 1.98 pt apart at the row nearest the
  corner, and the arm fails if that gap ever closes, since then the drawing code
  is going out of its way to avoid a circle for nothing.

The private selectors are used **here only**. They exist to make the shipped
constant checkable rather than believed, and none of them may appear in
`Sources/`.

The control claims a radius the window does not have, which is what a macOS
release that changed its corners will look like from inside this arm.

### Reading a corner off pixels

The row-by-row reading is an integral, not a threshold: for each pixel row it
integrates the uncovered fraction from the edge inward until coverage saturates.
An `alpha > 0.5` cutoff throws the antialiasing ramp away and reads this corner
0.6 pt short at the row nearest the vertex, which is what made the first
measurement of it look like neither a circle nor a squircle.

## match

The footer's path against the window's, rasterized and profiled the same way, over
the bar's own 22 pt. That is all of the corner a footer can show: the corner is
24.46 pt long, so its top 2.46 pt is above the bar entirely.

Two tolerances rather than one, because the two errors are not worth the same. A
shape that stops **short** of the window's outline leaves a sliver of window with
no footer painted on it, and that is visible; one that runs **past** it is cut off
by the window's own mask and cannot be seen at all. So inward is held to 0.01 pt
and outward is allowed 0.06.

The outward allowance is spent on one thing. SwiftUI cuts the corner short to fit
a 22 pt box by subdividing the cubic rather than shrinking the radius, which is
what makes this correct at this height at all, but its truncation leans up to
0.051 pt outward over the last third of the arc. Measured, not assumed: it is in
the table the arm prints, at 13.75 pt up.

The right-hand corner is measured too, mirrored, so a path built with leading and
trailing the wrong way round cannot pass on the strength of the left one. And a
pane in no corner is checked to still be square.

The control draws the fill as a circular arc of the same radius, which is what
`NSBezierPath(roundedRect:xRadius:yRadius:)` and `CGPath(roundedRect:)` both
produce. It misses by 8.6 pt.

## concentric

The focus frame is a 2 pt stroke whose centreline sits 1 pt inside the bar, so its
radius has to come down to 15 with it. Two curves are parallel only when they are
concentric: reuse the window's 16 on an inset rectangle and the gap widens through
the corner and closes again on the straight edges, which reads as the frame
sagging away from the window and coming back.

Measured as a perpendicular distance from densely flattened polylines, not a
row-wise one: a row-wise gap grows to 1.41 pt at the diagonal for a frame that is
exactly right, so there would be nothing to compare it against.

The shipped frame wanders by 0.071 pt. That is not zero and cannot be, because a
continuous corner of radius r-d is the platform's idea of concentric rather than
the exact offset curve of the radius-r one. The control, which insets the
rectangle and keeps the radius, wanders by 0.414 pt. The line is at 0.1.

## height

The `SIGWINCH` hazard, which is the reason `PaneStatusBarMetrics.reservedHeight`
ignores its parameter. The footer sits under the terminal, so a footer that grows
shrinks the ghostty grid and reflows whatever is running in the pane: in a pane
driving a coding agent, looking at the pane would destroy what it was showing.

Asserted on the metrics (`height`, both spellings of `reservedHeight`,
`baselineFromTop`, and `intrinsicContentSize` for a rounded bar against a square
one) and then on pixels. A real `PaneStatusBarView` is built twice, once square
and once with both corners rounded, rendered through `cacheDisplay(in:to:)`, and
every pixel more than the focus frame's own width inside the bar's outline has to
be identical. 840 pixels differ between the two bars and all of them are on the
bar's edge, where the fill's curve, the hairline and the frame live.

The allowance is the frame's width plus one pixel. The extra pixel is antialiasing
slack: the frame's outer edge lands exactly on the band boundary, and a curve
there bleeds a single unit of 255 into the pixel beyond it.

The control damages both gates, because there are two ways the footer can move: a
bar one point taller, which the size gate catches, and a bar whose anchor name is
longer so its contents sit somewhere else, which the pixel gate catches with 3655
pixels moved inside the bar.

## clip

Every arm above measures a path. This one measures pixels, because a path that is
right proves nothing about a view that never applies it: delete the `addClip()`
from `PaneStatusBarView.draw(_:)` and `radius`, `match`, `concentric` and `height`
all stay green while the footer goes back to a rectangle. Verified by doing it.

A real `PaneStatusBarView` is rendered through `cacheDisplay(in:to:)` and its
bottom-left corner is profiled out of the alpha channel, then compared against the
window's own mask the way `match` compares the path. Alpha only, which is what
makes the reading independent of the anchor name: text is drawn over an opaque
fill, so it moves colour and not coverage.

Two details of how it is set up carry weight:

- The corners are asked for through `PaneTree.bottomCorners(in:)`, on the owner's
  2x3 grid, rather than written as `.left`. The query has its own unit tests; what
  this adds is that the pixels were shaped by the answer the app pushes.
- The bar is rendered **unfocused**. The focus frame is stroked on its own copy of
  the path by `drawBarFrame(in:)` and would keep the corner in the bitmap by
  itself, so a focused bar cannot answer for the fill.

The hairline's own rows, the bottom 1 pt, are dropped. They are where two draws
composite through the same clip, the fill and then the hairline on top of it, and
two antialiased passes over the same partial coverage saturate the row sooner than
one: the bottom row reads 1.04 pt further out than the path it was clipped to,
the row above it 0.22, and the first row with a single draw in it 0.02. `match`
fills the same path once and reads that bottom row exactly, to four decimals,
which is what says this is compositing at a shallow angle rather than a shape.

The tolerances are looser than `match`'s, 0.04 inward and 0.07 outward against
0.01 and 0.06, because this compares a rasterized edge to a path rather than two
paths. The measured spread is 0.022 inward and 0.047 outward. That is nowhere near
loose enough to pass a square bar: the control renders the same bar with no
corners, which is pixel for pixel what a `draw(_:)` with no clip produces for a
pane in the corner, and it misses by 10.03 pt on the second row.

## frame

The attention frame is the one surface that reaches a window corner without being
on the footer, and until 2026-07-30 it was the one surface that did not go through
`WindowCorner`. `PaneEdgeFrameView` drew `NSBezierPath(rect:)`, so at a corner the
pane shares with the window its edge carried straight past the point where the
footer's fill curved away and the mask cut the overhang off into a spur. Found on
a screenshot, not by any of the six arms above, because all six measure the bar.

The two shapes overlap at that corner and are drawn in the same colour when a pane
is both asking and in the corner, which is what makes a 2 pt disagreement read as
damage rather than as a detail.

A real `PaneEdgeFrameView` is rendered through `cacheDisplay(in:to:)` and profiled
out of the alpha channel, the same way `clip` profiles a real bar, and for the same
reason: a path that is right proves nothing about a `draw(_:)` that does not use
it. Three things are worth naming:

- What is profiled is the **outer** edge of the stroke, and the reference is the
  window's mask with no allowance subtracted. That is the concentric rule landing:
  a 2 pt stroke whose centreline sits 1 pt in at radius 15 puts its outer edge on
  the window's own 16. A frame that reused 16 on the inset rectangle would read
  1 pt outside the mask here, which `concentric` catches as a path and this catches
  as pixels.
- The view is 200 pt tall, so all 24.46 pt of the corner is in the bitmap. The
  footer can only ever show 22 of it. The arm still reads 22, because the last of
  the curve is nearly vertical and a pixel row there spans several points of shape.
- The bottom stroke's own rows, the bottom 2 pt, are dropped for the reason `clip`
  drops the hairline's: down there the curve is nearly horizontal and the coverage
  saturates well outside the path it came from.

The tolerances are `clip`'s, 0.04 inward and 0.07 outward. The shipped frame
measures 0.004 inward and 0.035 outward. The control is the square path that
shipped until 2026-07-30, which is the regression this arm exists to catch, and it
misses by 7.88 pt.

## fullscreen

A window in full screen is masked to the display, not to a 16 pt corner. A footer
that keeps its curve there carves a wedge out of itself, 24.46 pt wide at the
window's bottom edge, and since nothing paints under the bar what shows through is
the window's own `backgroundColor`: a system-appearance colour on chrome that is
otherwise strictly the terminal's.

A real window is driven through both transitions rather than a style mask being
built with `.fullScreen` in it, because the question is *when* the mask flips.
`PaneTreeController` observes `didEnterFullScreen` and `didExitFullScreen`, and
that is only correct because at `willEnterFullScreen` the window still reports
itself windowed:

```
windowed         radius 16.000   WindowCorner.isRounded true
full screen      radius  0.000   WindowCorner.isRounded false
windowed again   radius 16.000   WindowCorner.isRounded true
notifications: WillEnterFullScreen=windowed, DidEnterFullScreen=full,
               WillExitFullScreen=full,     DidExitFullScreen=windowed
```

Both readings are taken at each state, the radius and the shipped predicate,
because either alone can agree with the app by accident: the radius says what the
system is doing and `WindowCorner.isRounded` says what the footer will do about
it. The notification order is asserted too, so an OS that moved the flip to `will`
fails here rather than leaving the wedge on screen. And it is asserted that the
transition happened at all, since a machine that refused to go full screen would
otherwise pass three windowed checks and call the bug fixed.

The control is the predicate as it was before this was fixed: every window is
round. It is the bug itself.

## What this cannot reach

`PaneTreeController`, which owns `TerminalPaneController` and therefore needs
libghostty, a Metal device and a spawned shell. So the push path,
`pushBottomCorners()` reading `displayedTree` and the window and assigning to each
pane, is not run here. Both ends of it are: the query is unit-tested in
`WorkspaceLayout` (`PaneTreeCornerTests`) and read by `clip` and `frame`, the
drawing is measured by `clip` and `frame`, and the fact the window half depends on
is measured by `fullscreen`. The wire itself is still only read.

That gap has cost something once. `TerminalPaneController.bottomCorners` reached
the footer and not the attention frame for four days, and no arm here could have
seen it, because the value both views need is assigned on the far side of a
controller this probe cannot build. A third view that draws into a corner would
fail the same way: the arm below it would pass on a value nothing pushed.

The window is never made key and nothing is captured. **The last step, that the
corner on screen is the one measured here, cannot be proven without looking.**
