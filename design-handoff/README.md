# Design handoff

Three documents, all pulled down from the Claude Design project **Baia Terminal
UI Design** (`6ee431e0-e6f9-44f0-98fe-315e845e9077`). Each is a **design
reference authored in HTML**, not code to port: recreations of the app captures
at 1 pt = 1 px, with each proposed treatment rendered on the real window beside
its values. The implementation target was AppKit, and it landed in `Sources/`
and `Packages/PaneChrome/`.

| File | Pulled | What it is |
|---|---|---|
| `Baia Design Pass.dc.html` | 2026-07-25 | v1, the pane chrome. Every option, with the arguments for each |
| `Baia Design Pass v2.dc.html` | 2026-07-26 | v2, the same subject, "decisions only". One treatment per problem |
| `Baia Sidebar Design Pass.dc.html` | 2026-07-29 | v3, the workspace sidebar. Nothing to do with v1 and v2 except where they touch |
| `Baia Sidebar Design Pass.md` | 2026-07-29 | v3 as markdown, the same document's own handoff notes. **The implementable form**: every constant, ready to type |

v2 carries v1's nine sections, retitled. It drops the alternatives and picks
a winner in each, so v1 stays as the record if an argument needs reopening.
Most of v2 ratifies what shipped from v1; the five places it does not are listed
below.

v3 is a different subject, the sidebar that shipped 2026-07-27. It answers the
brief in `vault/projects/baia/2026-07-29-design-v3-prompt.md`, and none of it is
implemented. Where the two subjects touch, the footer's tier-1 treatment, the
accent, the hairline vocabulary, v3 follows v2. Its markdown twin is vendored
alongside it because the values in it are meant to be typed into Swift, and a
document that has to be served to be read is a poor place to keep them.

## Reading it

The copies here are the documents only. Each imports a React runtime
(`support.js`, 70 KB, generated) and a web design system (`_ds/`, the
Nothing-inspired token and component library), and neither is vendored: a Swift
repository should not carry 200 KB of web assets to render one document, and
both are upstream files nobody here would edit.

So **read them in the Claude Design project**, where they render complete. The
local copies are for diffing against what was implemented, and for surviving the
project being changed or deleted.

The project also holds a self-contained bundle per document that renders offline
with everything inlined: `design_handoff_baia_chrome/baia-design-pass-v2-standalone.html`
at 254 KB, and `design_handoff_baia_sidebar/baia-sidebar-design-pass-standalone.html`
at 425 KB. Neither is vendored here, for the same reason `_ds/` is not. Pull one
down if you need to read a document without the project.

v3 is the exception worth knowing about: its markdown twin, `Baia Sidebar Design
Pass.md`, carries the whole specification in text, including the token block, so
the bundle is only needed to see the recreations rather than to implement them.

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

## What v3 asks for, and what it found

Its own suggested order is at the end of `Baia Sidebar Design Pass.md`, and step 1
of it shipped the day it arrived; see below. The eight decisions are the material
of the column (the terminal's own, not the panel's), per-column `XY` colour, a
truncation ladder that elides the directory, a heading carrying a count and the
anchor name, indent guides and trailing per-file status in the tree, five row
states now that rows act, square flush edges, and no trailing-edge sidebar.

Its one "still unverified" item is answered. `AppDelegate.toggleSurfacePanels`
cycles `changes → files → both → off` and reopens from `off`, so `off` is in the
cycle and the brief's claim holds.

## What was implemented from v3

Step 1 of its suggested order, on 2026-07-29. Three of the five §8 corrections,
which are the whole of what that step covers.

1. **§3 and §8/01, the path ladder.** `PaneChrome.RowPath` fits a path to a
   character budget by eliding the directory and never the name: the whole path,
   then the first directory with `…` and as many trailing ones as fit, then `…/`
   alone, then the name, and at the floor the stem tail-elided with its extension
   kept. Twelve tests, including one that walks every budget from 0 to 60 across
   seven paths and asserts nothing ever exceeds what it was given. The row draws
   with `draw(at:)`, so there is no rect left to wrap in.

   The wrap itself was found independently the same day and first fixed with
   `.byTruncatingHead`, which §3 rejects for spending the width on the directory
   and the name together. That fix is gone; the ladder replaces it.

2. **§8/02, one baseline.** Both strings in a changes row now draw from
   `rowBaseline - font.ascender`, the idiom `PaneStatusBarView` already uses with
   `PaneStatusBarMetrics.baselineFromTop`. The marker used to draw at `y + 3` and
   the path at `y + 1`, both top-origin in a flipped view, so it sat 2 pt below
   the path it labelled.

3. **§8/03, one inset.** `FileTreeRowsView` read 10 against everything else's 12
   and placed its text by its own constant. It now reads `ChangesRowsView`'s
   metrics, so a row in either surface sits at the same inset on the same
   baseline when the two are stacked.

**One correction to the document, from measuring rather than reading.** Every
width budget in v3 is derived from a 6.62 pt advance for
`monospacedSystemFont(ofSize: 11, weight: .regular)`. The font reports 6.7998 pt
on macOS 27, so the real budget at 260 pt is 30 characters rather than 31, and
`Sources/Workspace/Divider.swift` at 31 elides where the document's table says it
fits. `RowPath`'s caller measures the advance instead of hardcoding it, so the
budget follows the font, but v3's character counts run about 3 percent
optimistic wherever they are quoted.

Steps 2 through 8 are not started.

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
