# Titlebar toolbar probe

`./run.sh [output-directory]` from anywhere. Builds ten throwaway windows, shows
them one at a time, captures each alone, and grades every arm on whether its
titlebar carries material.

**Run this from outside a baia pane.** It launches nothing of baia's and quits
nothing, which is true and is not the point: it calls
`setActivationPolicy(.regular)` and `makeKeyAndOrderFront`, so it activates and
takes the keyboard from whatever is frontmost. An agent driving it from inside a
pane loses its shell mid-run. That is the hazard `SAFE_PROBES` in
`guard-baia-alive.sh` guards, and the guard correctly refuses this probe from a
pane; it does not belong on that list. An earlier version of this file reasoned
from "launches nothing of baia's" to "safe from inside a pane", which does not
follow.

## The question

Three times, and each rewrite is a previous answer turning out to have answered
a narrower question than the owner was asking.

**First**: once the workspace window became genuinely non-opaque (`331b7ec`), the
titlebar region had no material in it, and the research record
(`vault/projects/baia/liquid-glass-research.md` §4) says the material "comes from
`NSToolbar` and window style, not new window flags". So: does an *empty* toolbar
produce it, and `.unified` or `.unifiedCompact`? Answered below, and shipped in
`5f3b88c`.

**Second**: that shipped and the owner still saw no titlebar — "what titlebar" —
at 0.1, at 0.62, and at 0.99. The first generation of arms had measured the wrong
window. Every one of them filled its whole content view with a dark translucent
fill, and the real workspace window does not: it is `backgroundColor = .clear`
with content starting below `contentLayoutRect`, so the titlebar band has nothing
beneath it. The arms had been giving the material something to composite against
that the app never had.

**Third**: the material came back, the owner looked at it, and said "titlebar is
not glass/transparent." What generations one and two restored is the *system*
titlebar — a solid slab that blocks the desktop completely (band spread 0.04,
flat all the way down, unmoved by the opacity knob) while every other chrome
surface in the app wears untinted `NSGlassEffectView` and shows the desktop
through. "There is a titlebar" had been the whole question, and it was the
wrong one. Generation three asks which arrangement makes the band read like the
rest of the chrome. Answered below, and shipped in the commit that added these
arms.

## The arms

Thirteen, in three generations. The first four are the original question, the
next five reproduce the shipped window and test candidate fixes against it, and
the last three ask what makes the band glass rather than a slab.

Re-run the probe before quoting an absolute from this table. A show-through
arm's spread is a function of whatever sits behind the window at capture time,
so the absolutes move between runs; what transfers is the ordering and the gap
between the three clusters, which is what `spread.py` grades on.

Numbers below are one run, on a textured wallpaper with the capture region
clear (see **Measuring** for why that second condition is not automatic).

| arm | band spread | band mean | verdict |
|---|---|---|---|
| bare desktop (no window) | 64.9 | 153.1 | — |
| `no-toolbar` | 23.7 | 101.4 | show-through |
| `unified` | 27.3 | 99.2 | show-through |
| `unified-compact` | 26.7 | 99.7 | show-through |
| `unified-transparent-titlebar` | 27.3 | 99.2 | show-through |
| `shipped-clear` | 26.7 | 99.7 | show-through |
| `clear-fullsize` | 22.1 | 102.7 | show-through |
| `background-alpha` (0.42) | 0.0 | 36.9 | MATERIAL |
| `background-alpha-fullsize` | 0.0 | 39.8 | MATERIAL |
| `opaque-baseline` | 0.1 | 38.7 | MATERIAL, wells opaque |
| `minimal-alpha` (0.005) | 0.0 | 36.9 | MATERIAL |
| `transparent-no-glass` | 26.6 | 99.4 | show-through |
| `glass-in-content` | 4.2 | 69.7 | MATERIAL (and moves geometry) |
| `glass-in-frame` | 5.8 | 68.9 | **GLASS** |

## The verdicts

**An empty toolbar is enough, and `.unifiedCompact` is the metric.** No delegate,
no items, material anyway, title still displayed. Compact spends 40 pt against
unified's 52 where no toolbar is 32, and in a terminal every point off the
titlebar is a row returned to the grid. Unchanged from the first generation.

**The toolbar was necessary and not sufficient. The material needs a non-clear
window background.** `backgroundColor = .clear` leaves AppKit nothing to
composite the titlebar material against, so it draws nothing at all. The failure
is binary on that flip, not proportional to opacity: every `.clear` arm spreads
64 and every arm with *any* non-zero alpha spreads 0.0, including 0.005. There is
no ramp. That is why the opacity knob never moved it and why 0.99 looked as
broken as 0.1 while exactly 1.0 was fine — at 1.0 the window is opaque and the
background is `.windowBackgroundColor`.

