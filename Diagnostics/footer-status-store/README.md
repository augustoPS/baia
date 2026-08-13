# Footer status store

`./run.sh` from anywhere. Four arms — `gated`, `pulse`, `strip`, `handed` — each
followed by its inverted control; exits non-zero if any arm's invariant breaks or
if any control loses its teeth. Needs only `swiftc`; no app build, no capture, no
`python3`.

**Safe from anywhere, including inside a baia pane.** No window is ever ordered
on screen: the shipped `PaneStatusBarView` is compiled verbatim and rendered
through `cacheDisplay(in:to:)` into an offscreen bitmap, the `cluster-notice`
arrangement. Two arms render nothing at all — they read a `CALayer` back after a
property write. It is in `guard-baia-alive.sh`'s `SAFE_PROBES` on that ground.

## The question

The pane's canonical `PaneStatus` store moved off the footer on 2026-08-13. Does
the footer, now merely *handed* the value, still keep the three invariants its
`didSet` carried when it owned it?

1. **change-gating** — the anchor tracker polls once a second, so a redundant
   write must repaint nothing. An unconditional repaint would redraw every pane's
   footer every second for nothing.
2. **the arrival pulse fires on the transition** into asking, not on a repaint
   that happens while the pane is already asking. A pane that blinks on every git
   poll is one the eye learns to ignore.
3. **the wash's animations come off before the repaint**, not after. `invalidate`
   only writes the wash's opacity when no animation is running, so stripping
   afterwards left an acknowledged pane frozen as a solid alert band.

## Why it is a probe and not a package test

All three are statements about an `NSView` and a `CALayer`, and the app target
has no test target. A package test asserting "setting the same value twice does
not redraw" would pass in a harness where nothing redraws under any
circumstances — worth nothing, and the exact shape this repo has been burned by
repeatedly.

## The instrument, and the one that did not work

The obvious instrument for the change-gate is `needsDisplay`, and it was tried
first. It measures nothing here. Detached from a window it never latches; in an
unordered window it never clears; an explicit `needsDisplay = false` does not
stick while the window has display pending; and under `displayIfNeeded` AppKit
reports the parent and all three subviews clean whether the write was redundant
or real. Every configuration read **the same for a gated write and an ungated
one**, so a gate test built on it would have passed because nothing was
observable.

What replaced it is the wash's opacity, which `invalidate()` writes
unconditionally whenever no animation is running. `poisonWashForTesting()` puts
0.5 there — a value neither `invalidate` nor the pulse would ever legitimately
write — the write under test runs, and the value is the answer: still 0.5 means
the repaint was gated away, overwritten means it ran.

The `gated` arm asserts both halves. "A redundant write repaints nothing" is only
meaningful beside "and a real change does", or it passes in an inert harness.

## Verified against broken code

Each arm was observed failing against a deliberately broken `PaneStatusBarView`,
not only against its scripted control:

| mutation | arm | message |
|---|---|---|
| `guard storedStatus != oldValue` deleted | `gated` | `an identical status repainted the bar: the change-gate is gone, and the once-a-second anchor poll now repaints every pane's footer for nothing` |
| pulse condition reduced to `attention == .asking` | `pulse` | `a pane that repainted while still waiting pulsed again: the arrival pulse is being decided by the state instead of by the transition` |
| strip moved after `invalidate()` (the pre-2026-08-09 ordering) | `strip` | `acknowledging inside the 0.51 s pulse left the wash at 1.0: the footer is frozen as a solid alert band until something else repaints it` |

The `handed` arm covers the refactor's own failure mode, which the compiler does
not catch: dropping `statusBar.status = rebuilt` from
`TerminalPaneController.refreshStatus()` builds clean and silently blanks the
footer.
