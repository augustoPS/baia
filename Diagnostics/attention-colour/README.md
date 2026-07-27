# Attention colour probe

`./run.sh` from anywhere. It renders a real `PaneStatusBarView` and a real
`PaneEdgeFrameView` through `cacheDisplay(in:to:)`, reads the pixels back, and
checks that every attention mark carries the colour `attentionAccent` and
`alertBehavior` resolve to. Five arms, one process each, and every arm is followed
by a `break` variant that damages the drawing and is expected to fail. `run.sh`
inverts those, so a control that stops failing fails the run as loudly as an arm
that stops passing.

Nothing is captured from the screen. `screencapture` needs a screen-recording
grant that a headless run cannot answer, and it is not needed: every reading comes
from a bitmap this process rasterizes itself. No arm takes focus and no window is
made key.

`Sources/PaneStatusBarView.swift`, `Sources/PaneOverlayView.swift` and
`Sources/WindowCorner.swift` are compiled verbatim by `run.sh`, so the pixels
measured are the ones the app draws.

## What the arms are for, and what the controls damage

`PaneChromeTests` already says `PaneTheme.attentionColour(_:behavior:)` returns
the right colour for all six combinations of the two keys. That is the thing the
drawing *calls*. The previous probe in this repo, `footer-corners`, learned the
difference painfully: four of its six arms verified a geometry helper while the
`addClip()` that consumed it was covered by nothing, and its controls all failed
correctly, which is exactly what made it look sound.

So every control here damages the drawing rather than the resolution, and each one
renders the code as it stood before this feature: a site wired straight to
`theme.alert` whatever the config says. `fill`, `quiet` and `acked` do it by
handing the view the shipped defaults while the arm still checks against the
combination under test; `frame` does it to both of its gates.

The controls fail on two of six rows rather than all six, which is correct and is
the reason all six run. Dark Pastel resolves the six settings onto three colours:
`alert` with any behaviour is `#ff5555`, and so is `accent` + `noCollision`. Only
`accent` + `stock` (`#b5d5ff`) and `accent` + `derive` (`#cfa8c3`) differ from red,
so only those two rows can tell a wired-to-alert site from a correct one. An arm
that checked one row would have had a one-in-three chance of proving nothing.

## What an arm can see, and the gate that gives it eyes

Every arm computes its expectation by calling
`PaneTheme.attentionColour(_:behavior:)`, the function under test. That is the only
way to ask "does the drawing follow the resolution" without writing a second
resolution for the first to disagree with, and on its own it is blind: mutate
`attentionColour` to return one colour and the expectation moves with the drawing,
so every coverage check stays green.

`distinctness` is what closes that. Dark Pastel resolves the six settings onto
three colours, so six rows that drew fewer than three were either handed a constant
or sampled somewhere the colour never reaches. Every arm runs it, over the
commonest pixel each row drew: the wash for `fill`, the line for `quiet`, the
square for `acked`, the top edge for `frame`, and for `conflict` the six *asking*
bars, which is the one thing that arm's equality comparison cannot see for itself.

The gate was added after the fact, and the reason is worth keeping. Mutating
`attentionColour` to `return alert` unconditionally failed `fill` and was walked
past by `quiet`, `acked`, `frame` and `conflict`, all four of which reported
coverage of a colour they had computed from the mutation. With the gate, the same
mutation fails all five.

## The pixel tolerance, and the gate that keeps it honest

Colours go in through `NSColor(srgbRed:...)` and come back out of a bitmap whose
colour space AppKit picks for a windowless view, and the round trip moves a
channel by one: the derived accent goes in as `#cfa8c3` and reads back `#cfa9c4`.
Comparison is therefore within two units per channel.

Every pixel arm opens with a `pipeline` line that measures a quiet bar against
`theme.barBackground` and requires more than half of it to match. If the round
trip ever moved further than the tolerance, that gate fails first and says so,
rather than the arms below quietly needing a wider one.

## fill

The loud wash, which is also the layer the 510 ms arrival pulse animates. All six
combinations, on an asking pane at `attentionStyle: loud`.

More than half the bar has to carry the resolved colour, and the commonest pixel
on the bar has to be it. Half rather than all, because the text, the hairline and
the busy dot are drawn over the wash and are entitled to their pixels; in practice
it measures 94.4%.

Then the shared distinctness gate over the six washes.

## quiet

The 2 pt line the `quiet` treatment spends instead of the bar's background, along
the top edge of an unfocused bar. 100% of the line's own rows, and the bar under it
still has to be `barBackground`, because a quiet treatment that filled the bar
would clear the first check and be the loud one.

## acked

The 6x6 pt square an acknowledged pane keeps. Its rectangle is computed from the
constants the view draws it with and pulled in one pixel so the antialiased edge is
nobody's evidence: 100 px, all of which have to be the resolved colour.

The second gate is that fewer than 10% of the *bar* carries that colour. Without
it, a footer that had filled itself would pass on the strength of its fill
covering the square.

## frame

The 2 pt frame around the whole pane, the other half of the loud treatment. Two
gates, because the drawing and the decision live in different files and only one of
them can be rendered here.

The pixel gate builds a real `PaneEdgeFrameView`, hands it the resolved colour and
requires all four edges to carry it and the interior not to. A frame that filled
the pane rather than outlining it would be a coloured sheet over a live terminal,
so that is checked rather than assumed.

The source gate reads the one assignment in `TerminalPaneController.applyPresentation`
out of the shipped file and requires it to be
`edgeFrame.colour = theme.attentionColour(attentionAccent, behavior: alertBehavior)`,
and requires there to be exactly one of them. It is a source check and openly so:
the pixel gate proves only that the view draws the colour it is given, and the
thing that can regress is the colour it is given. `edgeFrame.colour = theme.alert`
compiles, renders, and ignores the config entirely. Its control rewrites that line
in memory to what it said before this feature, which is damaging the shipped text
rather than moving the goalposts.

## conflict

Red still means conflict. `PaneTheme.alert` is the conflicted-tree marker and the
`!` glyph as well as the attention colour, and only the attention colour follows
the setting.

A pane with a conflicted tree and no agent asking is rendered under all six
combinations and every pair has to be identical, pixel for pixel. If the git
segments had been helpfully wired up too, the six bars would differ and the arm
counts how many pixels did. The marker is confirmed present first, 61 px of it, so
the arm cannot pass by comparing six copies of a footer with nothing red on it.

Before either, the distinctness gate runs over six *asking* bars. An equality
comparison is blind twice over here: six identical footers are trivially equal, and
the expectations come from the function under test. Making the settings prove they
can move a pixel at all is what parts "the git segments were left alone" from "the
setting does nothing anywhere". It runs in both modes, because it is not what the
control damages.

Its control is the only one that is not a damaged draw site, because there is no
way to damage "this does not follow the setting" from outside the file. It asks the
same question of a pane that *is* asking, where the six settings are supposed to
differ, and 25,739 pixels do. That is what says the comparison can see a difference
at all: an arm built on equality passes when it is blind.

## What this cannot reach

`TerminalPaneController` itself. It imports `GhosttyTerminal`, so building it here
would mean linking libghostty and spawning a pty for four edges, and a probe nobody
runs proves nothing either. The `frame` arm reads its assignment out of the source
instead and says so above.

`ConfigurationCenter.apply(to:)` is in the same position: the two lines that push
`settings.attentionAccent` and `settings.alertBehavior` into a pane are not
executed here. Everything downstream of them is.

**The last step, that the colour on screen is the colour measured here, cannot be
proven without looking.**
