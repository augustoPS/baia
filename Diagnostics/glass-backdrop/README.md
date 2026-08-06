# Glass backdrop probe

`./run.sh [output-directory]` from anywhere. Writes nine captures and a grid
measurement; exits non-zero if a capture fails or a grid arm misses its number.

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
| 1 `arm-1-shipped-tinted` | `NSGlassEffectView`, `tintColor` = `MaterialSet.dark.fillChrome` | beside the surface (transparent window region) |
| 2 `arm-2-untinted-beside` | `NSGlassEffectView`, no tint | beside the surface — this is **(A)** |
| 3 `arm-3-untinted-over-surface` | `NSGlassEffectView`, no tint | over the surface's bottom 22 pt — this is **(B)** |
| 4 `arm-4-nsvisualeffect-control` | `NSVisualEffectView`, `.underWindowBackground` | beside the surface |

Arm 4 is not a candidate. It is the control that says how much of any difference
between the others is glass rather than blur.

The values are read off `PaneChrome` at run time (`PaneStatusBarMetrics.height`,
`MaterialSet.dark.fillChrome`) rather than transcribed, so the arm claiming to
reproduce the shipped footer cannot grade against numbers that have moved.

### The controlled backdrop

A full-screen window of pure white beside pure black is ordered below the probe
window, and the pane is centred on the seam so every capture carries both halves.
The desktop cannot be the backdrop: glass adapts to what is behind it, so an arm
graded against the owner's wallpaper is different on every machine and different
again next week.

## Findings

All numbers below are measured with `Diagnostics/lib/pixel.py` over the capture
files this probe writes. Sample regions: the bar over the white half is
x 0.10-0.30, over the black half x 0.72-0.92, both at y 0.96-0.99.

### 1. Glass does adapt. The empty backdrop was not the failure.

| Arm | bar over white | bar over black | luminance spread |
|---|---|---|---|
| 1 shipped tinted | `#bfbfbf` | `#1f1f1f` | 160.0 |
| 2 untinted beside | `#b6b6b6` | `#141414` | 162.0 |
| 3 untinted over surface | `#6a6b6f` | `#27272e` | 67.6 |
| 4 `NSVisualEffectView` | `#6d6d6e` | `#484849` | 37.0 |

Arms 1 and 2 track their backdrop across a 160-unit luminance range. Whatever
else is wrong with the shipped bar, it is sampling the desktop through the
transparent window region and responding to it strongly. §6.2's empty-backdrop
diagnosis does not hold for this bar: there *is* a backdrop, and it is the
desktop.

### 2. The tint is achromatic and nearly inert. The colored-slab diagnosis does not hold either.

Arm 1 minus arm 2, sampled at six x-positions across the bar:

```
     x      arm1      arm2   delta(R,G,B)
  0.05   #bebebf   #b6b5b6   [8, 9, 9]
   0.2   #bfbfbf   #b6b6b6   [9, 9, 9]
  0.35   #888888   #7f7f7f   [9, 9, 9]
   0.5   #4c4c4c   #414141   [11, 11, 11]
  0.65   #1f1f1f   #141414   [11, 11, 11]
   0.8   #1f1f1f   #141414   [11, 11, 11]
```

The tint's whole effect is a uniform +9 to +11 lift on all three channels. It is
**achromatic** — no hue is introduced, because `fillChrome` is `rgb(18,20,24)`,
a near-neutral, at 0.44. Ghostty's red-cast reports (discussion #11805) came from
tinting toward a *saturated* theme background; baia's chrome fill is grey, so the
same mechanism produces a slight darkening and no cast at all.

Removing the tint is still right — it is free, it is what the HIG asks for, and it
protects against a future theme whose `fillChrome` is not neutral — but it is a
tidy-up, not the fix. **Anyone expecting Plan 4's untinting to visibly change the
bar should expect a ~10/255 shift and nothing more.**

### 3. The real failure is legibility over bright backdrops, and only arm 3 survives it.

Contrast of the bar's text ink (`#ebebeb`) against the bar fill beneath it:

| Arm | over white | over black |
|---|---|---|
| 1 shipped tinted | **1.54:1** | 13.83:1 |
| 2 untinted beside | **1.70:1** | 15.45:1 |
| 3 untinted over surface | **4.46:1** | 12.44:1 |
| 4 `NSVisualEffectView` | 4.34:1 | 7.66:1 |

This is the finding that decides the spike. Arms 1 and 2 adapt *so* strongly that
over a bright desktop the bar becomes a near-white slab under light text: 1.54:1
and 1.70:1 are far under WCAG AA's 4.5:1 for body text and under even the 3:1
large-text floor. The bar is unreadable over a light wallpaper. That is a real
shipped bug, and it is the opposite of the flat-slab problem the plan expected:
the glass is not failing to adapt, it is adapting to a backdrop it should not be
sampling.

