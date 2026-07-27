# Full-screen strip probe

`./run.sh` for the geometry arm. `./run.sh sample <image> [x,y ...]` for the
sampler. The geometry arm takes over the display for a few seconds and exits on
its own.

## What this answers

On the notched built-in display, a full-screen baia window has a band of pure
black above its tab bar. Everything else on screen is grey: the tab bar reads
`#4B4B4B`, the terminal background `#1D1D1D`, the footer `#343334`. The band is
the only pure black anywhere in the window, so full screen reads as letterboxed
rather than filled, and the obvious next move is to paint the band with the
theme background.

That move is wasted work if the band is not inside the window, and a screenshot
cannot tell the two apart. A 39 pt black band looks identical whether the window
starts below it or the window covers it and is showing an unset system
`backgroundColor` through a safe-area inset. The first is unpaintable, the second
is a one-line fix.

## geometry

Opens a real window, drives a real `toggleFullScreen`, and reads the numbers
after the transition rather than reasoning about them. Measured 2026-07-27 on
the 16-inch built-in display:

```
screen.frame           (0, 0, 1800, 1169)
screen.visibleFrame    (0, 0, 1800, 1130)     in full screen
screen.safeAreaInsets  top 38
window.frame           (0, 0, 1800, 1130)
contentView.safeArea   top 0
```

The window is handed `visibleFrame`, and `visibleFrame` in full screen already
has the menu bar strip taken out of it. The content view's own inset is zero,
because there is nothing inside the window to avoid. So the 39 pt sits outside
the window: no background colour, no extended tab bar, no footer change reaches
it. `NSPrefersDisplaySafeAreaCompatibilityMode` is not a lever either, since it
already defaults to NO and YES would only force more letterboxing. Filling that
space means not using native full screen at all, which is a feature and not a
fix.

The arm asserts this rather than only printing it, because the conclusion is
load bearing: a macOS that starts handing the window the full frame should fail
here instead of leaving the note in `Verified 2026-07-27` quietly wrong. It
skips on a display with no safe-area inset, where there is no strip to explain
and a failure would only be reporting the monitor.

## sample

Reads pixels out of a screenshot, because "it looks black" and "it is `#000000`"
are different claims and only one settles an argument about whether a surface
matches the theme. Coordinates are image pixels from the top left, so on a 2x
capture they are twice the point value. With no coordinates it still reports how
far a solid black band at the top of the middle column runs, which is the 78 px
that the geometry arm then explains.

```
./run.sh sample ~/Desktop/shot.png 1800,36 600,106 900,720
```

## Where this came from

The find-in-pane live pass on 2026-07-27. The strip was noticed while confirming
that footer corners go square in full screen, which they do.