**Not `fullSizeContentView`.** The platform recipe for chrome over content is
content extending under the titlebar, and that was the first hypothesis. The
`clear-fullsize` arm does exactly it — the style mask set, the well anchored to
the safe area so the backing extends while the visible layout stays put — and its
band spreads 63.6, the bare-titlebar number. Content beneath the band is not what
the material samples. The arm is kept rather than deleted, because the next
reader will otherwise re-derive it.

**The smallest non-zero alpha is the right one, because the wells are the cost.**
`minimal-alpha` at 0.005 keeps a well spread of 50.0 against the shipped `.clear`
arm's 50.1: the desktop shows through exactly as much as it did. The 0.42 arm
restores the material just as completely and drops the wells to 29.1. The alpha
exists to be non-zero, not to tint — at 0.005 over a 0.09 white it is under a
single 8-bit level and cannot be seen.

**`titlebarAppearsTransparent` is not the meaning of the retired
`transparentTitlebar` setting.** That arm has a toolbar and still reads
show-through: the flag undoes the fix the toolbar exists to make.

**The slab is not glass, and the difference is measurable rather than a matter
of taste.** `minimal-alpha` — what shipped — holds one value down the whole
band (spread 0.0) and does not move when `backgroundOpacity` does. Measured on
the live dev build at the owner's own settings, the shipped band read the same
whether the knob was at 0.09 or 0.85. Every other chrome surface tracks that
knob. That gap is what "titlebar is not glass/transparent" names.

**`titlebarAppearsTransparent` plus a real glass view is the arrangement, and
the flag's earlier acquittal still stands.** `5f3b88c` ruled the flag out and
was right about the window it measured: over a `.clear` background it removes
the material and leaves bare wallpaper. `transparent-no-glass` reproduces
exactly that and still grades show-through at 26.6 — the control that proves
the flag really does stop the slab, so a glass arm's reading is the glass and
not a slab surviving underneath it. What changed is that the band is no longer
empty afterwards. The toolbar stays and measurably must: with the flag set, the
band is still 40 pt, the toolbar still reports visible, and the title and
subtitle are both still present. The probe asserts all four.

**The frame view, not `fullSizeContentView` — and the app stopped following
that on 2026-08-12, while the measurement behind it stands.** Both glass arms
produce glass; they are told apart by what they cost. `glass-in-content` parents
the backing in the contentViewController's own view, which needs
`.fullSizeContentView` to reach the band, and that drops `contentLayoutRect`
from 292 to 220 pt. `glass-in-frame` parents into `contentView.superview`, needs
no style-mask change, and leaves the rect untouched. `spread.py` asserts both
halves of that trade, so neither is re-derived and a future macOS that stops
charging for the first shows up as a failure here.

**What changed is the inference, not the number.** This paragraph used to run
from the 220 pt drop straight to "adopting it would resize every ghostty grid
and `SIGWINCH` every running shell", and that step assumed the pane tree's rect
follows `contentLayoutRect`. `Diagnostics/titlebar-merge`'s arm 5 measured the
alternative: extend the content view, let the sidebar column's rect grow up
under the band, and hold the tree's rect at the row it had. The tree region came
back identical in all four components, and its `gridtest` companion put a real
libghostty surface in that rect and read 73 x 19 in both arrangements with zero
resize callbacks across the flip. The app now carries `.fullSizeContentView` and
splits the rect in `SurfaceHosts` (`Sources/SurfaceHosts.swift`), because that
is the only arrangement in which the band's glass and the column's can share one
`NSGlassEffectContainerView` and stop showing a seam.

**No arm was re-aimed and none needed to be.** This probe builds its own
thirteen windows and links no app source, so it measures arrangements rather
than baia's window: the arms are as true after the change as before, and the run
passes unmodified. The 220-against-292 assertion is now a cost the app pays
knowingly rather than a cost it refuses, which is a change to what the app does
with the number and not to the number.

**Glass reads dimmer than bare show-through and that is the point.** The band
mean sits between the slab's and the raw wallpaper's because the glass is
lensing rather than blocking or passing through. The verdict does not test that
mean — see **Measuring** — but it is reported because it is the number that
makes the three clusters legible at a glance.

## Measuring

The verdict is **luminance spread down the band**, not its mean, and that
distinction is why the defect shipped. The material is a flat neutral and so is a
dark wallpaper behind a bare titlebar; both average to about the same grey, and
the first generation of this probe recorded a bare titlebar as "one flat neutral
(23,23,23)" and called it fixed. Walking down the strip separates them: material
holds one value, show-through tracks whatever is behind the window.

