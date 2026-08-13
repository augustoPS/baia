# Glass backdrop probe

`./run.sh [output-directory]` from anywhere. Writes fourteen captures, a `-screen.png`
companion for each, and a grid measurement; exits non-zero if a capture fails, if a
material never samples its backdrop, or if a grid arm misses its number.

## Still live after the footer's deletion

**The bar this probe grades was deleted on 2026-08-13, and the probe still
runs and still answers something.** Read every "the shipped footer" below as the
footer that shipped until that date: the tint and backdrop findings are a record
of what was measured, not a description of what draws now.

What is not historical is the arithmetic. The arms chose arrangement (B), which
shipped as `PaneChromeMetrics.glassWindowPaddingBump`, and `gridtest.swift`
still measures that compensation against a real PTY on every run — arm D there
is what keeps the naive `+height` version from looking correct. That constant
outlived the bar because a surface extended under chrome is the arrangement
design v6 is still choosing between; if that question closes the other way, this
probe's grid arm goes with it.

The geometry arms read `PaneChromeMetrics` at run time rather than transcribing
it, which is why the deletion did not strand them: the type keeps the bar's
numbers as a measured record.

## The question

Design v5 Plans 2-3 shipped Liquid Glass chrome (`NSGlassEffectView`) that
renders and was believed not to lens. The research report
(`vault/projects/baia/liquid-glass-research.md` §6) names two causes and the
shipped footer commits both at once: the backing carries a vitreous tint fill
(§6.4, the colored-slab failure) *and* the bar sits beside the terminal surface
with nothing behind it to refract (§6.2, the empty-backdrop failure). Two failures
stacked means fixing either alone proves nothing, which is why the arms below vary
tint and backdrop independently rather than together.

Two candidate resolutions were on the table, and this probe exists to choose
between them before any app code moves:

- **(A)** the bar's backdrop is the desktop through the transparent window region.
  The window is already non-opaque and the wells run at 0.42. No layout change.
- **(B)** the terminal surface view extends under the bar, so glass samples live
  well pixels, with the grid keeping its inset via ghostty padding.

(B) is the research report's preferred arrangement. (A) costs nothing. The
report could not say which reads better over a 22 pt strip, because that is a
question about pixels.

## What would be false if this probe passed and the code were wrong

That a 22 pt `NSGlassEffectView` over a terminal pane adapts to what is behind it
at all, and that "extend the content under the bar" can be done without taking a
row off the grid. A probe that only screenshotted the bars would answer neither:
the first needs the same bar captured over two known backdrops and the pixels
compared, and the second needs a real PTY, because a stand-in view has no shell to
send `SIGWINCH` to.

## The arms

Four renderings of the same 22 pt bar on the same pane-shaped window: a surface
stand-in at the shipped 0.42 well opacity over a non-opaque window.

| Arm | Bar | Backdrop |
|---|---|---|
| 1 `arm-1-shipped-tinted` | drawn `fillChrome` fill (α 0.44) + `NSGlassEffectView` above it, `tintColor` = `MaterialSet.dark.fillChrome`, content a sibling above the glass — the shipped hierarchy, **unfocused** | beside the surface (transparent window region) |
| 2 `arm-2-untinted-beside` | `NSGlassEffectView`, no tint, no fill, content as `contentView` | beside the surface — this is **(A)** |
| 3 `arm-3-untinted-over-surface` | `NSGlassEffectView`, no tint, no fill, content as `contentView` | over the surface's bottom 22 pt — this is **(B)** |
| 4 `arm-4-nsvisualeffect-control` | `NSVisualEffectView`, `.underWindowBackground` | beside the surface |

Arm 4 is not a candidate. It is the control that says how much of any difference
between the others is glass rather than blur.

Arm 1 modelled what shipped at the time and arms 2-3 the candidates, and they are
built differently on purpose. Arm 1 reproduces `PaneStatusBarView`'s hierarchy including
the drawn fill and the sibling-above-glass content placement; arms 2-3 use
`contentView`, which is what the research report says the adopted arrangement
should use. Grading the shipped bar through `contentView` would have measured
AppKit legibility treatments the shipped path never receives.

The values are read off `PaneChrome` at run time (`PaneChromeMetrics.paneBarHeight`,
`MaterialSet.dark.fillChrome`) rather than transcribed, so the arm claiming to
reproduce the shipped footer cannot grade against numbers that have moved.

### The controlled backdrop

