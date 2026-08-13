# Capsule legibility

`./run.sh` from anywhere. Five arms — resting, focused, dot, offer-glass,
offer-flat — each over two backdrops, each followed by its inverted control;
exits non-zero if any arm misses its floor, if any control loses its teeth, or
if the measured fill band stops matching the composite prediction. Needs only
`swiftc`; no app build, no capture, no `python3`.

**This probe graded one pill until 2026-08-12 and now grades two.** The owner's
tinted-glass ruling that day gave the sidebar's floating `git init` offer a real
`NSGlassEffectView`, which put a second translucent pill over content it is not
about — the same question this probe was built for, so it is asked here rather
than in a probe of its own. The offer arms are documented in their own section
below; everything above it is the capsule's and unchanged.

**Safe from anywhere, including inside a baia pane.** The probe opens no window,
takes no focus, launches nothing and quits nothing: every arm renders the
shipped `PaneClusterView` offscreen through `cacheDisplay(in:to:)` and reads the
bytes back, the `cluster-wires` arrangement. TODO: SAFE_PROBES membership — the
probe qualifies on `override-wires`' ground (nothing here ever reaches a
compositor), and adding it to `guard-baia-alive.sh`'s list is the coordinator's
call, not this task's.

## The question

The pane cluster moves the footer's facts onto a pill floating over the
terminal. Since 2026-08-12 (the owner's read-through ruling) the pill paints
two layers under glass: a backing — `theme.background` at
`ChromeMaterials.PaneWash.floor`, 0.5 — so what is beneath the pill never
reads through into the segment ink, then the translucent material fill
(`ChromeMaterials.Dark.fillChrome` at α 0.44 resting, `fillThick` at α 0.52
focused). Is the segment text legible over what that stack composites to, on
dark content and on the brightest backdrop this repo has measured, and does the
attention dot stay distinguishable throughout? — `pane-glass-legibility`'s
grading, applied to the pill.

## Method

**The harness is `cluster-wires`'.** The shipped view, compiled verbatim with
the packages it links, hand-fed the four-segment fixture (`main`, `↑1*?3`,
`working`, the dot) and rendered offscreen. The pill's layers are plain
translucent `NSColor` paint, not an `NSGlassEffectView`, so the offscreen
render is the full drawing route — nothing a compositor would add is missing.
That is also why, unlike every number in `pane-glass-legibility`'s README, the
numbers below are deterministic: no tone response, no wallpaper, no within-run
caveat. They are pinned exact and a changed byte is a changed feature.

**The grading is `pane-glass-legibility`'s.** Segment ink is graded against
WCAG AA's 4.5:1 — that probe's `FLOOR`, read here off the package as
`PaneTheme.minimumTextContrast` rather than transcribed. Ink is sampled as the
brightest pixel in a glyph band (the fully-covered glyph core; antialiased edges
lose by construction) and the fill from a band containing no ink — the
ink-contamination lesson, inherited, and applied once in each direction: the
fill is sampled at the gap between the first two segments, and the glyph band is
clamped to the middle 40% of the pill's height so the focused arm's 2 pt
`inkFocus` stroke cannot pose as glyph ink.

**Two backdrops per arm.** The dark theme document colour,
`PaneTheme.darkPastel.background` `#141414` — the realistic content behind the
pill — and the bright bound `#7c7c7c`, glass-backdrop finding 6b's brightest
measured backdrop, standing in for the prompt text and bright content the
backing exists to survive. The bright case was derived arithmetic in this
README before the backing; the backing is plain paint in the same `draw(_:)`,
so it became renderable offscreen and is measured. The bright arm is also what
lets the composite cross-check see the backing at all: over the document
colour the backing composites to exactly the document colour (background over
background) and its absence would be invisible there.

**The composite cross-check predicts through AppKit's own blend.** Each arm
renders the capsule over an opaque backdrop view and asserts the *measured*
fill band equals the predicted two-layer composite — backing onto backdrop,
fill onto backing — within ±1 byte per channel, so the layer stack and
AppKit's actual compositing are held to agree on every run. The per-channel
arithmetic is `NSColor.blended(withFraction:of:)`, because the rep
`bitmapImageRepForCachingDisplay(in:)` hands back is Generic RGB (gamma 1.8)
and AppKit blends in the rep's space, which `NSColor`'s calibrated blend
reproduces to sub-byte on both backdrops. The package's sRGB flatten,
`RGBA.composited(over:)` (glass-backdrop's `flatten(rgba:over:)`), is the same
stack in sRGB bytes: exact to sub-byte in the dark regime — where every
pre-2026-08-12 pin lived, which is why the space question never surfaced — and
~6 bytes dark of the measurement at the bright bound. The stack is cited
either way; only the blend curve is AppKit's.

**The dot's floor is this probe's own, documented.** `pane-glass-legibility`
grades text only and carries no non-text method, so the dot arm grades the
contrast of the dot's drawn colour against the composited fill, against the 3:1
of WCAG 1.4.11 (non-text contrast). The dot's centre pixel is asserted to be
`attentionColour(.alert, behavior: .stock)` before it is graded, so the arm
grades the accent as drawn, not a constant.

## What would be false if this passed and the code were wrong

- **If the view stopped painting the material fill**, the document-colour band
  would read the bare backing composite `#141414` and the cross-check fails —
  on the blue channel, by 2 bytes against the predicted `#131416`'s ±1. The
  margin is thin because the composite sits only ~2 bytes off the document
  colour; the ±1 tolerance is load-bearing, and widening it to ±2 would let a
  missing fill pass. (`cluster-wires`' opacity arm covers the same seam from
  the other side: the fill exists and its dial moves it.)
- **If the view stopped painting the backing**, the bright-bound band would
  read the fill over bare `#7c7c7c`, ≈`#535355` — ~29 bytes off the predicted
  `#363638` — and the cross-check fails on every channel. This is the arm the
  backing's existence lives or dies by; the document-colour arm cannot see it
  (background over background moves nothing).
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
  theme, the wash floor, the text floor and the accent are all read off the
  linked packages at run time. The only literal beyond the backdrops is the
  dot's 3.0, which no package constant carries; it is cited above.

## Findings

Run of record: 2026-08-12, the day the backing landed. Deterministic (see
Method), so these are pins, not within-run observations; `run.sh` re-derives
every one on every run.

| arm | backdrop | fill band (measured) | ink (measured) | contrast | floor | headroom |
|---|---|---|---|---|---|---|
| resting (`fillChrome`) | `#141414` | `#141415` | `#bbbbbb` | **9.62:1** | 4.5:1 | 5.12 |
| resting (`fillChrome`) | `#7c7c7c` | `#363638` | `#bbbbbb` | **6.26:1** | 4.5:1 | 1.76 |
| focused (`fillThick`) | `#141414` | `#151718` | `#bbbbbb` | **9.38:1** | 4.5:1 | 4.88 |
| focused (`fillThick`) | `#7c7c7c` | `#323435` | `#bbbbbb` | **6.53:1** | 4.5:1 | 2.03 |
| dot over `fillChrome` | `#141414` | `#141415` | `#ff5555` | **5.86:1** | 3.0:1 | 2.86 |
| dot over `fillChrome` | `#7c7c7c` | `#363638` | `#ff5555` | **3.82:1** | 3.0:1 | 0.82 |
| dot over `fillThick` | `#141414` | `#151718` | `#ff5555` | **5.72:1** | 3.0:1 | 2.72 |
| dot over `fillThick` | `#7c7c7c` | `#323435` | `#ff5555` | **3.98:1** | 3.0:1 | 0.98 |

All three text segments grade identically on every row: the ink reads back
`#bbbbbb` on every segment, so the worst case and the best case are the same
pixel value. The controls read 1.00–1.01:1 on every row.

**The dark rows barely moved when the backing landed**, and that is the
geometry, not luck: the backing is the document colour at 0.5 over the document
colour, an identity, so the pre-backing pins (9.62, 9.38, 5.86, 5.72) carried
over unchanged. **The bright rows are what the backing bought.** The old README
derived ~6.8:1 ink and ~4.1:1 dot at this bound from sRGB arithmetic; the
measured calibrated composite lands a little brighter (`#363638` vs the derived
`#303133`), so the honest numbers are 6.26:1 and 3.82:1 — both clear of their
floors, where the un-backed pill's fill alone would have left the band at
≈`#535355` and the dot at ~2.4:1, under its floor. The thinnest margin in the
table (0.82, the resting dot at the bright bound) is the number to watch if the
wash floor or the accent ever moves. `fillThick` reads *better* than
`fillChrome` over the bright bound — more dark paint is more help when the
backdrop is the problem.

### The bound this probe still does not measure

Live glass. The bright bound is an opaque stand-in for the backing-plus-glass
worst case; a real `NSGlassEffectView` adds the compositor's vibrancy and
adaptation, which glass-backdrop measured as helping ink, not hurting it. A
live capture of the pill over real glass belongs to a
`pane-glass-legibility`-shaped windowed probe, not this one.

## The offer arms

The sidebar's floating `git init` pill (`InitOfferView`), added 2026-08-12 with
the owner's tinted-glass ruling. Same grading, same floor, same two backdrops;
what differs is the view, its layer stack, and the shape of its control.

### What the glass contributes offscreen: nothing, and it is measured

`NSGlassEffectView` is composited by the window server. Through
`cacheDisplay(in:to:)` there is no compositor in the path, and the view lays
down **zero pixels**: a bare glass view over `#7c7c7c` reads back `#7c7c7c` at
every sample, checked directly before these arms were written.

That is what makes the glass arm possible rather than impossible, and it fixes
what it means. The arm grades the caption over **the pill's own paint with the
material counted as fully transparent** — a lower bound on the live pill, not a
model of it. `glass-backdrop` has the material adding its own dark paint and
adapting to what it samples, so every byte the compositor contributes moves the
band away from the caption, never toward it. **A pass here is a pass live.** The
flat arm needs no such caveat: flat draws no glass at all, so the offscreen
render is the whole drawing route, exactly as the capsule's arms are.

### What the arms found, and what changed because of them

Run of record: 2026-08-12.

| arm | backdrop | face (measured) | ink (measured) | contrast | floor | headroom |
|---|---|---|---|---|---|---|
| offer (glass) | `#141414` | `#141415` | `#bfbfbf` | **10.08:1** | 4.5:1 | 5.58 |
| offer (glass) | `#7c7c7c` | `#363638` | `#bfbfbf` | **6.56:1** | 4.5:1 | 2.06 |
| offer (flat) | `#141414` | `#141414` | `#9d9d9d` | **6.78:1** | 4.5:1 | 2.28 |
| offer (flat) | `#7c7c7c` | `#141414` | `#9d9d9d` | **6.78:1** | 4.5:1 | 2.28 |

The flat rows are identical across backdrops by construction: that pill is
opaque, so what is beneath it composites away entirely. Both rows are the
number the caption's tier was originally chosen at.

**Two things failed on the way to these numbers and both are the point of
running the arm.**

1. **The wash alone is not enough.** The pill's first glass draft laid down
   `PaneWash.floor` and left the rest to the material. That reads **3.11:1** at
   the bright bound, under the floor. The fix is the capsule's own stack, cited
   rather than invented: the wash *and then* `fillChrome` over it, 0.44 of
   vitreous dark paint. Raising the wash instead was rejected on the ruling —
   `PaneWash`'s doc names 0.8 as where the wash erases the glass, and a pill
   thick enough to carry the caption on paint alone is the painted rectangle
   the owner ruled against.

2. **A tier-4 ink fails on a translucent pill.** With both layers down,
   `inkContext` still read **4.41:1** at the bright bound. The pill did not have
   this problem while its fill was opaque. The fix is
   `PaneTheme.readable(_:on:minimumRatio:)` — the package's own repair chain,
   which every footer tier already goes through — graded against the worst face
   the pill can present. It fires only where a theme needs it; the flat arm
   shows it returning `inkContext` untouched.

### The space divergence, and the first draw path caught by it

`InitOfferView.worstFace` grades on the package's sRGB flatten **lifted by six
bytes**, and this section is why. AppKit composites in the bitmap rep's space
(Generic RGB, gamma 1.8); the package flattens in sRGB bytes. The two agree to
sub-byte in the dark regime — where every pin in this app lived until the
bright bound joined — and diverge at the bright end: the flatten predicts
`#303132` where this probe measures `#363638`, 4.79:1 against 4.41:1. Graded on
the flatten alone the repair chain does not fire and the caption ships under
the floor on a face the app can put on screen. The correction is toward the
measurement and only ever makes the grade stricter.

### The offer arms' controls are a different shape, deliberately

Every other arm here draws in a colour the theme states, so setting that colour
to the fill is a caption the eye cannot find. **The offer's caption is repaired**,
and `readable`'s last resort is the best of foreground, white and black — so no
theme colour handed to it survives as an unreadable one. Both damage routes were
tried (`foreground` alone, then `foreground` and `background` collapsed together)
and the arm passed at 6.07:1 each time, because the repair worked. A control that
cannot fail is not a control.

So these two controls damage the drawn **pixel** rather than the theme entry
behind it: the grade runs on a caption the colour of its own pill, which no
repair can rescue because the repair is upstream of it. Everything under it —
theme, render, sampling, band — is the arm's own, so a probe reading the wrong
pixels still fails here. Both controls read 1.00:1.

## Files

```
run.sh           builds the packages (via lib/build-packages.sh), compiles the
                 shipped view files verbatim, runs each arm and its control
legibility.swift the probe: fixtures, offscreen render over an opaque backdrop,
                 sampling, grading, and the inverted controls
```

The offer arms add `FilesSurface.swift`, `WorkspaceSurface.swift`,
`SidebarRowMetrics.swift`, `SurfaceFill.swift`, `RowFeedback.swift` and
`DividerGrabView.swift` to that compile line, the set `clip-layout` already
compiles for the same surface, plus `SurfaceFill` for the glass backing's tint.

Nothing is written into the repo; the binary and libraries land under
`$TMPDIR/baia-cluster-legibility-probe`.
