# Design handoff

Two documents, both pulled down from the Claude Design project **Baia Terminal
UI Design** (`6ee431e0-e6f9-44f0-98fe-315e845e9077`). Each is a **design
reference authored in HTML**, not code to port: recreations of the six app
captures at 1 pt = 1 px, with each proposed treatment rendered on the real
window beside its values. The implementation target was AppKit, and it landed in
`Sources/` and `Packages/PaneChrome/`.

| File | Pulled | What it is |
|---|---|---|
| `Baia Design Pass.dc.html` | 2026-07-25 | v1. Every option, with the arguments for each |
| `Baia Design Pass v2.dc.html` | 2026-07-26 | v2, "decisions only". One treatment per problem |

v2 carries the same nine sections, retitled. It drops the alternatives and picks
a winner in each, so v1 stays as the record if an argument needs reopening.
Most of v2 ratifies what shipped from v1; the five places it does not are listed
below.

## Reading it

The copies here are the documents only. Each imports a React runtime
(`support.js`, 70 KB, generated) and a web design system (`_ds/`, the
Nothing-inspired token and component library), and neither is vendored: a Swift
repository should not carry 200 KB of web assets to render one document, and
both are upstream files nobody here would edit.

So **read them in the Claude Design project**, where they render complete. The
local copies are for diffing against what was implemented, and for surviving the
project being changed or deleted.

The project also holds `design_handoff_baia_chrome/baia-design-pass-v2-standalone.html`,
a 254 KB self-contained bundle that renders v2 offline with everything inlined.
It is deliberately not vendored here for the same reason `_ds/` is not. Pull it
down if you need to read v2 without the project.

The six source captures both documents were built from live in
`../design-captures/`, which is gitignored for the images and tracked for
`capture.sh` that regenerates them.

## What was implemented from v1

Everything in the document except where noted, on 2026-07-25:

- The focused-pane treatment, all three styles (`recede` is the default)
- The two-level attention model, both volumes, with the arrival pulse
- The tab grammar and the window-title formats
- The four footer tiers, the coloured markers, the pin chip
- The themed split divider
- The app icon, direction C (SEAM) with the drawn `>_` glyph

Two things v1 leaves open that are now answered:

- **`focusAccent` stays `accent`.** The document recommends `bone` and
  deliberately defaults to `accent`; the default was kept, and all four
  derivations exist behind the config key. v2 keeps the same recommendation.
- **The dock badge is not the icon's fault.** The document names the placeholder
  icon as the leading suspect for `NSApp.dockTile.badgeLabel` doing nothing and
  says to re-test once a real icon ships. Tested: the Dock renders the new icon,
  and a fixed `badgeLabel = "9"` set at launch still produces no badge. The
  window title stays the primary carrier rather than becoming a fallback. See
  `Sources/AttentionNotifier.swift`. v2 §07 repeats the original instruction,
  unaware of the test.

One approximation worth knowing about: the tab grammar shows `:branch` only when
the branch is not the repository's default, and "default" is a name test for
`main` or `master` rather than an answer from git. `GitWorkspace` does not
collect the real default branch today. The predicate is
`TerminalPaneController.isConventionalDefaultBranch`, so replacing it is a change
to one function.

## Where v2 and the code diverge

Nothing below is implemented. Checked against `main` on 2026-07-26.

1. **§02 picks a focus treatment the code does not have.** v2 settles on a 2 pt
   inset stroke around the **footer bar only**, in `ink.focus`, the same colour
   as the anchor name, with the bar's fill identical in both states. The code
   ships `FocusStyle` with three cases defaulting to `recede` (a scrim over
   every *other* pane), and its `frame` case strokes the whole **pane** through
   `PaneOverlayView`. v2's answer is neither. It also names two constants that
   do not exist: `focusFrameWidth = 2`, and `frameCollapseWidth = 120`, below
   which the frame drops its side edges and becomes a bracket.
   `PaneStatusBarMetrics` currently documents the opposite rationale, that focus
   is not drawn in the bar at all.
2. **§08 deletes `focusStyle`.** With one treatment per problem, v2 leaves two
   config keys: `focusAccent` and `attentionStyle`. The code has both, plus
   `focusStyle` and `unfocusedScrim`, plus the cross-validation in
   `Settings.resolvedAttentionStyle` that quietens attention under `invert`. v2
   argues that rule is unnecessary once focus is an edge and attention is a fill,
   because the two can never collide.
3. **§01 adds a fifth accent, `midnight`.** `ansi[4].blended(ansi[5], 0.5)`,
   resolving to `#C890FF` at 6.8:1. `FocusAccent` has four cases. The
   recommendation is unchanged (`bone`, on the argument that four brights are
   spent on state and focus is not a state), with `midnight` named the best of
   the coloured options.
4. **§07 moves the icon glyph to the upper third.** v2 specifies chevron
   `471,287 → 559,375 → 471,463` with the ink baseline at 483 and the cursor at
   `623,427`. `Icon/make-icon.swift` puts the vertex at y = 550 and the baseline
   at 658, with chevron arms of 110 against v2's 88. The glyph sits about 175
   units lower and larger than v2 asks for. Bay, plank (x = 306, w = 44), cursor
   width 200 and gap 64 all match.
5. **`plank` never became a theme role.** v2 §01 names it
   `foreground.blended(background, 0.46)` = `#6E6E6E`, doing two jobs: the icon's
   dividers and the PIN chip's border. The icon hardcodes the hex, and the chip
   border is `context.blended(inkBackground, 0.45)` in `PaneStatusBarView`.
   `PaneTheme` has no `plank`. Related: §06 wants the divider's drag colour to be
   `ink.focus`, where `PaneTreeController` uses `edgeFocus`, the 0.55 blend v2
   deletes.

Everything else in v2 matches: the foundations table, the two-level attention
model with its 510 ms one-shot opacity pulse and reduce-motion skip, the
window-title formats, the tab grammar and its width ladder, the four footer tiers
on baseline 15, and the divider at 1 pt with a ±3.5 pt hit area through
`additionalEffectiveRectOfDivider`.
