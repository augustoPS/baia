# Cluster attention probe

`./run.sh` from anywhere. Four arms, each followed by a control that damages the
drawing and must fail. Nothing is captured from the screen, no window is made
key, and no app is launched: every reading comes from a bitmap this process
rasterizes through `cacheDisplay(in:to:)`.

## The question

**Does the capsule draw a different mark for each attention level, and is that
mark legible on the fill it sits on?**

Both halves were false until 2026-08-15. `PaneClusterView` drew one 6 pt oval in
`attentionColour` for `asking`, `acknowledged` and `done` alike, so three levels
that `PaneStatus.Attention` computed, tested and delivered arrived at the view
and were ignored. Spec:
`vault/projects/baia/specs/2026-08-15-what-the-capsule-says-about-attention.md`.

The legibility half is the part no test could have caught by reading values. A
sweep of the shipped catalog found the bare dot clearing 3:1 on 67.7% of rows on
a flat pill and 26.2% under glass, worst 1.00:1, because nothing bounded the
accent against the surface behind it. The bar this capsule replaced never had
that problem and never relied on the fill: it drew a glyph *on* the fill in
`theme.ink(on:)`, which `readable(_:on:minimumRatio:)` bounds against its
argument. The capsule kept the fill and dropped the glyph, and the guarantee went
with it.

## The arms

| arm | claim | control |
|---|---|---|
| `levels` | the three levels differ from each other in pixels | all three rendered as `asking`, which is what shipped |
| `calm` | no pixel of a `done` segment is the attention colour | `done` rendered as `asking` |
| `anchor` | the attention segment's rect is identical at every level | one level's glyph widened |
| `ink` | the glyph is `theme.ink(on:)` of what it sits on | `run.sh` rewrites that call to `theme.foreground` |

`levels` compares renders rather than naming a colour, so it survives a change of
treatment: whatever the levels are drawn as, they may not be drawn the same. A
test asserting "asking is a filled red capsule" would need rewriting by the next
design pass and would pass meanwhile.

`calm` exists because `levels` passed a wrong drawing. That arm asserts only
that the levels differ, and the first implementation gave `done` a capsule filled
in alert red, which differs from the other two and is still a finished pane
shouting for attention. It took the owner's eye on a capture to see it, and the
arm now states the half a difference test cannot: a finish is a notification
rather than a request, so it wears none of the colour that means "answer me".
Clean reads 0 attention-coloured pixels, the control 244.

`anchor` is the spec's criterion 2 and the half of an earlier ruling that
survived its reversal. `approvalAnchorRect()` anchors the approval popover to
this segment, so a width that varied by level would move a popover as a side
effect of an agent being seen. The mark changes; its box does not.

`ink`'s control is a `sed` in `run.sh` rather than a flag on the view, following
`pane-resize`: a seam added to production for a probe to poke is a second way the
shipped code can be wrong. A no-op `sed` is a hard failure, so the control cannot
silently stop damaging anything.

## What the ink arm reads, and what it read first

The glyph's **commonest** non-fill colour inside the capsule, not any matching
pixel. Two corrections got it there, both found by running it rather than by
reading it:

- `hits > 0` passed on a single antialiased blend. A `!` at 10 pt heavy is a few
  solid pixels inside a wide skirt of blends between ink and fill, so almost any
  ink would satisfy that.
- Reading the whole segment box returned `barBackground` as the commonest colour
  (#212121 on Dark Pastel) and failed a correct drawing. `segmentRect(for:)`
  spans the full pill height while the capsule is `capsuleHeight` concentric
  inside it with rounded ends, so the box's corners are pill. The arm insets to
  the capsule's interior before reading.

Clean reads `#141414` (`ink(on: #ff5555)` on Dark Pastel); the control reads
`#bbbbbb`, which is `theme.foreground`, legible on the pane and unbounded against
this fill. That is the plausible wrong answer rather than an absurd one, which is
what a control is for.

## What it does not reach

The catalog. This probe renders Dark Pastel, and the guarantee it checks is that
the drawing calls the bounded function; that the function clears the floor on all
485 themes is `theme-catalog`'s question and the sweep recorded in the spec. The
two together are the claim: one says the guarantee is asked for, the other says
it holds.

It also says nothing about glass. `pillInk` returns `theme.background` under
glass because the material's effective colour depends on a desktop no probe can
see, and the wash floor is what guarantees anything there. Judging real glass
needs a screen and an eye.
