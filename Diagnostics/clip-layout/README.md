# Clip-layout probe

`./run.sh` from anywhere. It drives a real `ChangesRowsView` through a first
layout, a width change and a scroll, and asserts that the three things derived
from its size follow: the document view's frame, the tracking areas, and what is
actually drawn. Four arms, one process each, and every arm is followed by a
`break` variant that damages the thing under test and is expected to fail.
`run.sh` inverts those, so a control that stops failing fails the run as loudly as
an arm that stops passing.

## The shape this exists for

**Something is derived from a view's size, the size changes, and the derived thing
is never rebuilt.** A view whose clip has not been laid out reports a width of zero
or falls to a floor of one, and whatever was built from that reading survives for
the life of the surface.

Four instances so far, each found by hand and each costing a trace:

| Found | What it looked like |
|---|---|
| 2026-07-29 | The document view drew into one point. Switching the sidebar on built a fresh surface, thirteen changes were pushed into it, and the column stayed blank until any command made the poller re-assign `changes` |
| 2026-07-29 | The file tree could not be hit at all |
| 2026-07-29 | Hover tracking areas covered nothing, for the life of the surface. Design v3 §2.3's four row states had nothing to fire them |
| 2026-07-30 | A rows view that never repainted when its column changed width. At the 120 pt floor "not a repository" drew as "not a r", running under the divider with no ellipsis |

Every one of them was a hand-found hour. This probe is the fifth hour, spent once.

## What it cannot reach

`SidebarHost` itself, which owns `PaneTreeController` and therefore libghostty, a
Metal device and a spawned shell. What the probe reproduces instead is the *shape*
of that host: a scroll view framed by hand inside a window, resized by
reassigning that frame. Both halves of that sentence were measured rather than
assumed, and both are load-bearing:

- **Framed by hand, not pinned by constraints.** `SidebarHost.viewDidLayout`
  assigns `section.surface.view.frame` directly, for the reason it records: a
  column of stacked rects recomputed on resize is the case autolayout costs more
  than it saves. A scroll view pinned by constraints resizes its clip *without ever
  delivering a layout pass to the document view*, so a rows view that follows its
  clip perfectly reads as one that never resized. The first draft of this probe did
  exactly that and the `width` arm failed against correct code.
- **`window.layoutIfNeeded()`, not `contentView.layoutSubtreeIfNeeded()`.** After a
  resize the content view's subtree pass does not reach the document view either.
  It reports `needsLayout == false` and its `layout()` is never called. The
  window's own pass does deliver it, and is also the pass AppKit runs after a live
  divider drag.

A probe that got either wrong would be green and would be measuring nothing, which
is why both are spelled out in `Host` rather than left to read as boilerplate.

`Sources/ChangesSurface.swift`, `Sources/WorkspaceSurface.swift`,
`Sources/RowFeedback.swift` and `Sources/DividerGrabView.swift` are compiled
verbatim by `run.sh`, not sliced and not retyped. `DividerGrabView` was the last
hundred lines of `SurfaceHosts.swift` until this probe existed: `SurfaceTitleView`
names `DividerGrabView.Touch`, so `WorkspaceSurface.swift` could not be compiled by
anything that was not the whole app, and neither could `ChangesSurface.swift`
beside it. Moving it to its own file is what made the sidebar reachable from here.

## The controls

Two, because the shape has two halves and one stand-in cannot carry both.

`StaleRowsView` never re-derives its geometry: the width is read in `init`, before
any clip has been laid out, and the tracking areas are built once from
`updateTrackingAreas`, which AppKit calls before the clip has a visible rect. Its
`layout()` is `super.layout()` and nothing else. That is the 2026-07-29 shape, and
it is the control for `floor`, `width` and `tracking`.

`StaleDrawingView` is correct everywhere except the one place under test: its frame
follows the clip exactly, and it lays its message out into the width it read when
the content arrived. That is the 2026-07-30 shape, and it is the control for
`reflow`. `StaleRowsView` would fail that arm too, by being one point wide, which
would prove the arm can fail rather than that it can catch this.

## floor

The most expensive of the four. A surface installed and populated *before* its clip
view has a size must not keep the width it read then.

The arm runs the order that produced it: build, install, push thirteen rows, and
only then lay out. The shipped view ends at the clip's 220 pt. The control ends at
1.0 pt, which is the floor `max(superview?.bounds.width ?? 0, 1)` falls to, and
which is what put every row into a document view one point wide.

## width

The same question one moment later: a resize after the surface has settled. The
document view follows the clip from 220 to 120.

The clip's own width is printed beside the document's. If the two disagree the rows
view is at fault; if the clip never moved, the host is, and the arm is measuring
nothing rather than measuring something that passed.

## tracking

The areas cover the rows the clip can show, so they have to follow both the size
and the scroll, and neither is a frame change on this view.

Four claims, in order: areas exist after the first layout at all; they survive a
resize; every one of them is inside the new 120 pt and none is wider; and none has
collapsed to a sliver. Then the clip is scrolled 400 pt with the frame untouched,
and the topmost area has to have moved down with it. That last one is the check
that matters, because `updateTrackingAreas` is called by AppKit for a frame change
and for nothing else: without the scroll observer the areas would be correct at
rest and wrong the moment the list is scrolled.

The control builds seventeen areas' worth of rows and registers zero, which is what
an empty visible rect produces, and still zero after the resize and the scroll.

## reflow

What is drawn has to be laid out for the width the view has *now*.

The absent state rather than a list of rows, because the rows never exposed this:
a row draws from a left inset that does not move, while the empty and absent
messages are centred in the visible rect. That is why the bug showed up as
"not a r" and not as a misdrawn file name.

Measured as the shared top-left corner of two renders, one at each width. A view
that re-lays its text out draws something different there. A view drawing from a
captured width draws the same pixels and loses only the part that no longer fits,
which is a crop rather than a reflow, and the shared corner gives it away. Both
dimensions are clipped to the smaller render, not just the width: a column that
changes width also changes the height of a document view sized to its clip, and a
comparison that let the row count vary would report "different" for two identical
drawings with a different number of blank rows under them.

The sequence is settle, *then* push the content, then drag: the poller pushes state
into a sidebar the owner has been looking at, and only afterwards is the divider
moved. Pushing before the first layout is `floor`'s question, not this one.