Arm 3 holds 4.46:1 over white and 12.44:1 over black. Extending the surface under
the bar puts a 0.42 dark well between the glass and the desktop, which is what
keeps the sampled backdrop inside a range the bar's ink was designed against.
Arm 3's spread (67.6) is less than half arm 2's (162) for the same reason, and the
narrower spread *is* the desirable property here.

### 4. Arm 3 is still glass, not blur.

Arm 4 is the control that makes arm 3's number mean something. Over the black
half, arm 3 reaches `#27272e` against `NSVisualEffectView`'s `#484849`: glass
goes materially darker and admits more of the backdrop, and it carries a slight
blue cast (`2e` blue against `27` red) where the control is flat neutral
(`48/48/49`). Arm 3 is not merely arm 4 with extra steps.

### 5. The capsule: glass-in-container and drawn-on-glass are indistinguishable here.

Capsule region against adjacent bar, measured as chroma (max channel minus min):

| Capture | capsule | chroma | adjacent bar | chroma delta |
|---|---|---|---|---|
| arm 1, drawn capsule | `#d19557` | 122 | `#bfbfbf` | 122 |
| arm 3, drawn capsule | `#c28648` | 122 | `#69696d` | 118 |
| `capsule-container-beside`, glass capsule in container | `#d3985a` | 121 | `#b6b6b6` | 121 |
| `capsule-container-over-surface`, glass capsule in container | `#c68b4d` | 121 | `#69696d` | 117 |

A tinted `NSGlassEffectView` capsule inside an `NSGlassEffectContainerView`
renders within 1-2 units of a drawn capsule at every sample. The container's
managed merge does not dissolve the capsule into the bar (`spacing = 0` keeps
them as distinct shapes sharing one sampling pass), and it does not make it more
vivid either.

### 6. The sidebar reads with its own untinted glass.

`sidebar-untinted-glass.png`: a 220 pt column of untinted `regular` glass over the
transparent window region, beside a pane at 0.42. The CHANGED header and the five
file rows are legible, the column is clearly a distinct surface from the pane
beside it, and nothing about the arrangement requires the split-view accessory
controller.

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
`PaneStatusBarMetrics` is built around; the top inset is a visual change for Task
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

### (A) or (B): **(B)**, and the reason is not the one the plan expected.

**Adopt (B): the terminal surface extends under the bar, with
`window-padding-y` raised by half the bar height (+11) to hold the grid.**

The plan framed this as an optics question — which arrangement lenses. The
captures say both lens fine, and that (A) is *actively broken* in a way nobody had
named: over a bright desktop, glass whose backdrop is the desktop adapts to a
near-white slab and the bar's light ink falls to 1.5-1.7:1 contrast. Any owner
with a light wallpaper cannot read their footer today. (B) puts the 0.42 well
between the glass and the desktop and holds 4.46:1 over the same backdrop.

The grid measurement says (B) is affordable: 0 rows delta at +11 padding, verified
against a real PTY, with the naive +22 shown to cost a row.

This is a stronger result than a tie on optics would have been, and it inverts the
plan's stated preference ordering: (A) does not merely fail to be better, it
fails.

### The capsule: **drawn-on-glass**, on the current evidence.

Glass-in-container and drawn render within 1-2 chroma units of each other
(finding 5). Given that, prefer the drawn capsule: it is what ships today, it
costs no second `NSGlassEffectView` and no container, and `PaneStatusBarView`'s
existing hit-testing refusals already cover it. The container arrangement buys
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

### The sidebar: **no restructure.**

`sidebar-untinted-glass.png` shows the sidebar reading correctly with its own
untinted `regular` glass over the transparent window region. The
`NSSplitViewItemAccessoryViewController` restructure — with its session-restore
and focus-rule blast radius — is not needed, and Tasks 2-6 should not take it.

One caveat carried forward rather than buried: the sidebar in that capture sits
over the dark half of the backdrop. Finding 3 says glass over the *desktop* is
exactly the arrangement that fails over bright wallpaper, and a 220 pt sidebar
has far more area to go white than a 22 pt strip. **Task 5 should re-run this
probe with the sidebar centred on the seam before trusting the sidebar over a
light desktop**, or apply the same fix (a well behind it) that (B) applies to the
bar.

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
inactive-2-untinted-beside.png        see "what inactive means here"
inactive-3-untinted-over-surface.png  see "what inactive means here"
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
   grey, which is why finding 2 measures an achromatic +10 rather than a cast.
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
