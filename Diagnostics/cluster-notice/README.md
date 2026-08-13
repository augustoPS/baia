# Capsule notice

`./run.sh` from anywhere. Three arms — `draws`, `bare-shell`, `legible` — each
over two backdrops, each followed by its inverted control; exits non-zero if any
arm misses its floor, if any control loses its teeth, or if a measured fill band
stops matching the composite prediction. Needs only `swiftc`; no app build, no
capture, no `python3`.

**Safe from anywhere, including inside a baia pane.** The probe opens no window,
takes no focus, launches nothing and quits nothing: every arm renders the shipped
`PaneClusterView` offscreen through `cacheDisplay(in:to:)` and reads the bytes
back, the `cluster-wires` arrangement. It is in `guard-baia-alive.sh`'s
`SAFE_PROBES` on `cluster-legibility`'s ground, with a check in `guard-test.sh`
pinning that.

## The question

Does the capsule actually **draw** a refusal notice — ink on the pill, not just a
segment in a solved layout — and does that ink clear the same contrast floor
every other capsule text clears?

## Why it exists (the honest version)

On 2026-08-13 the three-second refusal notice was rehomed from the retired footer
onto the per-pane top-right capsule pill. The whole package suite passed with
zero failures — reported as 1891 tests at the time, 1879 when this probe was
written, the drift being tests added and removed since. Three existing probes
passed. The notice did not render in the running app.

Pixel measurement is what caught it: the capsule band stayed a uniform `#171717`,
brightest luminance 0.318, across the notice's entire life.

**The root cause was upstream of the capsule entirely.**
`AppDelegate.sendToPrompt` guarded on `anchor?.kind == .repository` and returned
*before* `PromptPath.resolve` ran, so `showNotice` was never called on a
non-repository pane and the view was never handed a notice to draw. The row still
flashed red — that comes off the `false` return in `FilesSurface.mouseUp`, not
off the refusal reason — so the refusal *looked* like it had run. The defect
presented as "the capsule will not draw a notice"; the capsule was never asked.

The fix split the predicate in `Packages/ProjectAnchor/Sources/ProjectAnchor/Anchor.swift`:

- `Anchor.promptRoot(of:)` — a repository only. What may be **sent**. (The owner
  ruled bare shell panes stay send-inert.)
- `Anchor.refusalRoot(of:)` — any anchor with a root. What may be **resolved**, so
  an impossible name can still name itself.

`sendToPrompt` now resolves against `refusalRoot` and asks `promptRoot` only in
the `.send` arm.

**The gap this probe closes is the other half: nobody had watched the shipped
build draw the sentence.** One measurement of luminance 0.318 → 0.825 with the
text legible exists, and it is single-sourced. Four hand-driven verification
attempts failed on harness flakiness — expired automation sessions, stale
`screencapture -l` buffers, tree row-order changes moving the target row — rather
than on code, so the pixel claim was never reproduced. This probe reads the
capsule band deterministically and settles it repeatably.

## What this probe does *not* cover, and why

**The `promptRoot` / `refusalRoot` split is not an arm here, deliberately.** It
belongs in the package tests and is already there:
`AnchorTests.aPlainAnchorCanExplainARefusalWithoutBecomingSendable` asserts a
`.plain` anchor answers `refusalRoot` with its url and answers nil to
`promptRoot` — the pair, in opposite directions, which is the ruling — and
`aRepositoryAnchorAnswersBothRootsAndNoAnchorAnswersNeither` covers the rest.
Verified failing against a widened `promptRoot`.

CLAUDE.md's rule decides this: *package tests answer anything decidable without an
`NSWindow` or a descriptor; a probe is for what needs a real window, surface,
shell, socket, or human eye.* The predicate is two pure functions over a struct.
Duplicating it in a probe would put a second copy of the contract somewhere no
`make test` reaches, which is the shape `build-packages.sh` exists because of —
seven copies of one fact, six of them stale and none of them noticed. The claim
this probe *cannot* make from a package test is the drawn one, and that is all it
makes.

## Method

