# Settings preview dials

`./run.sh` from anywhere. Six arms — a fixture precondition, one per signal
dial, and a capsule-alone counterfactual — each dial arm followed by its
inverted control; exits non-zero if any dial stops moving the preview, if any
change lands somewhere the arm did not claim, or if any control loses its teeth.
Needs only `swiftc`; no app build, no capture, no `python3`.

**Safe from anywhere, including inside a baia pane.** The probe opens no window,
takes no focus, launches nothing and quits nothing: every arm renders the
preview's chrome offscreen through `cacheDisplay(in:to:)` and reads the bytes
back, `cluster-legibility`'s arrangement, which is `cluster-wires`'. Nothing
here ever reaches a compositor. TODO: `SAFE_PROBES` membership is the
coordinator's call, not this task's; the probe qualifies on `override-wires`'
ground.

## The question

> **2026-09-04.** `SettingsPreviewPane` and `SettingsPreviewColumn` are gone.
> The settings preview is `Sources/SettingsPreview.swift`, whose sample pane
> installs `Sources/PaneChromeStack.swift`, the same stack a live pane wears,
> so the divergence this probe measured cannot recur by construction. The
> probe still compiles the two overlay views verbatim and its arms still hold
> for them; the prose below describes the arrangement it was written against.

`SettingsPreviewPane` swapped its chrome from the retired `PaneStatusBarView` to
`PaneClusterView` on 2026-08-13. The footer was a 22 pt bar across the pane's
full width; the capsule is a 20 pt pill in the top-right corner, a fraction of
the area. Four settings keys — `focusAccent`, `attentionStyle`,
`attentionAccent`, `alertBehavior` — touch nothing else in the app, so this
preview is the only place they can be seen before they are committed. The
owner's ruling was **decide after I measure** rather than assume a pill-sized
preview shows what a bar-sized one did.

So: when each dial moves, what changes in the preview, and is the change
findable at the size the preview actually renders at?

## Method

**A differential, not a legibility grade.** `cluster-legibility` already grades
the pill's ink and dot against WCAG floors and pins those numbers; nothing here
re-asks that. This asks the other question — a dial the owner *turns* has to
produce a change the owner can *see* — so each arm renders the preview's chrome
twice, once at each end of the dial, and measures the difference between the two
bitmaps. Three numbers per dial:

- **changed area**, pixels differing by more than one byte on any channel, in
  view points² and as a share of the pane. How much of the preview moved. One
  byte of tolerance because both renders go through the same antialiaser and a
  glyph edge can land a byte apart for no reason a dial caused.
- **strongest delta**, the contrast ratio between the two colours at the pixel
  that moved most. How different what moved is. A ratio rather than a byte
  distance for `cluster-legibility`'s reason: the eye's response is not linear
  in bytes, and 1.00:1 is exactly "no visible difference".
- **where it landed**, asserted against `capsule` or `paneEdge`. See below.

**The geometry is the preview's own**, derived from the constants at each site
rather than measured from a live window (a live window would add the one thing
this probe must not have). 238 × 302 pt: the width is 1180 − 400 form − 12 inset
− 12 spacing, halved, less the column's 132 pt sidebar and 8 pt gap; the height
is 660 less the stack insets, the caption and the inter-pane spacing, halved.
`paneSize`'s doc carries the full arithmetic. Rendering the pill at its intrinsic
size — correct for `cluster-legibility`'s question — would answer a question
about a pill in isolation, and this is a question about a pill in a pane.

**The location assertion is load-bearing and was added after the first run
passed without it.** All three colour dials move derivations of the same two
theme colours: `focusAccent` sets `theme.focusedAccent`, and
`attentionColour(.accent, …)` reads it back. Without pinning *where* the change
lands, a `focusAccent` arm passes on any difference anywhere in 71,876 points²
of pane, including one caused by a sibling path it is not about. Verified in
both directions by inverting the expectation: claiming `focusAccent` lands on
the pane edge fails at `(102, 8) is on the pane's edge`, and claiming
`attentionStyle` lands in the capsule fails at `(0, 0) is inside the capsule`.

**The controls are inverted the other way round from every other probe here.**
An arm that renders the same settings twice measures zero, and a "nothing
changed" assertion would pass that trivially — so would an arm whose render
ignored the dial entirely. Under `break` each arm therefore renders **both
halves at the same dial value**, and the arm's own assertions must fail. A
control that still reports change means the two renders differ for a reason that
is not the dial.

## What would be false if this passed and the code were wrong

Each verified by breaking the shipped view and observing the failure, not by
argument:

- **If `PaneClusterView` stopped drawing its focus stroke from
  `theme.inkFocus`** (replaced with `theme.foreground`), the `focus-accent` arm
  reads 0 pt² and fails all three checks. That is the whole of `focusAccent`'s
  expression on the capsule.
- **If the pill's dot stopped resolving through
  `theme.attentionColour(attentionAccent, behavior:)`** (replaced with
  `theme.alert`), the `capsule-alone` arm reads 0 pt² for both
  `attentionAccent` and `alertBehavior` and fails. The four main arms would
  *not* catch this, because the pane frame carries the same two dials and would
  still move — which is exactly why the counterfactual arm is asserted rather
  than merely printed.
