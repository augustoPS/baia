# Design panel key probe

`./run.sh` from anywhere. It asks one question: **does the design panel's
`wantsKey` flag come back down on every path that ends an editing session?**
Five arms, one process each, and every arm is followed by a `break` variant that
strips the two window-level overrides and is expected to fail. `run.sh` inverts
those, so a control that stops failing fails the run as loudly as an arm that
stops passing.

## Do not run this from the pane you are typing in

**This probe is not in `guard-baia-alive.sh`'s `SAFE_PROBES` list, and it does not
qualify for it.** Every other member of that list either opens no window or opens
windows nothing takes focus from; the criterion the guard enforces is focus, not
invisibility, and it names `footer-corners` as denied specifically for calling
`makeKeyAndOrderFront`.

This probe takes the keyboard, and cannot not. Its whole subject is a flag about
taking key, so an arm that avoided taking key would be measuring nothing. That
was checked rather than assumed:

```
after orderFront: frontmost=Ghostty  panelIsKey=false  appActive=false
after makeKey:    frontmost=Ghostty  panelIsKey=true   appActive=true
after close:      frontmost=Ghostty                    appActive=false
```

`makeKey()` on an `.accessory` app's nonactivating panel moves
`NSApplication.isActive` from false to true and takes key, while leaving the
frontmost *application* unchanged at the Dock level. Focus returns when the
process exits, so the cost is bounded to the two seconds of a run — but
keystrokes typed during it go somewhere other than the pane. Run it from a
second terminal, or from a pane you are not typing into.

## What is under test, and the one thing this probe cannot compile

`DesignPanel`, in `Sources/DesignPanelController.swift`:

```swift
var wantsKey = false
override var canBecomeKey: Bool { wantsKey }
override func resignKey()  { super.resignKey(); wantsKey = false }
override func orderOut(_ sender: Any?) { wantsKey = false; super.orderOut(sender) }
```

The panel refuses key by default. Two of the ink knobs are hex fields, and a
window that can never become key holds a text field that can never be typed into,
so `HexField.mouseDown` raises the flag for the length of one editing session.
Everything else in the panel — every slider, checkbox, segmented control and
popup — works in a non-key window and never touches it.

**`keytest.swift` retypes those four lines rather than compiling them**, which
makes it the only probe here that is not measuring the shipped code verbatim.
`DesignPanel` shares a file with `DesignPanelController`, which reaches
`ConfigurationCenter` and from there the whole app target, so there is nothing to
compile in isolation the way `override-wires` compiles `PaneStatusBarView`.

Retyped code goes stale in the direction that matters: the probe keeps passing
while the app stops doing what the probe says it does. So `run.sh` greps the
shipped file for each of the four lines before any arm runs, and additionally
requires three `wantsKey = false` sites (both overrides plus the hex field's fast
path) — an override that kept the flag up would satisfy the four greps and be
precisely the bug. A rename, a deletion or an inverted guard fails the run at that
point rather than being measured against a copy nobody kept current.

## The bug this exists to catch

The first version of the panel lowered `wantsKey` in one place only: the hex
field's end-of-editing action. **Two ordinary paths end an editing session
without firing that action.** Escape aborts the field editor, and closing the
panel mid-edit orders it out. After either, the panel answered
`canBecomeKey = true` indefinitely, and the next click anywhere in it — a slider
drag included — took key from the pane.

That is the one property the panel's whole design exists to protect, undone by
the mechanism meant to protect it, and the class doc claimed the opposite. The
fix moves the lowering onto the window, where it is a fact rather than a
convention: `resignKey()` is the honest hook, since a panel that is no longer key
has ended whatever session took key, whatever ended it and whether or not a
control noticed.

## Arms

Each arm raises the flag and takes key the way a click into a hex field does,
then ends the session its own way, then asserts three things: the flag is down,
`canBecomeKey` answers false, and asking the panel to become key does not make it
key. The third is what says the first two describe the window rather than two
fields agreeing with each other.

### resign-key

Escape, and clicking back into a pane. Both end the session by key going
elsewhere while no control action fires. Modelled by another window taking key,
which is what both amount to from this panel's side.

The arm `resignKey()` exists for. Without it the flag stays up while the panel is
still on screen, which is the worst version of the leak: the panel is right there
and the next click on it is the theft.