**The harness is `cluster-legibility`'s.** The shipped `PaneClusterView` is
compiled verbatim — not sliced, not retyped — alongside `PaneOverlayView` and
`WindowCorner`, and rendered offscreen through `cacheDisplay(in:to:)`. The pill's
paint is plain translucent `NSColor` (a backing of `theme.background` at
`ChromeMaterials.PaneWash.floor`, then the material fill), never an
`NSGlassEffectView`, so the offscreen render is the full drawing route: nothing a
compositor would add is missing, and every number below is deterministic and
pinned exact.

**One structural difference from `cluster-legibility`, and it is load-bearing.**
The capsule is rendered inside a pane-sized superview (900 × 120 pt) and pinned
top-trailing at `PaneClusterMetrics.cornerInset`, rather than sized to itself at
the origin. The notice is the one segment measured against a budget, and
`PaneClusterView.noticeText` reads that budget off `superview?.bounds.width` — a
capsule with no superview passes the sentence through unbudgeted, which is the
pre-installation case, not the drawn one. For the same reason the view is
installed *first* and given its segments *second*: `remeasure()` runs from the
`segments` setter, and a capsule fed before it has a pane measures the sentence
against no budget and never re-measures.

**The fixture sentence is a real refusal**, `PromptPath.Refusal.notUTF8`'s own
`notice` text (`name is not valid UTF-8, so the shell cannot hold it: rename the
file`) — the longest of the three the resolver produces, and therefore the one
that exercises the budget. Copied into the probe rather than linked, because
`PanePrompt` would join the link line to supply one string; a change there is
findable from this paragraph.

**The statuses go through `PaneClusterSegments.build`**, not hand-listed roles, so
the probe cannot disagree with the shipped derivation about what a status
produces.

**Grading is `pane-glass-legibility`'s, inherited through `cluster-legibility`.**
Ink is the brightest pixel in a band (the fully-covered glyph core; antialiased
edges lose by construction), clamped to the middle 40% of the pill's height so a
focused pill's 2 pt `inkFocus` stroke cannot pose as glyph ink, and inset by
`horizontalInset` so the pill's antialiased semicircular ends cannot either. The
fill band is read from the pill's trailing inset — inside the shape, outside every
glyph, since a notice is placed at `horizontalInset` from the leading edge and cut
to fit. Every band is checked against the composite its own layers predict, so a
probe reading the wrong pixel fails rather than reports a contrast.

**Two backdrops per arm**, `cluster-legibility`'s pair cited rather than
reinvented: the dark document colour `PaneTheme.darkPastel.background` `#141414`,
and the bright bound `#7c7c7c` — `glass-backdrop` finding 6b's brightest measured
backdrop, which is also what `PaneClusterInk.worstFace` grades against.

## The thresholds, and where they come from

| grade | floor | source |
|---|---|---|
| legibility | 4.5:1 | `PaneTheme.minimumTextContrast`, read off the package |
| presence | 1.5:1 | a literal in this probe; see below |

**No threshold here is derived from the arm it grades**, which this repo has been
burned by four times. The legibility floor is the package's own constant, the same
one `cluster-legibility` grades its resting, focused and offer arms against — the
notice is capsule text and is held to the standard capsule text is held to.

The presence floor is a fixed 1.5:1 and is deliberately far *below* the legibility
floor, because `draws` asks a different question: not "can the sentence be read"
but "was anything painted at all". The live defect answered that with a uniform
band at 1.00:1. A presence threshold set at the legibility floor would make
`draws` a duplicate of `legible` and would fail for a notice rendering perfectly
well in a low-contrast theme. Its teeth come from the control, not from its
height.

## The arms

### `draws`

Hands the capsule a `PaneStatus` carrying a notice, renders it, and asserts the
pill has the sentence painted across it. **The arm that would have caught the
original defect had the notice reached the view.**

Control: the same capsule with `notice = nil`.

**The first shape of this control was toothless, and the toothless shape is the
obvious one.** A resting pill is not blank — it wears branch, markers, agent and
dot in bright `theme.foreground` — so "is there ink brighter than the fill" passes
on a resting pill at 9.62:1. Measured, not reasoned about: the control passed on
this file's first run. So the arm asserts the ink at the sentence's far end is
`PaneClusterInk.noticeInk`'s own answer (`#ff9090` at the shipped theme), which
the resting grey `#bbbbbb` is not. That colour check is what the control fails on.

