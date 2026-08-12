# cluster-wires

**The question.** Do the pane capsule's draw wires carry — the
`chrome.cluster.opacity` dial to the pill fill, the focus expression to the
`fillThick` step and the stroke, the window-active gate over both — and does an
undialled cluster group leave the rendering exactly where it was?

**What would be false if this probe passed and the code were wrong.** Nothing
this probe asserts can hold while the opacity dial reaches no pixel, reaches the
wrong pixels (the ornaments instead of the fill), or moves the rendering at its
nil default; nor while the focus step is absent, is only the stroke, or ignores
the window's active state. Each arm compares two renderings of the *shipped*
`PaneClusterView`, compiled verbatim with its own `PaneOverlayView` superclass,
so a wire that had drifted would show up as a rendering that failed to move or a
default that moved on its own.

The probe renders `PaneClusterView` directly with hand-fed segments; it does not
need the app running, and no capsule ever has to be dialled on in a live pane
for it to measure anything.

## Run it

```
./run.sh
```

**Safe from anywhere, including inside a baia pane.** No window is opened, no
focus is taken, nothing is launched and nothing is quit. Every arm renders the
capsule offscreen into an `NSBitmapImageRep` through `cacheDisplay(in:to:)` and
reads the bytes back — `override-wires`' class, and its reasoning wholesale:
the question is what this app's own drawing code puts down, which the process
decides on its own, so offscreen is the stronger measurement, deterministic and
machine independent. Byte equality rather than a tolerance, for that file's
reason too.

## The arms

Each is followed by an inverted negative control. `run.sh` fails if a control
stops failing, which is what stops an arm that has quietly become a tautology
from reading as evidence.

| arm | what it says |
|---|---|
| `nil-cluster` | A capsule never assigned `fillOpacity` renders the same bytes as one handed `DesignOverrides().chrome.cluster.opacity` — the explicitly-nil group, applied the way `ConfigurationCenter.apply(to:)` applies it. Checked under flat and glass both. This is the byte-stability half of the dial's contract: the panel's mere existence moves nothing. Since 2026-08-12 the arm also asserts `Cluster.resolvedMode` at nil is `.cluster`, because the baseline it renders became the shipped chrome (see below) |
| `opacity` | `0.35` moves the rendering under flat and glass, moves more than 200 pixels (a surface, not an edge — the fill is the whole pill), and leaves the attention dot's centre pixel carrying its own ink. That last check is the "fill only" clause of the dial's doc measured at the one ornament pixel whose coverage is total; glyph edges antialias against the fill, so text pixels are deliberately not asserted |
| `focus` | Focused and unfocused render differently under glass, and a *fill-only* pixel (mid-gap between segments, clear of the inset stroke and every glyph) moved — so the `fillChrome` → `fillThick` step exists as a fill step, not just as the stroke appearing. Then the gate: focused-but-deactivated renders byte-identically to unfocused, `framesForFocus`' conjunction measured directly, since offscreen `isWindowActive` is a plain property with no window feeding it |

## What this probe does not measure, and why

**`chrome.cluster.cornerInset` has no arm, because it is a constraint knob, not
a draw knob.** The dial lands in `TerminalPaneController.clusterCornerInset`,
whose `didSet` rewrites `clusterEdgeConstraints[].constant`, and those
constraints exist only when the install path has pinned the capsule into a live
pane — `TerminalPaneController` reaches the whole app target, so there is
nothing here to compile and no offscreen rendering in which the pill's *position
in a pane* is a pixel. The arithmetic under the dial
(`clusterCornerInset ?? PaneClusterMetrics.cornerInset`) is one `??` read by
both the install path and the live re-pin. What covers it instead: the
`cluster-card-key` probe stands a real window with a capsule pinned at the
shipped inset (its first-mouse arm clicks what the pinning placed), and the look
of a dialled inset is owed to the owner's eye through the panel — recorded as
owed rather than claimed, the same entry `override-wires` keeps for its surface
fills. This probe deliberately covers draw wires only.

**`chrome.cluster.mode` has no arm for the same reason, stated so its absence
reads as a decision.** The gate is `TerminalPaneController.applyClusterMode()`:
`.footer` never adds the capsule to the hierarchy, `.cluster` installs it and
hides the footer, `.both` shows both. Installation is a fact about a pane's view
tree, not about the capsule's own `draw(_:)`, so it lives behind the same
app-target wall as the inset. The absence claim `.footer` makes — no
extra view, nothing the compositor could touch — is a hierarchy claim asserted
in the controller's own doc, not a rendering this probe could compare.

**The default flipped on 2026-08-12.** Undialled `chrome.cluster.mode` resolved
to `.footer` when this probe was written; it now resolves to `.cluster`
(`Cluster.resolvedMode` in BaiaSettings, the one resolution site). Undialled
still means what ships, and what ships changed by design: the capsule on, the
footer hidden. The `nil-cluster` arm re-baselined with the flip, which cost it
nothing pixel-wise (it always rendered the capsule directly) and gained it the
resolution assertion above; `.footer` and `.both` stay dialable, so the
pre-flip rendering remains reachable from the panel for comparison.

**The segments' text and placement are not re-tested here.** `PaneClusterLayout`
and `PaneClusterSegments` are package code with their own suites
(`PaneClusterLayoutTests`, `PaneClusterSegmentsTests`); a probe arm restating a
package test would be a second copy free to drift from the first. This probe
does recompute the placement with the view's own font — but to *find* single
pixels (the dot's centre, a fill-only gap), not to assert where segments sit.

## Related

- `override-wires/` is the pattern this probe follows, and carries the full
  argument for offscreen-over-capture and for byte equality.
- `cluster-card-key/` is the other half of the capsule's diagnostics: the cards'
  key-return contract on a real window, which this probe's no-window discipline
  cannot reach. It takes key on purpose and stays out of SAFE_PROBES.
- `PaneClusterLayoutTests` / `PaneClusterSegmentsTests` in `PaneChrome` own
  everything decidable without a view.
