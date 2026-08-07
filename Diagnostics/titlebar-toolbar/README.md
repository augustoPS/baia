# Titlebar toolbar probe

`./run.sh [output-directory]` from anywhere. Builds four throwaway windows,
captures each titlebar strip, and prints the chrome height each arrangement
costs. Launches and quits nothing of baia's, so it is safe from inside a pane.

## The question

Once the workspace window became genuinely non-opaque (`331b7ec`: `isOpaque =
false` and a clear `backgroundColor` whenever `backgroundOpacity < 1`), the
titlebar region had no material in it. The traffic lights and the title floated
on whatever was behind the window. The owner's ruling was to go full macOS and
adopt the platform treatment rather than hand-draw a scrim, which on macOS 26
means an `NSToolbar`: the research record
(`vault/projects/baia/liquid-glass-research.md` §4) states that the titlebar
material "comes from `NSToolbar` and window style, not new window flags".

Two things had to be decided from pixels rather than guessed:

- Does an **empty** toolbar (no delegate, no items) produce the material at all,
  or does AppKit need items to draw a titlebar?
- `.unified` or `.unifiedCompact`?

And one had to be ruled out: whether the retired `transparentTitlebar` setting
should map to `titlebarAppearsTransparent`.

## The arms

| arm | chrome height | strip reads |
|---|---|---|
| no toolbar | 32 pt | the content behind the window, varying down its height |
| empty toolbar, `.unified` | 52 pt | one flat neutral |
| empty toolbar, `.unifiedCompact` | 40 pt | one flat neutral |
| empty toolbar + `titlebarAppearsTransparent` | 52 pt | back to show-through |

## The verdicts

**An empty toolbar is enough.** No delegate is set and no items exist, and the
material is there anyway, with the title still displayed. That is what let the
app take the platform titlebar without inventing toolbar buttons it does not
want — baia's controls live in the footer and the command palette.

**`.unifiedCompact`.** Both toolbar arms measured identically flat, so the
material was not the tiebreaker; the cost was. Compact spends 40 pt of chrome
against unified's 52, which matters in a terminal where every point off the
titlebar is a row of cells returned to the grid, and it matches the 22 pt scale
baia's own chrome is built at.

**`titlebarAppearsTransparent` is not the meaning of `transparentTitlebar`.**
The fourth arm has a toolbar and still reads as show-through: that flag undoes
precisely the fix the toolbar exists to make. So the setting was retired from the
ghostty emission rather than remapped (it configured a window ghostty never
created, and was read by nothing), keeping its decoding for file compatibility.

## Measuring

Sample a column clear of the traffic lights and walk down the strip. Material
reads one value all the way down; an unmaterialed titlebar tracks whatever is
behind the window and varies. Measured on the live app for confirmation: at
`backgroundOpacity = 1` the strip is flat and solid, and at the owner's `0.1` it
is deliberately translucent — the material is doing its job over a non-opaque
window, which is the arrangement working rather than a failure.
