# cluster-card-key

`./run.sh` from anywhere *outside a baia pane*. It asks one question: **does the
cluster cards' key discipline hold on a real window — key taken on show,
returned on every path that ends a card, and the capsule still clickable while
the card holds it?**

## This probe takes the keyboard, on purpose

**It is not in `guard-baia-alive.sh`'s `SAFE_PROBES` list, does not qualify for
it, and `guard-test.sh` pins that it stays denied.** The criterion the guard
enforces is focus, and this probe's subject *is* focus: `show` must take key
(the cards want ⎋ and nothing in a pane may take first responder, the
controller's own doc), and every dismissal path must hand it back. An arm that
avoided taking key would measure nothing — `design-panel-key`'s argument,
inherited whole. The first-mouse arm additionally posts one real CGEvent click,
at a point it first proves belongs to its own window, which needs the
Accessibility grant `lib/click.swift` already relies on. Focus returns when the
process exits; keystrokes typed during the few seconds of a run land somewhere
other than the pane. Run it from a second terminal.

## What is compiled, and what is retyped

`ClusterCardController` and `PaneClusterView` are **compiled verbatim** —
unlike `DesignPanel`, the controller shares no file with anything that reaches
the app target, so the key discipline under test is the shipped code. The one
retyped class is `PalettePanel` (two overrides, in
`Sources/CommandPaletteController.swift`, whose palette controller drags in the
app target). `run.sh` greps both overrides out of the shipped class body before
any arm runs, so a drift fails the run rather than being measured against a
copy nobody kept current — `design-panel-key`'s discipline, including its
lesson that a bare count is not a check.

**What would be false if this probe passed and the code were wrong.** Each arm
asserts where key actually sits (`NSApp.keyWindow`, the content view's own
window, `host.isKeyWindow`), not the controller's flag agreeing with itself. So
nothing here can hold while `show` fails to take key, while ⎋ or a
click-outside or a direct `dismiss()` strands key on a dead panel, while the
hadKey restore hands it to nothing, while a switch fires the wrong card's
teardown, or while the capsule's first click merely re-activates the host and
delivers nothing.

## Arms

Each runs in its own process (key status is process-global) and is followed by
an inverted negative control. For the five card arms, `break` makes the retyped
panel refuse key — the honest way to damage a system whose controller is
compiled verbatim, and every arm fails on its took-key precondition. For
`first-mouse`, `break` is different and is described with the arm.

### show

Host key, `show` → the panel is key and the host is not. The precondition every
other arm re-asserts.

### esc

A synthesized keyCode-53 `keyDown` sent to the panel, routed to the content
view — the panel's first responder, by the direct grant `show` makes — whose
`onClose` calls `dismiss()`. That is the shipped cards' exact wiring:
`ClusterPlaceCardView` and `ClusterChangesCardView` answer `cancelOperation`
and the 0x35 `keyDown` with `onClose`, and the pane wires `onClose` to
`clusterCards.dismiss()`. Afterwards: card gone, `onDismiss` fired once, host
key again.

### click-outside

The resign path: `host.makeKey()` while the card shows, which is what a click
into the pane amounts to from the panel's side. The card must come down through
the resign observer, which is documented one turn late, so the run loop is
pumped before the assertion. Host key, `onDismiss` fired once.

### switch

`show`, then `show` again with different content — the 63fd178 race regression
arm. The internal dismiss orders the panel out, enqueueing a `didResignKey`
that is delivered a turn late; without the observer's isKeyWindow guard that
queued delivery tore the new card down one turn after it opened. So the
load-bearing assertions come *after* the pump, on a second card that has lived
through the turn the race fired on: panel still key, still visible, the first
card's `onDismiss` fired exactly once, the second's not at all, the first
card's view out of the panel.

### dismiss

`show`, then `dismiss()` directly: the hadKey restore. Host key again, card
gone, `onDismiss` fired once.

### first-mouse

The question Task 5 deferred here: with the card up and its panel key, a click
on the capsule reaches a **non-key** window — does it still reach
`onSegmentClick`? That is `PaneClusterView.acceptsFirstMouse` earning its keep;
without it AppKit spends the click on re-activation and the same-segment toggle
needs two clicks.

**Mechanism: a real CGEvent through the window server, because the synthetic
routes are dishonest here — measured, not assumed.** Before this probe was
written, a synthesized `NSEvent` was delivered through both
`NSWindow.sendEvent` and `NSApplication.sendEvent` against a view whose
`acceptsFirstMouse` answered false, and the `mouseDown` arrived anyway, both
times: the first-mouse discard happens upstream of anything a synthesized
`NSEvent` can enter through, so a synthetic click would have "passed" this arm
with the override deleted. The real post (`lib/click.swift`'s two-event
sequence, inlined) exercises the gate in both directions, and the arm's own
control is the proof: `break` swaps the capsule for a view with the override
*missing* — `NSView`'s default — and the identical click is not delivered.

The arm also rides the same click to the end of the shipped flow: activating
the host resigns the panel, and the resign observer takes the card down. One
click, three facts — delivered to the segment, key handed back, card dismissed.

Safety: the host window sits at `.popUpMenu` level and the arm refuses to post
if `NSWindow.windowNumber(at:)` says the click point is not its own window, so
this probe can never press someone else's button. Without the Accessibility
grant the arm fails with a message naming the grant rather than silently
passing.

## What this cannot reach

**The pane's toggle.** Which segment's card is up, and whether a second click
on the same segment dismisses rather than reopens, lives in
`TerminalPaneController.clusterCardRole` — app target, unreachable from here.
This probe proves the mechanism under it: the click arrives (first-mouse), and
`isShowing`/`onDismiss` tell the pane the truth on every exit.

**The real cards' content.** The probe's card is a stand-in keeping the shipped
cards' Esc contract; what `ClusterPlaceCardView` and friends draw, and their
subscriptions' cleanup beyond `onDismiss` firing, is theirs.

**`chrome.cluster.cornerInset` as a dial.** The capsule here is pinned at the
shipped inset (which is what places the segment the click then hits); the
dialled re-pin lives in `TerminalPaneController.clusterCornerInset`'s `didSet`,
behind the same app-target wall. `cluster-wires`' README carries the full
entry.

## Related

- `cluster-wires/` — the capsule's draw wires, offscreen, no window at all: the
  safe half of the pair.
- `design-panel-key/` — the probe whose shape this one inherits: key as the
  subject, one process per arm, retyped-code grep guards, and the measured
  record of what `makeKey()` on an `.accessory` app's panel does to focus.
- `Sources/ClusterCardController.swift` — the class under test, whose doc
  comments carry the approval popover's key discipline this probe pins.