A full-screen window of pure white beside pure black is ordered below the probe
window, and the pane is centred on the **vertical seam** where the two halves
meet, so every capture carries the bright half on the left and the dark half on
the right in one frame. The desktop cannot be the backdrop: glass adapts to what
is behind it, so an arm graded against the owner's wallpaper is different on every
machine and different again next week.

### How the captures are read, and why it takes two of them

Each window is photographed twice: `screencapture -l <windowid>` as
`<name>.png`, and `screencapture -R <rect>` over the same frame as
`<name>-screen.png`. Neither route alone is trustworthy, and the first version of
this probe used only `-l` and published a wrong arm-3 number because of it.

- **`-l` returns the window's own backing store**, alpha intact, before the window
  server composited anything under it. These windows are `isOpaque = false` over a
  0.42 well, so the surface band came back `(19, 19, 24, α=107)` on *both* halves
  of the backdrop: the unpremultiplied theme colour at the well's own alpha,
  carrying no trace of what it sits over. Anything read *through* the well was the
  stand-in's paint rather than a composite.
- **`-R` composites correctly but applies the display's brightness and EDR tone
  response.** Measured here at one instant, over the same borderless full-screen
  window painted pure `NSColor.white` beside pure `NSColor.black`:

  ```
  -l   white half #ffffff   black half #000000
  -R   white half #373737   black half #111111
  ```

  `-R` crushes pure white to 21% luminance. Absolute numbers off an `-R` file move
  with the brightness slider and are not reproducible tomorrow or on another
  machine.

So the two routes are used for different things, and which one a given material
must be read through is not a choice:

| Material | Read through | Why |
|---|---|---|
| `NSGlassEffectView` (arms 1-3, both capsule windows) | `-l`, well flattened in analysis | Glass composites its sampled backdrop into its *own* window's buffer, so `-l` sees the adaptation. The 0.42 well is flattened against the backdrop this probe controls and therefore knows exactly. |
| `NSVisualEffectView` `.behindWindow` (arm 4), and the sidebar's glass | `-R` | These composite at the *window-server* level. Their `-l` files are flat slabs however long the probe waits — both sat out six escalating settles unchanged — and only the screen grab carries their adaptation. |

The flatten is validated against the review's own arithmetic: the old `-l` surface
band `(19,19,24,α=107)` flattens to `#9c9c9e` over white and `#08080a` over black,
matching the predicted `≈#9b9c9e` / `≈#08080a`. The `-l`-versus-`-R` cross-check
agrees on hue and on ordering (brighter over the white half) for all four arms;
they disagree on magnitude only, in the direction `-R`'s tone curve predicts.

Because a flat slab and a sampled gradient are tens of units apart, the probe now
*verifies* sampling before accepting a capture rather than trusting a fixed
`settle()`: `recordSampled` re-settles and re-captures until the two sides of the
seam differ. That check is what caught the sidebar arm.

## Findings

All numbers below are measured with `Diagnostics/lib/pixel.py` over the capture
files this probe writes, read through the route named in the table above.

**Sample region: x 0.10-0.30 over the white half, x 0.72-0.92 over the black half,
both at y 0.980-0.997.** Every part of that band is load-bearing:

- **The y band must miss the bar's own text.** The bar draws its ink at
  `#ebebeb`, and the glyph rows sit at roughly y 0.951-0.977. An earlier band of
  y 0.96-0.99 ran straight through them, so the "fill" it averaged was part ink —
  and the contrast figure then compared `#ebebeb` against a region containing
  `#ebebeb`, which inflates it. y 0.980-0.997 is below the glyphs and inside the
  bar: for a 22 pt bar on a 320 pt window at 2x it is rows 31-42 of the bar's 44,
  in **both** capture routes.
- **The band is quoted as a fraction because the two routes differ in height.**
  `-l` sizes its output to the window's *rendered* bounds, which include each
  window's own overdraw: arm 1 and both capsule windows come back 642 px tall
  from the same 320 pt frame where arms 2-4 come back 640. The bar is
  bottom-anchored and both routes end at the same bottom fraction, so the *same*
  y-fractions land on the same rows of the bar in every file. Absolute pixel rows
  do not transfer between files; fractions do.

