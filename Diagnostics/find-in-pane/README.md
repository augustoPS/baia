# Find panel probe

`./run.sh` from anywhere. Two cases, one process each, both under `set -e`.

The question this exists to answer is not "does ⌘F open a panel". It is whether
the find panel can break the two things in baia that fail silently: a responder
inside a pane's window, and a reference that keeps a dead pane's shell alive.

`responder` is invariant 1. `AppTerminalView.performKeyEquivalent` opens with
`guard window?.firstResponder === self`, so anything in a pane's window that
takes first responder disables every ghostty binding in that pane, with no error
and nothing on screen to explain it. The case builds a window holding a terminal
stand-in, makes it first responder, opens the real `FindPanelController` over it,
types, leaves once by Escape and once by Return onto a match, and asserts at
every step that the panel is a window of its own, that no `NSControl` has been
added to the pane's window, that the terminal is still that window's first
responder, and that closing the panel asked the pane's window for the keyboard
back exactly once per dismissal.

`retention` is the leaked-shell check. libghostty exposes no way to close a
surface, so a pane's pty dies only when its controller deallocates and
`PaneTreeController` is the sole owner of one. The case gives the panel a result
for a pane, drops the workspace's only reference to that pane while the panel is
still open and still drawing the match, and asserts the pane deallocated anyway,
that the row is still drawn from the lines it copied, and that Return still
reports the match by id. `FindResult` carries a pane id and strings precisely so
that all four of those can be true at once.

## The negative controls

Both run out of tree, on 2026-07-27, not checked in because each requires
breaking the thing under test.

`if hadKey { hostWindow?.makeKey() }` in `FindPanelController.dismiss()` replaced
with `_ = hadKey`: the responder case failed both hand-back assertions and exited
1. So the panel really is what returns the keyboard, and the count is not
measuring something AppKit would have done anyway.

`find.onCollect` rewritten to close over the pane array strongly instead of
reading it weakly through the owner: the retention case failed both deallocation
assertions and exited 1. So the case can see a leak of exactly the shape it
exists to forbid.

## Limits

Nothing here is part of the app build. `Sources/FindPanelController.swift` and
`Sources/CommandPaletteView.swift` are compiled from the repo verbatim, so those
two cannot drift from what ships at all; `PalettePanel` is sliced out of
`Sources/CommandPaletteController.swift` with `awk`, and if that class moves, the
`awk` boundary is the line to fix.

`TerminalPaneController` is out of reach: it needs libghostty, a Metal device and
a spawned shell. `TerminalStandIn` is an `NSView` that accepts first responder,
which is the whole of what invariant 1 is about, and `PaneStandIn` is an id and
its lines, which is the whole of what crosses the panel's boundary. What the
probe cannot say anything about is therefore the surface side: that
`readScreenLines` returns what the pane really holds, that the row a match
resolves to is the row it is drawn on, and that ⌘F reaches
`AppDelegate.findInPane` through the menu bar. Those are the live checks in the
plan's Task 9.

The app is never activated, so an ordinary window in this process is never
`isKeyWindow` whatever the code does. That is why the hand-back is asserted as a
counted `makeKey()` on the pane's window rather than as key status. The panel is
a `.nonactivatingPanel` and does take key in that state, which is what makes the
path under test run at all.