A second intention did *not* survive measurement and the code says so: the tail
rect was meant to lie past a resting pill's trailing end entirely, and it does
not. Both pills are pinned at the same trailing edge, so a 141 pt resting pill and
a 485 pt notice pill overlap across the resting pill's whole width. The tail is
still the right place to sample — it is where a sentence cut short or never drawn
leaves nothing — but the geometry contributes nothing to the control.

### `bare-shell`

The specific case that broke. A pane with **no** resting segments — no branch, no
markers, no agent, no attention — must still produce a visible capsule when handed
a notice.

`PaneClusterSegmentsTests.aNoticeGivesABareShellPaneACapsule` covers the pure
layer, asserting `build` answers `[]` at rest and `[.notice]` under a notice. This
arm covers the drawn result of the same two states, because a segment in a solved
layout is not a pixel and the whole reason this probe exists is that the two were
confused for one another once already.

Control: bare shell with no notice, which must render nothing visible —
`pillWidth` answers zero for an empty placement and `remeasure()` hides the view.
The control fails on the visibility check before any ink is looked for, and its
output shows the pill at 0 × 20 pt with the band reading the raw backdrop.

### `legible`

The notice ink must clear the same floor other capsule text does.
`PaneClusterInk.noticeInk(theme:chrome:)` is the derivation under test — the
repair chain walking `theme.alert` up to the floor over the pill's worst face.

Both focus tiers are graded. `noticeInk` grades itself against `fillChrome` on the
argument that the resting fill is the worse of the two over a bright backdrop;
this arm renders the pill wearing each fill in turn rather than taking that
argument on trust. The measured numbers below confirm it (`fillChrome` 5.52:1
against `fillThick` 5.75:1 at the bright bound).

Control: the graded ink set to the pill's own composited face. **Damaging the
theme would not work here**, and the reason is the one `cluster-legibility`'s
offer arms hit: `noticeInk` goes through `PaneTheme.color(for:focused:on:)`, whose
last resort is the best of the stated colour, white and black, so no `theme.alert`
handed in survives as an unreadable one — the repair would rescue the control and
the arm would pass broken. So the control damages the graded *pixel*, downstream
of the repair. Everything under it — theme, render, band sampling, the grade — is
the arm's own, so a probe reading the wrong pixels still fails there.

## The numbers, 2026-08-13

Deterministic. A changed byte is a changed feature.

| arm | fill | backdrop | band | ink | ratio |
|---|---|---|---|---|---|
| draws | fillChrome | `#141414` | `#141415` | `#ff9090` | 8.47:1 |
| draws | fillChrome | `#7c7c7c` | `#363638` | `#ff9090` | 5.52:1 |
| bare-shell | fillChrome | `#141414` | `#141415` | `#ff9090` | 8.47:1 |
| bare-shell | fillChrome | `#7c7c7c` | `#363638` | `#ff9090` | 5.52:1 |
| legible | fillChrome | `#141414` | `#141415` | `#ff9090` | 8.47:1 |
| legible | fillChrome | `#7c7c7c` | `#363638` | `#ff9090` | 5.52:1 |
| legible | fillThick | `#141414` | `#151718` | `#ff9090` | 8.26:1 |
| legible | fillThick | `#7c7c7c` | `#323435` | `#ff9090` | 5.75:1 |

The notice pill measures 485 pt wide at this sentence and pane width; the resting
pill measures 141 pt. `noticeInk` answers `#ff9191` and the drawn glyph core reads
`#ff9090`, one byte apart on two channels — antialiasing against a dark fill, the
±2 byte tolerance `cluster-legibility` uses for the same comparison.

**The lowest reading in the table is 5.52:1, against a 4.5:1 floor.** The notice
clears legibility on both fills over both backdrops, with the worst case on the
resting fill over the bright bound — exactly the case `PaneClusterInk.worstFace`
predicts is worst, which is the argument for grading there confirmed rather than
assumed.

## Reproducing the original defect

Revert `sendToPrompt`'s resolve guard to `kind == .repository` and the app stops
calling `showNotice` on a plain-anchor pane. **This probe still passes**, and that
is correct rather than a hole: it grades the view given a notice, and the reverted
defect is that the view is never given one. `AnchorTests` is what fails there, and
it is verified to. The two halves of the fix are pinned in the two places that can
see them — which is the lesson the whole episode taught, and the reason this probe
does not try to own both.