**Glass is a third state, and spread alone cannot name it.** Generation two
separated slab from wallpaper on spread, which worked because those two differ
by three orders of magnitude. Glass sits between them: it keeps the backdrop's
structure but softens it, here by about 4.5x. It landed at 5.8 against a
threshold of 5.0 drawn for a different question, so the first version of this
grader failed the winning arrangement by a hair. The verdict is now the
*ratio* of the band's spread to the backdrop's — how much structure survived —
which needs no absolute and moves with the wallpaper the way the arms do.

**The band's mean is reported and deliberately not tested.** An earlier version
of the glass check also required the band's mean to sit near the bare desktop's.
That is unsound: the baseline samples the whole strip of uncovered wallpaper
while an arm's band samples whatever is behind the window at its own position,
so the two means describe different backdrops. A bright baseline duly failed a
band that was visibly, correctly glass.

**A textured backdrop is a precondition, and "bare desktop" is a claim about
the screen rather than something the probe can arrange.** The baseline is one
fixed screen rect, and whatever is parked there is what gets measured. The first
plain-backdrop run of this grader turned out to be a *terminal window* sitting
at that spot, its text averaging to a flat grey — not a plain wallpaper at all,
and with nothing to lens the glass arm read 1.3 and graded "flat slab". So
`spread.py` checks the baseline's own spread first and skips the glass
assertions, saying so, when the backdrop cannot answer the question. Clear the
capture region before trusting a GLASS verdict.

`spread.py` grades every arm and fails the run if `minimal-alpha` loses its
material, if it stops showing the desktop through, if `shipped-clear` starts
reading as material — that one because a probe that no longer reproduces the
defect has stopped explaining anything — if `transparent-no-glass` stops
reading as show-through, if `glass-in-frame` stops reading as glass or costs
content height, or if `glass-in-content` stops costing it.

It also asserts the SIGWINCH property, now twice. A pane tree lays out against
`contentLayoutRect`, so one point of movement there is a live grid resize and a
`SIGWINCH` to every running shell. The probe flips each candidate four times on
a real window with a real toolbar and prints `contentView`, `contentLayoutRect`
and the window frame each time; all five rows of each block must be identical,
and they are.

- **the background flip**, `.clear` against the shipped alpha, which is what
  made `ea7a223` safe to apply live rather than only at window creation.
- **the titlebar-glass flip**, `titlebarAppearsTransparent` plus adding and
  *removing* the frame-view backing, which is what makes the glass safe to
  toggle from a live settings edit. Removal is included rather than hiding,
  because that is the path a chrome change takes under flat.

  **Kept after the app stopped parenting in the frame view (2026-08-12), and
  the reason is the flag rather than the parent.** `applyTitlebarGlass()` no
  longer adds a view here — the band's plane moved into `SidebarHost` so a
  container could merge it with the column's — but the flip still measures the
  two things that decide whether a live chrome change is safe: that
  `titlebarAppearsTransparent` moves no geometry, and that adding or removing
  glass in the band region moves none either. Both are exactly what the app
  still does on every settings edit, in a different superview. Deleting the arm
  would retire a live assertion in exchange for nothing measured.

## Why not ghostty parity (arrangement B)

Extending the terminal surface under the titlebar the way the footer does is
the other way to make the band read as terminal rather than as chrome, and it is
ruled out here rather than measured.

The premise it was proposed on is false and worth correcting: `window-padding-y`
is **not** restricted to one symmetric value. Ghostty 1.3.1 documents
`window-padding-y = top,bottom` (`ghostty +show-config --default --docs`), and
`TerminalConfigCommand.custom` can emit any string, so an asymmetric top
compensation is expressible. `PaneStatusBarMetrics.glassWindowPaddingBump`'s
doc comment says "`window-padding-y` is symmetric", which is true of how baia
*emits* it today and not of the key. The arithmetic therefore does not rule (B)
out: a 40 pt titlebar wants `+40` on top, and `window-padding-y = 40+p,p` says
exactly that.

What rules it out is the window's shape. The footer's compensation works because
every pane has its own footer, so the bump is per-pane and uniform. The titlebar
spans the whole window above a *sidebar column plus a split pane tree*: only the
top row of panes touches the band, the sidebar touches it too and has no ghostty
grid to compensate with, and the compensation would have to be recomputed per
pane on every split and every drag. Each of those recomputations is a
`window-padding-y` change on a live surface, which is the live grid resize
`spawnedUnderGlass` exists to prevent. Arrangement (A) costs none of it: the
glass is a window-level view over chrome AppKit already owned, and the probe
measures `contentLayoutRect` unmoved across the flip.