- **If `PaneStatus.Attention.wearsFrame(under:)` lost its style term**, the
  `attention-style` arm reads 0 pt². The predicate's own package tests catch it
  first (`PaneStatusTests`, three tests, verified failing against two separate
  breaks).
- **If an arm's change moved somewhere else**, the location check fails; see
  above for both directions measured.
- **If the fixture drifted** from `SettingsPreviewColumn.status(asking:)` — it
  is a copy, because that function is private to a file importing
  `GhosttyTerminal` — the `fixture` arm fails: it pins that the asking pane
  carries a dot and wears the frame, the calm one does neither, and both carry
  the same resting segments.

## Findings

Run of record: 2026-08-13, the day of the swap. Deterministic (no compositor, no
wallpaper, no tone response), so these are pins and a changed byte is a changed
feature.

| dial | what changes | changed area | strongest delta | legible |
|---|---|---|---|---|
| `focusAccent` (accent → bone) | the capsule's 2 pt inset focus stroke | **600 pt²** (0.83%) | `#b4d4fe` → `#e0e0e0`, **1.15:1** | yes, marginal |
| `attentionAccent` (alert → accent) | the pane's edge frame **and** the pill's dot | **2175 pt²** (3.03%) | `#ff5555` → `#b5d5ff`, **2.09:1** | yes |
| `alertBehavior` (stock → noCollision, at `accent`) | the same two, back the other way | **2175 pt²** (3.03%) | `#b5d5ff` → `#ff5555`, **2.09:1** | yes |
| `attentionStyle` (loud → quiet) | the pane's edge frame, entirely | **2144 pt²** (2.98%) | `#ff5555` → `#141414`, **5.87:1** | yes |

And the counterfactual — the same dials with the pane frame removed, which is
what a capsule-alone preview would have shown:

| dial | changed area | strongest delta |
|---|---|---|
| `attentionAccent` | **31 pt²** | 2.09:1 |
| `alertBehavior` | **31 pt²** | 2.09:1 |
| `attentionStyle` | **0 pt²** | 1.00:1 |

**`attentionStyle` is zero on the pill and it is structural, not a wiring
mistake.** `PaneClusterView` has no `attentionStyle` property to set. In a real
pane the key gates `TerminalPaneController.drawsAttentionFrame`, which is
`PaneEdgeFrameView` — and `AttentionStyle.quiet`'s own doc says so: "The capsule
alone. The pane says it is asking; nothing outside the footer moves." The two
values are *defined* as differing only outside the capsule. A capsule-alone
preview cannot show this dial at any size, on any theme, for any status.

**The two attention colour dials survive on the pill alone, but at 31 pt².**
That is the 6 pt dot's disc and its antialiased edge: about 1.4% of the area the
frame gives them, and 0.04% of the pane. The colour step is identical (2.09:1 —
same two colours either way), so the dot alone is *legible* in the strict sense
and *findable* in no useful sense. A 6 pt disc in the corner of a 238 × 302 pt
pane, in a window showing two such panes twice over, is not what an owner
comparing "Current" against "New" will notice.

**`focusAccent` at 1.15:1 is the thinnest number in the table and it is the one
to watch.** 600 pt² is the whole capsule perimeter, so the area is fine; the
delta is thin because Dark Pastel's `accent` (`#b5d5ff`, pale blue) and its
`bone` (`#e0e0e0`, near-white) are both bright neutrals a step apart. Other
`FocusAccent` values are further apart — `ansi5` is magenta — so this row is a
near-worst case rather than typical. It clears the probe's own 1.1:1 floor with
0.05 of headroom, which is the smallest margin measured here and would be the
first thing to fail if the stroke ever thinned.

**Nothing measured requires the sample terminal.** Every number above is a delta
between two renders over the same backdrop, so the backdrop cancels out. The
probe stands the ghostty surface in with its background colour, which is what
the chrome composites against anyway; `cluster-legibility` separately measures
that the pill's face barely moves even under a `#7c7c7c` backdrop.

### What this probe does not measure

The sample terminal's own re-theming. `apply(_:theme:)` reaches a live ghostty
surface and this probe cannot link one, so a break in the terminal half of
`SettingsPreviewPane.apply` would go unseen here. That half is unchanged by the
swap and was never one of the four keys' business.

## Files

```
run.sh      builds the packages (via lib/build-packages.sh), compiles the two
            shipped views verbatim, runs each arm and its control
dials.swift the probe: geometry, offscreen render of the preview's chrome
            stack, the difference measure, the arms and the inverted controls
```

`SettingsPreviewPane.swift` is deliberately not on the compile line — it imports
`GhosttyTerminal` for its sample surface. `renderPreviewPane` rebuilds that
file's two-view stack instead and carries the note that a divergence between the
two is a probe measuring a preview that does not exist. The `attentionStyle`
gate is the one place they cannot diverge: both call
`PaneStatus.Attention.wearsFrame(under:)`, which is why that predicate moved to
the package.

Nothing is written into the repo; the binary and libraries land under
`$TMPDIR/baia-preview-dials-probe`.