**Arm 1 is the bar as it then shipped, in all three of its layers**, which the
first version of this probe did not reproduce and which changes the headline
result. `PaneStatusBarView` filled the whole bar with `effectiveFillMaterial`
(`fillChrome`, `rgb(18,20,24)` at α 0.44) in `draw(_:)`, put `glassBacking` above
that as a subview, and drew its segments as siblings *above* the glass. The first version modelled only the tint,
skipped the 0.44 fill, and assigned the label as the glass's `contentView` (which
invites AppKit legibility treatments the shipped path never gets). Arms 2-3 keep
`contentView` deliberately: they model the *future* arrangement the research report
asks for. **Arm 1 is the unfocused bar**; `effectiveFillMaterial` steps to
`fillThick` (α 0.52 over `rgb(22,24,28)`) when the pane is focused, and that state
is not captured.

### 1. Glass adapts. The empty backdrop was not the failure — but the shipped bar's own fill damps it hard.

| Arm | bar over white | bar over black | luminance spread |
|---|---|---|---|
| 1 shipped tinted (faithful) | `#3a3d40` | `#313437` | **3.1** |
| 2 untinted beside | `#a6a6a6` | `#141414` | 95.5 |
| 3 untinted over surface | `#3a3a3f` | `#27272e` | 5.6 |
| 4 `NSVisualEffectView` | *see note* | *see note* | *see note* |

**Arm 4's absolutes are deliberately not quoted.** It is the one arm readable only
through `-R`, and `-R` carries the display's brightness and EDR response at capture
time — which moves between runs, not just between machines. Two runs minutes apart
measured its bright half at `#545555` and `#333434`, a 6.27:1 versus 10.48:1 swing
from the same code against the same backdrop. Its *role* survives that (finding 4
compares it to arm 3 within a single capture, where the tone curve cancels); its
absolute numbers do not belong in a table a reader is invited to reproduce. Re-run
the probe and read arm 4 against arm 3 in the same run.

Arm 2 — a bare untinted `NSGlassEffectView` over the transparent window region —
tracks its backdrop across a 117-unit luminance range. §6.2's empty-backdrop
diagnosis does not hold for this material: there *is* a backdrop, and it is the
desktop.

**Arm 1's range is 3.1, not the 160 first reported.** The correction is the 0.44
`fillChrome` pass the first version omitted. That fill is opaque enough to
dominate what the glass above it can contribute, so the shipped bar is very nearly
a *fixed* slab: it moves ~3 units between a white and a black desktop. Whatever
else is true of the shipped footer, it does not track the desktop.

### 2. The tint is NOT inert. It is the single largest term in the bar's appearance.

Arm 1 minus arm 2, sampled at six x-positions across the bar:

```
     x      arm1      arm2   delta(R,G,B)
  0.05   #383b3e   #a8a8a8   [-112, -109, -106]
   0.2   #3a3c3f   #a6a6a6   [-108, -106, -103]
  0.35   #36393b   #a1a1a2   [-107, -104, -103]
   0.5   #313437   #4d4d4d   [ -28,  -25,  -22]
  0.65   #313437   #141414   [  29,   32,   35]
   0.8   #313437   #141414   [  29,   32,   35]
```

**This overturns the previous finding.** The old table reported a uniform +9..+11
lift and concluded the tint was "achromatic and nearly inert". Measured against a
faithful arm 1, the delta is **-112 to +35** depending on the backdrop: the shipped
treatment *darkens* the bar by up to 112/255 over a bright desktop and *lightens* it
by ~32/255 over a dark one. It is not a tidy-up. It is the mechanism that pins the
bar near mid-grey regardless of what is behind it.

