# Capsule legibility

`./run.sh` from anywhere. Three arms — resting, focused, dot — each followed by
its inverted control; exits non-zero if any arm misses its floor, if any control
loses its teeth, or if the measured fill band stops matching the flatten
arithmetic. Needs only `swiftc`; no app build, no capture, no `python3`.

**Safe from anywhere, including inside a baia pane.** The probe opens no window,
takes no focus, launches nothing and quits nothing: every arm renders the
shipped `PaneClusterView` offscreen through `cacheDisplay(in:to:)` and reads the
bytes back, the `cluster-wires` arrangement. TODO: SAFE_PROBES membership — the
probe qualifies on `override-wires`' ground (nothing here ever reaches a
compositor), and adding it to `guard-baia-alive.sh`'s list is the coordinator's
call, not this task's.

## The question

The pane cluster moves the footer's facts onto a pill floating over the
terminal, and the pill's fills are translucent materials
(`ChromeMaterials.Dark.fillChrome` at α 0.44 resting, `fillThick` at α 0.52
focused). Is the segment text legible over what those fills composite to on
realistic content, and does the attention dot stay distinguishable on both? —
`pane-glass-legibility`'s grading, applied to the pill.

## Method

**The harness is `cluster-wires`'.** The shipped view, compiled verbatim with
the packages it links, hand-fed the four-segment fixture (`main`, `↑1*?3`,
`working`, the dot) and rendered offscreen. The pill's fill is plain translucent
`NSColor` paint, not an `NSGlassEffectView`, so the offscreen render is the full
drawing route — nothing a compositor would add is missing. That is also why,
unlike every number in `pane-glass-legibility`'s README, the numbers below are
deterministic: no tone response, no wallpaper, no within-run caveat. They are
pinned exact and a changed byte is a changed feature.

**The grading is `pane-glass-legibility`'s.** Segment ink is graded against
WCAG AA's 4.5:1 — that probe's `FLOOR`, read here off the package as
`PaneTheme.minimumTextContrast` rather than transcribed. Ink is sampled as the
brightest pixel in a glyph band (the fully-covered glyph core; antialiased edges
lose by construction) and the fill from a band containing no ink — the
ink-contamination lesson, inherited, and applied once in each direction: the
fill is sampled at the gap between the first two segments, and the glyph band is
clamped to the middle 40% of the pill's height so the focused arm's 2 pt
`inkFocus` stroke cannot pose as glyph ink.

**The compositing is `glass-backdrop`'s `flatten(rgba:over:)`**, reused as the
package's own copy, `RGBA.composited(over:)` (ChromeMaterials.swift): per
channel, `out = rgb·α + backdrop·(1−α)`. The backdrop is the dark theme document
colour, `PaneTheme.darkPastel.background` `#141414` — the realistic content
behind the pill. The arithmetic is not trusted blind: each arm renders the
capsule over an opaque `#141414` backdrop view and asserts the *measured* fill
band equals the flatten's prediction within ±1 byte per channel, so the formula
and AppKit's actual compositing are held to agree on every run (they differ by
sub-byte rounding: predicted `#131416`, measured `#141415`).

**The dot's floor is this probe's own, documented.** `pane-glass-legibility`
grades text only and carries no non-text method, so the dot arm grades the
contrast of the dot's drawn colour against the composited fill, against the 3:1
of WCAG 1.4.11 (non-text contrast). The dot's centre pixel is asserted to be
`attentionColour(.alert, behavior: .stock)` before it is graded, so the arm
grades the accent as drawn, not a constant.

## What would be false if this passed and the code were wrong

- **If the view stopped painting the fill**, the band would read bare `#141414`
  and the flatten cross-check fails — on the blue channel, by 2 bytes against
  the predicted `#131416`'s ±1. The margin is thin because the composite sits
  only ~2 bytes off the document colour; the ±1 tolerance is load-bearing, and
  widening it to ±2 would let a missing fill pass. (`cluster-wires`' opacity arm
  covers the same seam from the other side: the fill exists and its dial moves
  it.)
- **If the sampling read the wrong pixels** — ink band and fill band
  accidentally the same region, or the glyph search landing on fill — the arm
  itself would read ~1:1 and fail; a pass means the ink sample found something
  bright over the band. The printed ink is `#bbbbbb` exactly, the theme
  foreground: the glyph core, not an edge and not the stroke.
- **If the grade were vacuous** — wrong pair, wrong formula, floor read from
  nowhere — the inverted controls catch it: each arm re-runs with the graded
  ink (`theme.foreground` for the text arms, `ansi[1]`, the attention colour's
  source, for the dot arm) deliberately set to the composited fill colour, and
  must fail its floor. The control runs the whole pipeline (theme, render,
  sampling, contrast), so it also proves the render honours the theme it is
  handed.
- **If a constant were transcribed wrong**, nothing moves: the materials, the
  theme, the text floor and the accent are all read off the linked packages at
  run time. The only literal is the dot's 3.0, which no package constant
  carries; it is cited above.

## Findings

Run of record: 2026-08-12. Deterministic (see Method), so these are pins, not
within-run observations; `run.sh` re-derives every one on every run.

| arm | fill (measured, over `#141414`) | ink (measured) | contrast | floor | headroom |
|---|---|---|---|---|---|
| resting (`fillChrome`) | `#141415` | `#bbbbbb` | **9.62:1** | 4.5:1 | 5.12 |
| focused (`fillThick`) | `#151718` | `#bbbbbb` | **9.38:1** | 4.5:1 | 4.88 |
| dot over `fillChrome` | `#141415` | `#ff5555` | **5.86:1** | 3.0:1 | 2.86 |
| dot over `fillThick` | `#151718` | `#ff5555` | **5.72:1** | 3.0:1 | 2.72 |

All three text segments grade identically (9.62:1 resting, 9.38:1 focused): the
ink reads back `#bbbbbb` on every segment, so the worst case and the best case
are the same pixel value. The controls read 1.00:1, 1.00:1 and 1.00–1.01:1.

**Why the ratios sit so close to `#bbbbbb`-on-`#141414`'s 9.60:1** (the
arithmetic `pane-glass-legibility`'s α = 1.0 row pins): the fills are dark paint
at moderate alpha over a dark document, so the composite lands within 4 bytes of
the document colour. The pill, over the dark theme, costs the text almost
nothing.

### The bound this probe does not measure

Over glass chrome the surface behind the pill is not bare `#141414`: it is the
pane wash over live glass, and on a bright day that is brighter.
`pane-glass-legibility`'s finding 3 bounds the washed pane at
`band(0.5) = 0.5·20 + 0.5·124 ≈ #484848` against the brightest glass ever
measured in this repo (glass-backdrop 6b's `#7c7c7c`). Running this probe's own
flatten over that bound: `fillChrome` composites to ≈`#303133`, the ink to
≈6.8:1 and the dot to ≈4.1:1 — derived arithmetic, not a measurement, but both
still clear their floors with the headroom above absorbing the swing. A live
capture of the pill over real glass belongs to a `pane-glass-legibility`-shaped
windowed probe, not this one.

## Files

```
run.sh           builds the packages (via lib/build-packages.sh), compiles the
                 shipped view files verbatim, runs each arm and its control
legibility.swift the probe: fixtures, offscreen render over an opaque backdrop,
                 sampling, grading, and the inverted controls
```

Nothing is written into the repo; the binary and libraries land under
`$TMPDIR/baia-cluster-legibility-probe`.