### order-out

⌥⌘D while a field is being edited. `DesignPanelController.toggle()` calls
`orderOut(nil)` directly.

### perform-close

The titlebar close button, which drives `performClose(_:)` → `close()`.

A separate arm from `order-out` because it is a **different entry point** that
could plausibly bypass both hooks, and whether it does is a fact about AppKit
rather than something the code can assert about itself. It does not:

```
close()        -> ["orderOut", "resignKey"]
performClose() -> ["orderOut", "resignKey"]
```

Both route through `orderOut(_:)` *and* fire `resignKey()`, in that order, on a
`.titled`/`.closable` nonactivating panel. So the close path is covered twice.
The arm keeps checking it rather than trusting the measurement, because it is the
kind of thing an OS release moves.

`.titled` and `.closable` are in the probe's style mask for this arm's sake:
`performClose(_:)` is a no-op on a panel with no close button, so a borderless
probe would pass this arm by never testing it.

### order-out-never-key

Ordering out a panel that was never key: the flag raised, no key ever taken, then
closed.

**The path `resignKey` alone cannot cover**, since no key was held and none is
resigned. It is the arm that stops the two overrides from looking like one plus a
redundancy — `resignKey` alone misses this, and `orderOut` alone misses
`resign-key` above.

### reopen

Closed mid-edit, then reopened with ⌥⌘D. The state the owner actually reaches:
dial, type a hex, close, come back later.

**The arm that carries the latent leak through to a panel back on screen**, and
the reason it exists separately from `order-out`. A window that has been closed
cannot become key whatever its `canBecomeKey` says, so in `perform-close` and
`order-out-never-key` the control fails on the flag and on `canBecomeKey` while
*passing* the third check. That is AppKit rather than a hole: the leak in those
two arms is real but latent, and the theft happens on the next open. Here the
panel is back on screen with the flag still up, and the control fails all three.

## The controls

One class with a `lowersOnWindowEvents` flag, rather than a subclass that
overrides the fix away. Swift has no `super.super`, so a subclass wanting
`NSPanel`'s implementation past its own superclass's has to duplicate the class
or reach for the Objective-C runtime, and both put the control further from the
code it is meant to be identical to. A flag consulted at the one line that
differs keeps the two versions a single readable diff.

`false` is the panel exactly as it shipped before the fix. Every arm ends its
session by a path that fires no control action, so "the hex field's action never
ran" is modelled by no lowering happening at all.

Measured, at the time of writing:

| arm | control fails | panel on screen at the assertion |
|---|---|---|
| `resign-key` | 3 checks | yes |
| `order-out` | 2 checks | no |
| `perform-close` | 2 checks | no |
| `order-out-never-key` | 2 checks | no |
| `reopen` | 3 checks | yes |

Twelve failing checks across five controls, and the split in that last column is
the whole reason `reopen` is an arm. Three of the five end with the panel off
screen, where a window cannot become key whatever its `canBecomeKey` says, so
their controls fail on the flag and on `canBecomeKey` and pass the third check.
Only the two arms that assert against a panel still on screen fail all three, and
one of those two — `reopen` — is the one that carries a leak from the off-screen
arms through to the moment it would actually cost something.

Stripping the two overrides is the bug itself, so a control that stopped failing
would mean an arm had become a tautology.

## What this cannot reach

**The field editor.** Every arm models the end of an editing session by the
window-level event that accompanies it — another window taking key, an
`orderOut`, a `performClose` — rather than by a real `NSTextField` being escaped
out of. So what is verified is that the flag comes down when key is lost or the
panel is ordered out, on every path that does either.

What is *not* verified here is the assumption underneath: that pressing Escape in
a live field editor produces one of those events and fires no control action. That
is why the panel's own doc states it, and why the live check is still owed:

> Open a pane running `watch -n1 'stty size'`. Open the panel, click a hex field,
> press Escape, then drag a slider. The keyboard must still be in the pane and the
> reported size must never change.

`HexField.mouseDown` is not exercised either — it is the raise side, and this
probe raises the flag by assignment. Both ends of the wire are read (the raise is
one line in the shipped file, checked by `run.sh`'s grep; the lowering is what the
arms measure), but the click that connects them is not.
