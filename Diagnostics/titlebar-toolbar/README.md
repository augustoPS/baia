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

Twice, and the second time is why this file was rewritten.

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

## The arms

Ten, in two generations. The first four are the original question; the rest
reproduce the shipped window and test candidate fixes against it.

Re-run the probe before quoting an absolute from this table. A show-through
arm's spread is a function of whatever wallpaper sits behind the window at
capture time, so the absolutes move between runs; what transfers is the
ordering and the two-orders-of-magnitude gap between show-through (tens) and
material (~0.0), which is what `spread.py` grades on.

| arm | band spread | verdict |
|---|---|---|
| bare desktop (no window) | 36.7 | — |
| `no-toolbar` | 64.3 | show-through |
| `unified` | 64.3 | show-through |
| `unified-compact` | 64.3 | show-through |
| `unified-transparent-titlebar` | 64.3 | show-through |
| `shipped-clear` | 64.3 | show-through |
| `clear-fullsize` | 63.6 | show-through |
| `background-alpha` (0.42) | 0.0 | MATERIAL |
| `background-alpha-fullsize` | 0.0 | MATERIAL |
| `opaque-baseline` | 0.1 | MATERIAL, wells opaque |
| `minimal-alpha` (0.005) | 0.0 | MATERIAL |

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

## Measuring

The verdict is **luminance spread down the band**, not its mean, and that
distinction is why the defect shipped. The material is a flat neutral and so is a
dark wallpaper behind a bare titlebar; both average to about the same grey, and
the first generation of this probe recorded a bare titlebar as "one flat neutral
(23,23,23)" and called it fixed. Walking down the strip separates them: material
holds one value, show-through tracks whatever is behind the window.

`spread.py` grades every arm and fails the run if `minimal-alpha` loses its
material, if it stops showing the desktop through, or if `shipped-clear` starts
reading as material — the last because a probe that no longer reproduces the
defect has stopped explaining anything.

It also asserts the SIGWINCH property. Flipping the background between `.clear`
and the shipped alpha must move no geometry, since a pane tree lays out against
`contentLayoutRect` and one point of movement there is a live grid resize and a
`SIGWINCH` to every running shell. The probe flips it four times on a real window
with a real toolbar and prints `contentView`, `contentLayoutRect` and the window
frame each time; all five rows must be identical, and they are. That is what
makes the fix safe to apply live rather than only at window creation.
