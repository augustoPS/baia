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

- The focused-pane treatment, all three styles (`recede` is the default), since
  collapsed to the one treatment by v2 §08
- The two-level attention model, both volumes, with the arrival pulse
- The tab grammar and the window-title formats
- The four footer tiers, the coloured markers, the pin chip
- The themed split divider
- The app icon, direction C (SEAM) with the drawn `>_` glyph

Two things v1 leaves open that are now answered:

- **`focusAccent` stays `accent`.** The document recommends `bone` and
  deliberately defaults to `accent`; the default was kept. The claim once made
  here, that all four derivations existed behind the config key, was wrong: the
  key was decoded, stored and covered by four tests while nothing read it, and
  `PaneTheme.focusedAccent` came from the theme's selection colour on every
  path. `"focusAccent": "bone"` was a silent no-op for nine days. Fixed on
  2026-07-26 as part of the v2 pass. v2 keeps the same recommendation.
- **The dock badge is not the icon's fault.** The document names the placeholder
  icon as the leading suspect for `NSApp.dockTile.badgeLabel` doing nothing and
  says to re-test once a real icon ships. Tested: the Dock renders the new icon,
  and a fixed `badgeLabel = "9"` set at launch still produces no badge. The
  window title stays the primary carrier rather than becoming a fallback. See
  `Sources/AttentionNotifier.swift`. v2 §07 repeats the original instruction,
  unaware of the test.

The tab grammar shows `:branch` only when the branch is not the repository's
default, and "default" is now an answer from git rather than a name test.
`GitWorkspace.DefaultBranchResolver` reads `refs/remotes/*/HEAD` with one
`for-each-ref` on the first poll of a repository and remembers it, so a poll
still spawns exactly one git process. The `main`-or-`master` name test survives
only as the fallback for a repository where no remote has ever said what its
default is, which is every local-only one. The resolution order and what each
step costs are in that type's doc comment.

## What was implemented from v2

On 2026-07-26, on branch `design-v2`. Six of the seven divergences found on the
`main` check, plus a seventh the check missed. §08 landed last, once the live
comparison it was waiting on had been made.

1. **§01 `plank` is a theme role.** `foreground.blended(background, 0.46)` =
   `#6e6e6e` on `PaneTheme`, used for the PIN chip's border. The icon still
   hardcodes the hex, because it is drawn by a standalone script that cannot
   import `PaneChrome`; `plankIsOneDerivationDoingTwoJobs` is what keeps the two
   in step. The chip keeps its fill-relative derivation on a *filled* bar: a flat
   derivation off the theme scored 1.85:1 over `alert`, which is the bug that
   blend was written to fix.
2. **§01 `midnight`, and `focusAccent` reaching the screen at all.**
   `ansi[4].blended(ansi[5], 0.5)` = `#aa55ff`, repaired to clear 4.5:1 on the
   bar. The larger half was that the key was inert, described above. Resolution
   now happens inside `PaneTheme+Palette.swift`'s initializer rather than in the
   app target, so there is no assignment for a caller to forget, and
   `theConfiguredFocusAccentReachesTheTheme` is the test that would have caught
   the original bug.
3. **§02 the footer is the frame.** A 2 pt inset stroke around the focused
   pane's footer bar in `inkFocus`, the bar's fill identical in both states,
   collapsing to a top-and-bottom bracket below `frameCollapseWidth = 120`. Faded
   over 160 ms. Gated on `isWindowActive`. On a bar filled for attention the
   stroke is drawn in `theme.ink(on:)`, the same colour the anchor name takes
   there, because `inkFocus` is repaired against `barBackground` and scores
   2.08:1 on `alert`. It shipped first as a fourth `FocusStyle` case, so that it
   could be compared against the scrim in the running app; see 7 below.
4. **§03 the attention frame takes the pane.** A 2 pt inset frame in `alert`
   around the whole pane while an ask is unacknowledged and `attentionStyle` is
   `loud`, ranked above focus. `AttentionStyle.loud`'s doc has described this
   since v1; nothing drew it until now.
5. **§06 the divider drags in `ink.focus`**, replacing `PaneTheme.edgeFocus`,
   which 7 below then deleted, so the drag reads as part of the focus signal
   rather than as a third colour.
6. **§07 the icon glyph moves to the upper third.** Chevron
   `471,287 → 559,375 → 471,463`, ink baseline 483, cursor at `623,427`, with the
   heavy variant at stroke 72 and gap 48.
7. **§08 deletes `focusStyle`.** The footer frame was compared against the
   shipped scrim on six panes at 1680 pt on 2026-07-26 and won, which is the one
   way that argument could be settled, so the deletion landed the same day. Gone:
   `FocusStyle` and all four cases, `focusStyle`, `unfocusedScrim`,
   `Settings.Limits.scrim`, `Settings.resolvedAttentionStyle`,
   `PaneTheme.unfocusedScrim` and `PaneTheme.edgeFocus`. The config file is 19
   keys, `focusAccent` and `attentionStyle` being the two the design pass left.

   `PaneScrimView` and `PaneTheme.inactiveScrim` survive, and are not what §08 is
   about: every pane recedes by 0.15 while its *window* is not key, so an inactive
   window reads as one recessed object. macOS offers no other honest signal there,
   because the titlebar is transparent. `PaneEdgeFrameView` survives too and is
   now attention-only, which is its whole reason to exist.

   **A config file written before this needs two lines deleted by hand.**
   `focusStyle` and `unfocusedScrim` are now reported as unknown keys on stderr
   at every launch until they are removed. They are deliberately not accepted and
   ignored: a key that stopped applying has to be visible, which is what
   `unknownKeys` exists for, and swallowing one quietly is exactly how
   `focusAccent` came to sit dead for nine days.

## Still open

- **§07's badge instruction, deliberately not followed.** v2 says to re-test
  `NSApp.dockTile.badgeLabel` once a real icon ships. That test was already run
  on 2026-07-25 against the real icon, with an unconditional `badgeLabel = "9"`
  set at launch, and no badge appeared. v2 repeats the v1 instruction unaware of
  the result. See `Sources/AttentionNotifier.swift`.

**One thing this pass established about the documents themselves:** the design
prose runs ahead of the code. `AttentionStyle.loud` documented a whole-pane alert
frame that did not exist for nine days, and the `focusAccent` claim above was
wrong in the same direction. A statement in v1, v2, or a doc comment derived from
them is a statement about the design, not evidence about the build.

Everything else in v2 matched before this pass and still does: the foundations
table, the two-level attention model with its 510 ms one-shot opacity pulse and
reduce-motion skip, the window-title formats, the tab grammar and its width
ladder, the four footer tiers on baseline 15, and the divider at 1 pt with a
±3.5 pt hit area through `additionalEffectiveRectOfDivider`. The tab-grammar
approximation noted above is unchanged.
