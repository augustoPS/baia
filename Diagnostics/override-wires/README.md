# override-wires

**The question.** Does each chrome extra in `DesignOverrides` actually reach the
pixel it claims to move, and does an undialled override leave the rendering
exactly where it was?

Both halves matter and neither implies the other. A wire that moves nothing is
the `focusAccent` defect this codebase names repeatedly — decoded, stored, and
never read by the one line that mattered. A wire whose *default* moves something
is worse, because it changes what ships in exchange for a knob nobody asked for.

**What would be false if this probe passed and the code were wrong.** Nothing
this probe asserts can hold while a lift parameter, the rim, the busy dot's
colour or the bar lift is reaching the wrong site or no site at all. Each arm
compares two renderings of the *shipped* view types, compiled verbatim, so a
mapping that had drifted would show up as a rendering that failed to move or a
default that moved on its own.

## Run it

```
./run.sh
```

**Safe from anywhere, including inside a baia pane.** No window is opened, no
focus is taken, nothing is launched and nothing is quit. Every arm renders a view
offscreen into an `NSBitmapImageRep` through `cacheDisplay(in:to:)` and reads the
bytes back. On that count it is in the same class as `theme-catalog` and
`app-icon`.

## Why offscreen and not a capture

`glass-backdrop` needs a real compositor because its question is what an
`NSGlassEffectView` *samples*, which only the window server can answer. This
probe's question is different: what does this app's own drawing code put down.
That is decided entirely inside the process, so rendering offscreen is not a
weaker version of a capture — it is the stronger measurement, because it is
deterministic and machine independent. No wallpaper, no display scale, no focus
steal, and two runs a week apart compare the same numbers.

Byte equality rather than a tolerance, for the same reason. The claim under test
is "renders byte-identically", and a tolerance would let a wire that shifted every
pixel by one level pass as unchanged, which is exactly the drift a default pinned
to the wrong constant produces.

## The arms

Each is followed by an inverted negative control. `run.sh` fails if a control
stops failing, which is what stops an arm that has quietly become a tautology
from reading as evidence.

| arm | what it says |
|---|---|
| `lift-nil` | A lift view never handed a `parameters` value renders the same bytes as one explicitly given `PaneLiftParameters.shipped`. This is an assertion about the *default*, not `.shipped` compared with itself |
| `lift-ring` | `ringAlpha` and `ringSpread` move the rendering, and a 6 pt spread moves a band of pixels rather than a hairline — the direction the knob names, not merely "something moved" |
| `lift-highlight` | `innerHighlightAlpha` and `innerHighlightOffsetY` move the top edge |
| `lift-enabled` | `enabled = false` renders what a lift that was never made visible renders. Off has to mean *absent* for the knob's own question ("is the lift carrying its weight?") to be answerable by switching it off |
| `rim` | Off is the shipped rendering, byte for byte: the rim constants' first consumer added a knob without adding a pixel. On changes the rendering, and `topAlpha` moves it again |
| `surface-fill` | The four material roles resolve to four distinct colours, nil resolves to no tint, and one role answers differently in the dark and light sets |

Two arms were dropped on 2026-08-13, when `Sources/PaneStatusBarView.swift` was
deleted: `busy-dot` (`busyDotHex` repaints the dot and nothing else, measured at
92 differing pixels and bounded above at 200) and `bar-lift` (`barLift` repaints
the bar, measured at 26342 and bounded below at 1000). Both rendered the footer,
which was the only view that drew either dial.

The two dials still exist in `PaneThemeAdjustments`, so their wires are now
**unwitnessed rather than proven absent** — nothing surviving draws a busy dot
or lifts a bar, so there is no pixel to re-aim at today. If a later surface
picks either dial up, this is the probe that should grow the arm back, and the
bounds above are the numbers it had.

## What this probe does not measure, and why

**The surface fills are checked at their resolution, not at a pixel.** A dialled
`DesignOverrides.Chrome.Surfaces` value becomes an `NSGlassEffectView.tintColor`,
and what the compositor does with a tint is not something this process renders —
`cacheDisplay` on a glass-backed view captures this app's own drawing, not the
material's contribution. So `surface-fill` asserts that the mapping is correct,
distinct per role and appearance-sensitive, and stops there. That the tinted
glass then *looks* different is owed to the owner's eye through the panel, and it
is recorded as owed rather than claimed.