The delta is still **achromatic** — the three channels move within a few units of
each other, because `fillChrome` is `rgb(18,20,24)`, a near-neutral. Ghostty's
red-cast reports (#11805) came from tinting toward a *saturated* theme background;
baia's chrome fill is grey, so no hue is introduced. That part of the old finding
survives.

But the magnitude claim does not. **Plan 4's untinting is not a ~10/255
cosmetic shift. Removing the drawn fill and the tint is what moves arm 1 to arm 2,
which is a 92-unit swing in adaptation range and — see finding 3 — the difference
between a bar that clears WCAG AA over a bright desktop and one that does not.**

### 3. The shipped bar clears 4.5:1 over a bright desktop. Untinting it is what breaks that.

Contrast of the bar's text ink (`#ebebeb`) against the bar fill beneath it:

| Arm | over white | over black |
|---|---|---|
| 1 shipped tinted (faithful) | **9.17:1** | 10.50:1 |
| 2 untinted beside | **2.04:1** | 15.45:1 |
| 3 untinted over surface | **9.49:1** | 12.44:1 |
| 4 `NSVisualEffectView` | *see note* | *see note* |

**This inverts the spike's central claim.** The old table put arm 1 at 1.54:1 and
called the shipped bar a real, unreadable, already-shipping bug. It is not: the
faithful arm 1 measures **9.17:1** over a pure-white backdrop, comfortably clear of
WCAG AA's 4.5:1 body-text floor. The 1.54:1 figure was an artifact of modelling the
shipped bar without its own 0.44 fill.

What the number now says is the reverse. The shipped bar is legible over a bright
desktop *because of* the fill-plus-tint stack the plan proposes to remove. Arm 2 —
resolution (A), the tint off with no other change — falls to **2.04:1**. That is
the arrangement that would ship a legibility regression, and it would be introduced
by Plan 4, not fixed by it.

Arm 3 (resolution **(B)**) holds **9.49:1** over white and 12.44:1 over black by
putting the 0.42 well between the glass and the desktop. It clears the AA floor
with room to spare, and it is marginally *better* than what ships today.

### 3b. What arm 3 actually puts under the glass

Measured on the surface band above the bar in the arm-3 capture, flattened over the
controlled backdrop:

| Backdrop half | well colour | ink `#ebebeb` against the well |
|---|---|---|
| white | `#a3a4a5` | **2.09:1** |
| black | `#07080a` | 16.81:1 |

This is the number Task 2 needs and the one the first version could not produce
(under `-l` the well read as its own unflattened paint on both halves). **A 0.42
well over a white desktop is `#a3a4a5`, a light mid-grey.** Ink judged against the
well by Task 2's approximation therefore fails badly over a bright desktop — 2.09:1
— even though the *glass over that well* reaches 9.49:1. The glass is doing the
legibility work, not the well. Any Task 2 approximation that reasons about ink
against the well colour alone will be wrong over a bright desktop by more than a
factor of four.

### 4. Arm 3 is still glass, not blur.

Arm 4 is the control that makes arm 3's number mean something, and the comparison
that survives `-R`'s instability is the one made *within a single run*. In the run
these findings were written from, arm 3 reached `#27272e` over the black half
against `NSVisualEffectView`'s `#2d2d2d`: glass admits more of the backdrop, and it
carries a slight blue cast (`2e` blue against `27` red) where the control is flat
neutral (`2d/2d/2d`). Arm 3 is not merely arm 4 with extra steps.

That relationship — glass darker and faintly blue, blur flatter and neutral — held
across every run. The absolute pair did not. Compare the two arms inside one run's
output; do not carry either number between runs.

### 5. The capsule: glass-in-container and drawn-on-glass are indistinguishable here.

Capsule region against adjacent bar, measured as chroma (max channel minus min):

| Capture | capsule | chroma | adjacent bar | chroma |
|---|---|---|---|---|
| arm 1, drawn capsule | `#c4894b` | 121 | `#686a6c` | 4 |
| arm 3, drawn capsule | `#c3884b` | 120 | `#6a6b6f` | 5 |
| `capsule-container-beside`, glass capsule in container | `#d2975a` | 120 | `#b6b6b6` | 0 |
| `capsule-container-over-surface`, glass capsule in container | `#c78c4e` | 121 | `#6a6b6e` | 4 |

A tinted `NSGlassEffectView` capsule inside an `NSGlassEffectContainerView`
renders within 1-2 chroma units of a drawn capsule at every sample. The
container's managed merge does not dissolve the capsule into the bar
(`spacing = 0` keeps them as distinct shapes sharing one sampling pass), and it
does not make it more vivid either. This finding is unchanged by the capture fix:
it compares two capsules within the same capture, so the tone curve and the well
flatten cancel.

### 6. The sidebar adapts strongly and fails over the bright half.

`sidebar-untinted-glass-screen.png`: a 220 pt column of untinted `regular` glass
over the transparent window region, beside a pane at 0.42, now positioned so the
**column** straddles the seam rather than the window. The first version centred the
*window* on the seam, which left the entire 220 pt column over the dark half at a
uniform `#141414` — the one measurement the sidebar question could not use.

Measured across the column (seam at x-fraction 0.120, column ends at 0.239):

| Sample | x | glass (one run) | glass (another run) |
|---|---|---|---|
| bright half | 0.03 | `#4b4b4b` | `#474747` |
| bright half | 0.08 | `#494949` | `#464646` |
| dark half | 0.16 | `#2f2f2f` | `#2a2a2a` |
| dark half | 0.22 | `#2e2e2e` | `#292929` |

Contrast of the sidebar's own ink against that glass, both runs:

| Half | file rows `#e6e6e6` | CHANGED header `#9e9e9e` |
|---|---|---|
| bright | 6.99:1 / 7.44:1 | **3.26:1 / 3.47:1** |
| dark | 10.57:1 / 11.50:1 | 4.93:1 / 5.36:1 |

Two runs are shown because the sidebar, like arm 4, is readable only through `-R`
and therefore carries the display's brightness response at capture time. The
absolutes move a few units between runs; **the conclusion does not**, which is why
it is safe to draw one:

The file rows hold comfortably on both halves in both runs. **The CHANGED header
fails over the bright half — 3.26:1 and 3.47:1** — under the 4.5:1 body-text floor
though above the 3:1 large-text floor, and at 10 pt bold it is not large text. The
header needs roughly `#bbbbbb` or lighter to clear 4.5:1 against a bright-half glass
in this range.

#### 6a. Correction: the two runs above graded a stand-in, not the shipping ink.

Found 2026-08-07 while landing the repair. The arm drew its header with a
hard-coded `NSColor(white: 0.62)` (`#9e9e9e`) and the table above reports that as
"CHANGED header `#9e9e9e`". **The shipping header never drew `#9e9e9e`.** It draws
`theme.inkFaint`, which on `.darkPastel` derives to `#898989` — darker than the
stand-in, so the real ink was *worse* than the published number, not better. The
four render arms already read `PaneChromeMetrics.paneBarHeight` off the package at run
time for exactly this reason; the sidebar arm was transcribing instead, and now
reads `PaneChrome` too.

The finding's **verdict survives and is strengthened**: the header failed the floor
over the bright half, and by more than was reported. Only the absolute was wrong.

#### 6b. Re-run with the repair in, and why it reports no absolute pass.

The arm now draws two `CHANGED` strings side by side — the repaired
`theme.sectionHeaderInk(on:)` and the unrepaired `theme.inkFaint` as its control —
so one capture carries the bug and the fix and the comparison cannot drift between
runs.

Re-run 2026-08-07, `sidebar-untinted-glass-screen.png`, bright half:

| Ink | Value | Contrast this run |
|---|---|---|
| glass backdrop, bright half | `#7c7c7c` | — |
| `theme.inkFaint` (ships without the fix) | `#898989` | 1.19:1 |
| the old literal `#bbbbbb` | `#bbbbbb` | 2.17:1 |
| **`sectionHeaderInk`, repaired** | `#dcdcdc` | **3.04:1** |
| `sectionHeaderInk`, dark half | `#dcdcdc` | 12.95:1 |

**This run's display was far brighter than the two recorded above** — its bright
half read `#7c7c7c` where they read `#4b4b4b` and `#474747`, and the bare white
backdrop beside the column read `#7d7d7d`. That is the `-R` tone-curve caveat this
README already states, doing exactly what it warns about, so **these absolutes are
within-run only and are not comparable to the table above**.

What the re-run does establish, because all four values come from one capture at
one instant:

- The repair moves the header **2.55x** over the ink that ships without it
  (3.04:1 against 1.19:1) and beats the `#bbbbbb` literal it replaces (2.17:1).
- On the dark half it is comfortable at 12.95:1.
- **No fixed ink clears 4.5:1 on a bright half this bright** — `#ffffff` itself
  would reach only about 3.9:1 against `#7c7c7c`. The floor is not reachable by
  choosing an ink at this backdrop luminance.

So the ≥4.5:1 acceptance is met **against the backdrop the code grades on**
(`#4b4b4b`, finding 6's own worst measured sample: the repair returns `#dcdcdc` at
6.34:1, and 6.85:1 on the brightest sample, with 9.72–10.57:1 on the dark half) but
is **not** met against this brighter run's glass. Both facts are the record.

**What that leaves owed.** The grading constant in
`SurfaceTitleView.measuredBrightGlass` is finding 6's worst *measured* sample, and
this run shows the desktop can composite brighter than anything finding 6 saw. A
constant cannot track that. Closing it properly needs either a floor under the
sidebar wash (so the backdrop stops depending on the wallpaper) or a real sampled
backdrop, and neither is this task's to choose. Recorded here rather than resolved.

Re-run the probe before quoting a sidebar absolute; the bright-versus-dark ordering
and the ~2x ratio between the halves are what transfer.

## The grid measurement for arm 3

`gridtest.swift` spawns a real ghostty surface on a real PTY (`backend: .exec`)
and reads `terminalDidResize(columns:rows:)` — the same callback the app listens
on, and the signal the shell actually receives. Window 720x480 pt, bar 22 pt, base
`window-padding-y` 8.

```
A inset        surface  458 pt  padding-y  8  ->   82 cols x  23 rows
B extended     surface  480 pt  padding-y  8  ->   82 cols x  25 rows
C half-comp    surface  480 pt  padding-y 19  ->   82 cols x  23 rows
D naive-comp   surface  480 pt  padding-y 30  ->   82 cols x  22 rows
```

- **A** is the shipped arrangement.
- **B** is arm 3 with no compensation: **+2 rows**. This is the `SIGWINCH` the
  arm has to buy back, and it is real.
- **C** is arm 3 compensated: **0 rows delta**. Arm 3 is affordable.
- **D** is the negative control, and the reason it is here:

**`window-padding-y` is symmetric.** It applies to the top edge and the bottom
edge both, so raising it by `n` removes `2n` points of drawable height. A 22 pt
bar at one edge is bought back with **+11, not +22**. The naive arithmetic (D)
overshoots and costs a row, silently, on every pane. There is no bottom-only
padding key: `TerminalConfiguration.windowPaddingY(Int)` renders a single
`window-padding-y = n` line, and `Settings.windowPadding` is explicitly one value
for both axes.

**The residual cost is not zero.** Arm C spends 11 pt of padding at the *top* that
the shipped arrangement does not, so the first text row sits 11 pt lower. The row
*count* is preserved, which is what closes the `SIGWINCH` hazard
`PaneChromeMetrics` is built around; the top inset is a visual change for Task
2 to weigh, not a correctness problem.

## What "inactive" means here, honestly

This probe is `.accessory` and its windows are never key. That is the `SAFE_PROBES`
standard (`pane-resize`, `theme-refresh` meet it) and the only honest way to run a
probe that puts windows on screen while the owner is working: a focus steal
mid-capture would land keystrokes in whatever they were typing into.

The consequence is that the "inactive" pair measures nothing:

```
arm-2  bar@white  active #b6b6b6  inactive #b6b6b6  dLum +0.0
arm-2  bar@black  active #141414  inactive #141414  dLum +0.0
arm-3  bar@white  active #6a6b6f  inactive #6a6b6f  dLum +0.0
arm-3  bar@black  active #27272e  inactive #27272e  dLum +0.0
```

Zero delta on all four, because *every* capture in this probe is already of a
non-key window. `inactive-2-*.png` and `inactive-3-*.png` are kept as the
measurement that establishes this rather than being deleted, but they do not
answer the question they were commissioned for.

**The key-to-non-key transition is therefore unmeasured, and it is the one thing
Ghostty's discussion #10170 reports as jarring**: `NSGlassEffectView` drops its
tint and flattens when its window stops being key, and Ghostty shipped a manual
`isKeyWindow`-driven tint overlay to hide it. A probe that owns a key window is
needed to measure it, and it cannot run unattended while the owner is at the
machine. **Task 2 must not assume this is a non-issue.** Since the tint is coming
off anyway (finding 2), the specific thing Ghostty saw — a tint disappearing on
unfocus — may not apply here; what remains to check is whether untinted glass
also flattens.

## Verdict

### (A) or (B): **(B)**, and it clears WCAG AA on its own. The bug it was chosen to fix does not exist.

**Adopt (B): the terminal surface extends under the bar, with `window-padding-y`
raised by half the bar height (+11) to hold the grid. No legibility repair is
required to clear the floor.**

Two earlier conclusions are overturned, both by the faithful arm 1:

1. **The bar was not broken over a bright desktop.** It measured 9.17:1,
   comfortably clear of WCAG AA. The previous verdict called it "a real shipped
   bug" that "any owner with a light wallpaper cannot read"; that was an artifact
   of an arm 1 built without `PaneStatusBarView`'s own 0.44 `fillChrome` pass.
   Nothing needed rescuing, which is part of why deleting the bar in 2026-08
   cost no legibility that had to be rebuilt elsewhere.
2. **(A) is the regression, not the status quo.** Untinting the bar without
   changing its backdrop (arm 2) drops it to 2.04:1. Plan 4 as written would
   *introduce* the unreadable-over-bright-desktop bug the spike thought it was
   fixing.

So the question is not "which arrangement rescues a broken bar" but "which
arrangement preserves a working one while getting the HIG-correct untinted glass".
(B) is the answer and (A) is disqualified:

| | over white | verdict |
|---|---|---|
| shipped today (arm 1) | 9.17:1 | clears |
| (A) untinted beside (arm 2) | 2.04:1 | fails badly |
| (B) untinted over surface (arm 3) | **9.49:1** | clears, and marginally better than today |

**Does (B) clear 4.5:1? Yes, at 9.49:1 — roughly twice the floor**, and slightly
better than what ships. An earlier revision of this README reported 4.46:1 and
called (B) "0.04 short"; that figure came from a sample band that ran through the
bar's own `#ebebeb` glyph rows, so it compared the ink against a region containing
that same ink. The band now sits below the glyphs (see the sample-region note under
Findings) and the number roughly doubles for every arm.

The grid measurement says (B) is affordable: 0 rows delta at +11 padding, verified
against a real PTY, with the naive +22 shown to cost a row.

### The well-opacity sweep

The owner's chosen pairing for (B) is a well opacity above the shipped 0.42. Arm
3's arrangement rendered at five opacities, same bar, same untinted `regular` glass,
same sample discipline — only the stand-in's alpha differs between captures:

| well opacity | bar over white | ink contrast, bright half | bar over black | ink contrast, dark half | well over white |
|---|---|---|---|---|---|
| **0.42** (shipped) | `#3a3a3f` | **9.49:1** | `#27272e` | 12.44:1 | `#a3a4a5` |
| 0.46 | `#36393e` | 9.72:1 | `#25282e` | 12.39:1 | `#9b9c9d` |
| 0.50 | `#36383d` | 9.84:1 | `#25282e` | 12.39:1 | `#939395` |
| 0.55 | `#35373c` | 9.99:1 | `#26282d` | 12.37:1 | `#88898b` |
| 0.60 | `#34363a` | **10.15:1** | `#26282d` | 12.37:1 | `#7e7f81` |

**First value clearing 4.5:1: 0.42 — the shipped default already does.** First
clearing 4.7:1: **0.42** as well. Every opacity in the sweep clears both thresholds,
so no value on this curve can be justified *on legibility grounds*.

The curve is nearly flat: 0.42 to 0.60 buys **0.66 of contrast** (9.49 → 10.15),
about 7%, for a 43% increase in well opacity. That is the same fact finding 3b
states from the other direction — the glass is doing the legibility work, not the
well — and it means the opacity decision is an aesthetic one, not an accessibility
one.

**The cost the table does not carry.** Each step darkens the well over the desktop:
`#a3a4a5` at 0.42 through to `#7e7f81` at 0.60. The pane reads progressively less
like a window onto the wallpaper and more like an opaque panel, which is a move
away from the ghostty-parity look. That is the axis the choice actually turns on,
and the probe can only supply the other side of it. **The final default is the
owner's pick.**

**And a warning for Task 2's approximation.** Finding 3b measures the well itself
at `#a3a4a5` over a white desktop, where the ink scores 2.09:1. The glass over that
well reaches 9.49:1 — the glass is doing the legibility work, not the well. An
approximation that judges ink against the well colour will be wrong over a bright
desktop by more than a factor of four.

### The capsule: **drawn-on-glass**, on the current evidence.

Glass-in-container and drawn render within 1-2 chroma units of each other
(finding 5). Given that, prefer the drawn capsule: it was already what shipped,
it costs no second `NSGlassEffectView` and no container, and `PaneStatusBarView`'s
hit-testing refusals covered it. The capsule outlived that view — it draws on
`PaneClusterView` now — and this recommendation is why it is drawn rather than
glass-in-container there. The container arrangement buys
nothing measurable here.

**Named ambiguity, for a human eye.** The pixel means say the two are equivalent;
they cannot say whether the glass capsule has a specular rim or an edge treatment
that a region mean averages away, and rim highlights are exactly the kind of
narrow-band feature a mean over a 26x32 region hides. Compare by eye:

- `capsule-container-beside.png` against `arm-2-untinted-beside.png`
- `capsule-container-over-surface.png` against `arm-3-untinted-over-surface.png`

Look at the capsule's outline only. If the container version has a visible
specular edge the drawn one lacks, that is a reason to pay for the container that
these numbers cannot see, and it overrides the verdict above. If the outlines
match, the drawn capsule wins on cost.

### The sidebar: **still no restructure — but the header ink has to change.**

With the column straddling the seam (finding 6), the sidebar's own untinted
`regular` glass over the transparent window region carries the file rows fine on
both halves (6.99:1 bright, 10.57:1 dark). The
`NSSplitViewItemAccessoryViewController` restructure — with its session-restore and
focus-rule blast radius — is **not** justified by these numbers, and Tasks 2-6
should not take it.

What does fail is narrower than the restructure and is fixed far more cheaply.
**The CHANGED header reads 3.26:1 over the bright half**, under the 4.5:1 floor for
10 pt bold text. In the order the plan should try them:

1. **Lighten the header ink.** It draws `#9e9e9e` (`NSColor(white: 0.62)`) today;
   `#bbbbbb` or lighter clears 4.5:1 against the measured `#4b4b4b`. This is a
   single constant and it is the whole fix for the only thing that failed.

   **Landed 2026-08-07, and not as a constant.** See findings 6a and 6b. The
   `#9e9e9e` in this line is the stand-in the arm drew, not the shipping ink
   (`theme.inkFaint`, `#898989`). And `#bbbbbb` passes on `.darkPastel` for a
   reason that does not generalise — it *is* that theme's own `foreground` — so as
   a literal it says nothing about the other 484 themes in the catalog and
   inverts on a light one, where `#bbbbbb` is the near-invisible ink. It shipped
   as `PaneTheme.sectionHeaderInk(on:)` instead: the theme's own faint tier,
   repaired against the backdrop it is actually drawn on, which is the same
   `readable(_:on:minimumRatio:)` policy the rest of the chrome already uses.
2. **Whatever legibility repair the bar takes.** If the bar's remedy ends up being
   a darker well or a scrim, the same treatment applies behind the sidebar and
   moves both halves at once.
3. **The accessory-controller restructure.** Last resort, and nothing measured here
   asks for it.

The earlier caveat — that the sidebar capture sat entirely over the dark half and
so could not speak to bright desktops — is now discharged rather than carried
forward. It has been measured, and the answer is "one ink constant", not "a
restructure".

## Files

Captures land in the output directory (default
`$TMPDIR/baia-glass-backdrop`), which is outside the repo:

```
arm-1-shipped-tinted.png              arm 1
arm-2-untinted-beside.png             arm 2, resolution (A)
arm-3-untinted-over-surface.png       arm 3, resolution (B)
arm-4-nsvisualeffect-control.png      arm 4, the blur control
capsule-container-beside.png          glass capsule in a container, over (A)
capsule-container-over-surface.png    glass capsule in a container, over (B)
sidebar-untinted-glass.png            the sidebar question
sweep-well-0{42,46,50,55,60}.png      the well-opacity sweep for (B)
inactive-2-untinted-beside.png        see "what inactive means here"
inactive-3-untinted-over-surface.png  see "what inactive means here"
<name>-screen.png                     the `-R` screen-composite companion for each
                                      of the above; the ONLY route that sees arm 4
                                      and the sidebar (see "how the captures are read")
grid-measurement.txt                  the four grid arms
```

## Prior art that shaped this probe

Ghostty embeds the same engine, and PR
[#8801](https://github.com/ghostty-org/ghostty/pull/8801) plus discussions
[#9973](https://github.com/ghostty-org/ghostty/discussions/9973),
[#10170](https://github.com/ghostty-org/ghostty/discussions/10170) and
[#11805](https://github.com/ghostty-org/ghostty/discussions/11805) were read
before it was built. Three things changed the design:

1. **Ghostty never puts glass over the terminal surface.** They add it
   `positioned: .below, relativeTo: terminalView` and clear the renderer's
   background, so their glass samples the desktop and never in-window content.
   Arm 3 is therefore *unprecedented* rather than borrowed: no upstream result
   said whether glass samples a pane's pixels, which is why it had to be measured
   rather than assumed. It does.
2. **Their tint bugs are not reproducible here.** #11805's red cast came from
   tinting toward a saturated theme background; `fillChrome` is a near-neutral
   grey, which is why finding 2 measures an achromatic delta rather than a cast.
   The delta's *magnitude* is large (-80 to +35 depending on backdrop); its
   *hue* is nil, and it is the hue that #11805 was about.
3. **The unfocus flattening (#10170) is real and is OS behaviour**, and Ghostty
   shipped a manual `isKeyWindow` tint overlay to hide it. This probe cannot
   measure it (see "what inactive means here"), which is why that section warns
   Task 2 rather than staying silent.

Also honoured: the 26.2 regression in §6.8 — glass in borderless *non-movable*
transparent windows stops re-sampling as content moves beneath it (Apple forums
810314), with `isMovable = true` as the documented partial workaround. Every
window this probe opens sets it. Without that flag the probe would have measured
the bug rather than the material and reported "glass does not lens" for a reason
having nothing to do with the backdrop question.
