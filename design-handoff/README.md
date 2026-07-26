# Design handoff, 2026-07-25

`Baia Design Pass.dc.html` is the visual design pass over baia's shell, pulled
down from the Claude Design project **Baia Terminal UI Design**
(`6ee431e0-e6f9-44f0-98fe-315e845e9077`). It is a **design reference authored in
HTML**, not code to port: recreations of the six app captures at 1 pt = 1 px,
with each proposed treatment rendered on the real window beside its values. The
implementation target was AppKit, and it landed in `Sources/` and
`Packages/PaneChrome/`.

## Reading it

The copy here is the document only. It imports a React runtime (`support.js`,
70 KB, generated) and a web design system (`_ds/`, the Nothing-inspired token
and component library), and neither is vendored: a Swift repository should not
carry 200 KB of web assets to render one document, and both are upstream files
nobody here would edit.

So **read it in the Claude Design project**, where it renders complete. The local
copy is for diffing against what was implemented, and for surviving the project
being changed or deleted.

The six source captures it was built from live in `../design-captures/`, which is
gitignored for the images and tracked for `capture.sh` that regenerates them.

## What was implemented

Everything in the document except where noted, on 2026-07-25:

- The focused-pane treatment, all three styles (`recede` is the default)
- The two-level attention model, both volumes, with the arrival pulse
- The tab grammar and the window-title formats
- The four footer tiers, the coloured markers, the pin chip
- The themed split divider
- The app icon, direction C (SEAM) with the drawn `>_` glyph

Two things the document leaves open that are now answered:

- **`focusAccent` stays `accent`.** The document recommends `bone` and
  deliberately defaults to `accent`; the default was kept, and all four
  derivations exist behind the config key.
- **The dock badge is not the icon's fault.** The document names the placeholder
  icon as the leading suspect for `NSApp.dockTile.badgeLabel` doing nothing and
  says to re-test once a real icon ships. Tested: the Dock renders the new icon,
  and a fixed `badgeLabel = "9"` set at launch still produces no badge. The
  window title stays the primary carrier rather than becoming a fallback. See
  `Sources/AttentionNotifier.swift`.

One approximation worth knowing about: the tab grammar shows `:branch` only when
the branch is not the repository's default, and "default" is a name test for
`main` or `master` rather than an answer from git. `GitWorkspace` does not
collect the real default branch today. The predicate is
`TerminalPaneController.isConventionalDefaultBranch`, so replacing it is a change
to one function.