**The sidebar's wash floor had no arm here, and now has no knob either.**
`chrome.sidebarWashFloor` put a minimum under the sidebar's glass wash. It never
got an arm because `SidebarHost` is an `NSViewController` whose glass is built
against a live window, so it does not render standalone the way `PaneLiftView`
does, and the way `PaneStatusBarView` did before its deletion. Both the wash and the floor retired on 2026-08-08,
when the owner A/B'd naked native glass against the hand-drawn layer through
`chrome.bareGlass` and ruled that the naked material wins. `chrome.bareGlass`
retired in the same stroke, having answered the one question it was built to ask.

**`chrome.paneWashFloor` and the pane plane inherit the same gap, written down
here for the same reason.** The pane-as-glass work (2026-08-09) gave every
glass pane a `PaneGlassPlaneView` with a `PaneGlassWashView` over it, both
owned by `TerminalPaneController` and built against a live window, so neither
renders standalone and neither gets an arm: `cacheDisplay` on the plane would
capture no material contribution, and the wash's pixels only mean something
composited over that material. What covers the knob instead: the arithmetic
under it (`max(backgroundOpacity, floor)` and the 0.4712 AA bound) is pinned in
`ChromeMaterialsTests`' `PaneWash` suite, the composited result is measured by
`pane-glass-legibility`'s shipped-default arm through the screen route, and the
look of a dialled floor is owed to the owner's eye through the panel, recorded
as owed rather than claimed, exactly as `surface-fill`'s visual half is above.

**The lift's duration has no arm here.** It reaches a `CABasicAnimation`, and a
transition's length is not something a still rendering can hold. The wire is
visible in `PaneLiftView.apply(animated:)` and Reduce Motion still wins over it.

**The ink ratio and the ink hex are not here**, deliberately: they are decidable
without a view and are asserted in `PaneThemeAdjustmentsTests` in the
`PaneChrome` package, field by field and across a dark and a light theme. A probe
arm restating a package test would be a second copy free to drift from the first.
There were three ratios and two hexes until 2026-08-12, when the rulings that
removed the sidebar's session header and its "New session" row took the
derivations those dialled; the sentence is worth keeping in this shape because
what makes them absent is where they are decidable, not how many there are.

**A sidebar-ink arm was written and then removed, and the reason is worth
recording.** The intended arm would have rendered the sidebar's two ink-bearing
rows under `.flat` and `.glass` and asserted their ink does not move between the
two — the exact claim a first cut of this wiring got wrong, by branching on
`resolvedChrome` and grading against the bright-glass stand-in, which fires the
repair chain and walks `#898989` to `#dcdcdc` with every override nil. Both views
imported only `AppKit` and `PaneChrome`, but one of them read two constants off
the sidebar's shared row metrics, which lived in `ChangesSurface.swift` and would
have dragged most of the sidebar hierarchy onto this probe's compile line. That
was a bigger dependency than the arm was worth.

**That pricing moved three times on 2026-08-12 and the arm ended with no
subject.** The morning's ruling removed the CHANGES section and the constants
moved to `Sources/SidebarRowMetrics.swift`, a leaf importing only `AppKit` and
`PaneChrome`, which made the arm cheap to compile. The afternoon's first ruling
removed `SidebarSessionHeaderView`, leaving one row to render rather than two.
The second removed `SidebarActionRowView`, the "New session" row being a second
face for the `New Tab` menu item, and its ink derivation and two dials retired
with it. Both ink-bearing rows this arm was about are now gone, so it is
unwritable rather than merely unwritten: the sidebar's one surviving graded ink
is `SurfaceTitleView`'s caps label, which *does* branch on `resolvedChrome` by
design, so an arm asserting an ink does not move between flat and glass would now
assert the opposite of the shipped rendering. Recorded because "cheap to compile
now" was the last note here, and a later reader acting on it would write a red
arm against correct code.

What caught the defect instead, and what would catch it again, is
`PaneThemeAdjustmentsTests.theRepairIsNotANoOpOnTheBrightGlassStandIn`: it pins
that the repair is *not* the identity on `#4b4b4b`, so the "these derivations are
the identity" claim is stated with the backdrop it depends on. The residual gap
is the surviving view's choice of backdrop, which is asserted in prose at
`SurfaceTitleView.measuredBrightGlass` and by a reviewer's eye, not by a test.

## Related

- `footer-corners/` compiled the same shipped files and measured their geometry.
  It was the byte-stability contract for the flat path; this probe is the
  wire-continuity contract for the glass-side extras. It froze on 2026-08-13
  with the footer it compiled, so that contract is now unwitnessed rather than
  met, the same shape as the two arms this probe lost the same day.
- `glass-backdrop/` is the measured record of why the fills are dormant in the
  first place, which is the finding `SurfaceFill`'s own doc comment carries
  forward.
