# Titlebar merge probe

`./run.sh [output-directory]` from anywhere. Writes four captures, an `-backing.png`
companion and a `backdrop-check-*.png` strip for each, and a strip measurement;
exits non-zero if a capture fails, if a glass arm never samples its backdrop, or if
**any arm's controlled backdrop was displaced** — the last naming the arm and
refusing to publish a number for it.

## The question

The window wears two separate `NSGlassEffectView` planes, and where the sidebar
column meets the titlebar band there is a visible seam. The owner wants one panel.

- **`TitlebarGlassBacking`** is parented into the window's **frame view**
  (`contentView.superview`), because the titlebar band sits above `contentView` and
  no public API hands it over. `Sources/WorkspaceWindowController.swift`,
  `applyTitlebarGlass()`.
- **`SidebarGlassBacking`** lives **inside `contentView`**, added below every
  sibling of the sidebar host's view. `Sources/SurfaceHosts.swift`,
  `applyResolvedChrome()`.

They sample separately, so the band and the column each compute their own answer for
"what is behind me" and meet at a step.

**The two planes are configured identically**, which is the first thing this probe
establishes and it is worth stating before any measurement: both are `.regular`,
both `cornerRadius = 0`, both untinted, both added `positioned: .below`. Read off the
app source rather than transcribed. So the seam is not a style mismatch that could be
tuned away — it is a *sampling-boundary* artifact, and only an arrangement change can
remove it.

## What would be false if this probe passed and the code were wrong

That a seam between two adjacent glass planes is visible in a screen capture at all,
and that the arrangement each arm claims to build is the arrangement it actually got
on screen. A probe that only printed numbers would answer neither, and during
development this one was wrong about both in ways only the captures caught:

- **Arms were measured over the desktop rather than over the controlled backdrop**,
  with the owner's own terminal text legible through the glass. The window was
  compositing over whatever else was on screen, so the "seam" number was a
  photograph of it. **This was named here as a known failure mode and left open for
  one revision, and it invalidated every absolute number the probe published in that
  time** — two runs minutes apart on one machine measured arm 1 at 38.00 and at
  1.26, and the second run's captures show the terminal through the glass in *all
  four* arms, not only arm 1. Re-asserting the backdrop before every capture, which
  is what the previous revision did, cannot fix it: see "how the backdrop is
  guaranteed" for why the cause was the window *level* and what closed it.
- **Arm 2 was graded `SEAM` at 113 while its capture visibly merged.** The strip was
  reading a row well above where its planes abut, because the boundary was derived
  from the window frame (`(frame.height - contentLayoutRect.height) / frame.height`)
  and that fraction is not where these particular planes meet. Each arm now reports
  the y it actually built to.
- **Arm 2 lost the titlebar band entirely** in its first honest form: a bare strip of
  backdrop where the band should be and no traffic lights, because the container
  needs both planes in `contentView` and an unextended content view has no band
  region to put one in. That is now a *finding* (see the verdict) rather than a bug.
- **The geometry was built against the requested `contentRect`, not the live content
  view.** `NSWindow(contentRect:)` grows the content view when a toolbar is added — a
  380 pt request measured 438 pt — so the column stopped 58 pt short of the band and
  left a white gap the strip read as a step. The content view is also unflipped, so
  frames written in flipped terms anchored to the wrong edge. Both were visible
  instantly in the capture and invisible in the numbers.

So: **the captures are the check on the numbers.** Look at them before quoting a
figure from this README.

## The arms

Four renderings of the same window: a real `.titled` window with an empty
`NSToolbar` at `.unifiedCompact` (which is what gives the band its 40 pt metric and
its material, as `WorkspaceWindowController` documents), a titlebar band, and a
260 pt column at `SidebarGeometry.default.width` read off `WorkspaceLayout` at run
time rather than transcribed.

| Arm | Band plane | Column plane | Hierarchy |
|---|---|---|---|
| 1 `1-shipped-two-planes` | frame view | `contentView` | **two**, as shipped |
| 2 `2-container-merged` | `contentView`, in a container | `contentView`, same container | one |
| 3 `3-fullsize-one-plane` | one plane spans both | same plane | one |
| 4 `4-flat-control` | system slab | flat fill | n/a |

Arm 4 is not a candidate. It is the control that says how much of any difference
between the others is glass rather than layout.

### What arm 2 measures, and what it does not

**The honest arrangement — a container holding both planes while each stays in the
hierarchy it ships in — is structurally impossible, and that is the answer to the
question the brief flagged as unknown.** `NSGlassEffectContainerView` merges the
glass views that are its **subviews**, and a view has exactly one superview. A plane
in the frame view and a plane in `contentView` cannot both be subviews of one
container without one of them leaving its hierarchy, at which point it is no longer
where the app puts it. There is no API that merges across the split.

So arm 2 is built the second way: **both planes in ONE hierarchy, inside one
container**. It measures **the merge itself**, and says nothing about the app's
ability to reach that arrangement from where it stands today. What the app would have
to change is in the verdict.

### What arm 3 does and does not re-open

`WorkspaceWindowController` records that `.fullSizeContentView` was tried on this
window and measured **not** to fix a *different* glass problem: the titlebar material
was rendering as nothing over a `.clear` window background, the platform recipe of
extending content under the titlebar was the obvious hypothesis, and
`Diagnostics/titlebar-toolbar`'s arm measured that band at **spread 63.6 — the
bare-titlebar number**. The cause was the `.clear` background, not the content
extent, and the fix was a non-zero window background alpha.

**This arm does not re-open that.** It is not a claim that `.fullSizeContentView`
makes the titlebar material appear; the window here already carries the non-clear
background (`white 0.09, alpha 0.005`, the constant the app ships) that settled that
question. What it re-opens is the *cost* line: `applyTitlebarGlass()` rejects
parenting glass in the content view because reaching it needs `.fullSizeContentView`,
and the probe's `glass-in-content` arm measured `contentLayoutRect` dropping from 292
to 220 pt — which would resize every ghostty grid and `SIGWINCH` every running shell.
**That objection stands and this probe does not dispute it.** See the cost section.

Arm 3 also cannot be one view for the whole shape: an `NSGlassEffectView` is a
rectangle and band-plus-column is an L. What it builds is one plane covering the
column's full height including the band region — exactly the strip's path — plus a
separate plane for the band to the right of the column, where the strip never reads.
Down the strip there is one sampling shape and no boundary, which is the claim being
measured.

### The controlled backdrop

A full-screen window of pure white **above** pure black, with a mid-grey grid for a
human eye to compare structure through.

#### How the backdrop is guaranteed

**The cause was the backdrop window's level, and no amount of re-ordering could have
fixed it.** The backdrop sat at `.normal - 1`, copied from `glass-backdrop`. At that
level it loses to *every ordinary window on screen*, and `orderFrontRegardless()`
only orders a window to the front of its own level — so a `.normal - 1` backdrop can
never rise above a `.normal` terminal, however many times it is re-asserted.
`glass-backdrop` never hit this because its probe windows are `.borderless` and it
never competes for the same level.

Two mechanisms now close it, and the second is what makes recurrence impossible
rather than unlikely:

1. **Levels.** The backdrop is `.floating` (above every ordinary window) and the
   probe window one step above the backdrop. The stacking is a property of the
   levels rather than of what else happens to be on screen.
2. **A per-arm assertion.** Before each arm's capture, a strip down the screen's
   left edge — **outside the probe window's frame** — is captured and sampled in
   both halves. The white half must read bright, the black half dark, and the two
   must be at least 100 luminance units apart. An arm that fails prints
   `BACKDROP DISPLACED <arm>` with the measured values and **the run exits
   non-zero without publishing a number for it**.

Both, because the failure being guarded is exactly the kind that survived a README
paragraph describing it: glass samples whatever is behind it at capture time, and a
capture over the wrong thing still looks like glass.

**Proved rather than asserted.** A variant of the probe with only the two level
lines reverted was built and run against a deliberate full-screen `.normal`-level
intruder window:

```
BACKDROP DISPLACED 1-shipped-two-planes — white-half=71.0 black-half=71.0
BACKDROP DISPLACED 2-container-merged   — white-half=71.0 black-half=71.0
BACKDROP DISPLACED 3-fullsize-one-plane — white-half=71.0 black-half=71.0
BACKDROP DISPLACED 4-flat-control       — white-half=71.0 black-half=71.0
4 arm(s) did NOT pass the backdrop assertion.   exit 1
```

Equal mid-greys in both halves is the signature of the original defect, and it
matches the broken baseline's strip profiles (~70-80 across every arm). Against the
**same intruder**, the fixed probe passes all four assertions
(`white-half=255.0 black-half=0.0`) and measures the same numbers as an undisturbed
run. The level fix is what stops displacement; the assertion is what would catch it
if it ever returned.

**Split horizontally where `glass-backdrop` splits vertically, and the rotation is
the measurement.** That probe asked whether a 22 pt bar adapts to what is behind it,
so it needed the bar to cross a *vertical* seam left-to-right. This probe asks
whether two stacked planes step at their shared *horizontal* boundary, and a vertical
backdrop seam would put the same backdrop luminance above and below that boundary —
every arm would measure the same flat field and the probe would grade nothing.

The probe window sits **entirely within the white half**, so the strip reads one
constant backdrop luminance from top to bottom and any step it finds is the glass.
The backdrop's own seam is what proves the glass is sampling at all. White rather
than black because a seam between two planes is a difference in how much backdrop
each admits, and there is more to admit over white.

### How the captures are read

**`-R` is the measured file here, which is the opposite of `glass-backdrop`'s choice,
and the titlebar is the reason.** That probe measures borderless windows whose glass
composites into their own backing store, so `-l` sees the adaptation and avoids
`-R`'s display tone curve. These windows are `.titled` with a real toolbar: the band
is chrome the *window server* composites, and arm 1's frame-view glass sits under
material AppKit paints outside the content view's backing store. An `-l` file of arm 1
does not contain the band as an owner sees it, so it cannot answer whether the band
steps against the column. The `-l` file is still written as `<name>-backing.png` for
cross-checking.

The cost is the one `glass-backdrop` documents: `-R` carries the display's brightness
and EDR response at capture time, so **absolute values are not comparable between
runs or machines.** This probe's verdict is therefore built **only on within-run
comparisons** — every arm is captured in one run against one backdrop, and the
grading threshold is re-measured from that run's own noise floor rather than frozen
as a constant. It is derived from a boundary-free region, never from an arm under
test; see "the strip, and why the threshold is what it is".

### The strip, and why the threshold is what it is

For each arm, luminance is sampled down a vertical column of the capture at
x = 0.06 of the window width — inside the 260 pt column, left of every glyph the
column content draws, and left of the traffic lights' x range in the band above. Ink
inside the strip would read as a step that has nothing to do with the seam.

`boundaryStep` is the number the verdict rests on: the mean luminance in a band just
above where the two planes meet, minus the mean just below. A mean either side rather
than two single pixels, because a one-pixel read can land on the transition row and
report half the step.

**The threshold is `(noise floor + one 8-bit level) x 2`, which on this machine is
2.00. No arm contributes to it.**

#### The threshold that was replaced, and why it could not fail

The previous rule was `max(arm 1 x 0.10, 2.0)`, printed as "10% of arm 1's measured
seam". **Arm 1 defined the threshold it was then graded against, so its line read
MERGED whatever it measured.** The broken probe's own output is the demonstration:

```
grading threshold: 2.00 (10% of arm 1's measured seam 1.26, floored at 2.0)
1-shipped-two-planes   1.26  MERGED (defines threshold)
2-container-merged     6.67  SEAM
3-fullsize-one-plane   6.00  SEAM
```

The control passed and both candidates failed — the grading exactly inverted. Marking
arm 1's line `(defines threshold)` acknowledged the circularity without removing it.

#### The noise floor, measured

The honest question is what magnitude of `boundaryStep` this pipeline reports when
there is **no boundary at all**. That is measurable: apply the identical computation
— mean of a band above a row minus mean of a band below it, at the same 0.04
half-width the measurement uses — at rows *inside one continuous glass plane*, where
no arm puts an edge. Five positions down arm 1's own column, at y = 0.40, 0.50,
0.60, 0.70 and 0.80:

```
y=0.40:0.00  y=0.50:0.00  y=0.60:0.00  y=0.70:0.00  y=0.80:0.00
max 0.00, mean 0.00
```

**A measured 0.00 is this pipeline's real answer, not a failed read**, and the
captures say why: the glass blur is wide enough to dissolve even the backdrop's 1 pt
rulers, so the column reads one identical 8-bit value (141.0) at all 56 samples below
the boundary. `screencapture` is a lossless read of a composited buffer rather than a
photograph of a screen, so there is no sensor noise to find.

Getting to that number took one correction worth recording: the backdrop's rulers
were vertical only and started a quarter of the way across, so the strip ran down a
featureless field and the floor was measured over nothing. A floor measured over a
flat field does not bound a measurement read through structure. The backdrop now
carries a grid — vertical lines from x = 0 and horizontal lines every 19 pt — so the
floor is measured over the same character of region as the boundary it bounds. The
answer came back 0.00 anyway, which is the finding above.

#### From floor to threshold

Doubling a floor of 0.00 gives 0.00, which would grade on exact equality and fail an
arm for a single least-significant-bit difference. So the floor is added to the
pipeline's **resolution** limit before doubling. One 8-bit level is 1.0 luminance
unit on the 0-255 scale these numbers live on, and it is the smallest difference a
capture can represent at all — a step below it does not exist as a measurement.

```
(noise floor 0.00 + one 8-bit level 1.00) x 2 = 2.00
```

A step must be at least twice the pipeline's combined noise-and-resolution limit
before it counts as a boundary. **Neither input can be moved by any arm**: one comes
from a region with no boundary in it, the other from a property of 8-bit colour.
That is the whole difference from the rule it replaces, and it is why arm 1 is now
graded like every other arm rather than exempted.

The floor is still re-measured every run rather than frozen as a constant, which `-R`
requires: the display's tone response varies with brightness, so a floor measured
last week does not bound today's capture.

The flat control's step is still reported for scale and is still **not** an error
bar: it is a deliberate two-tone layout (a flat column fill meeting the system
titlebar slab), so it measures how big a step the geometry draws when nothing is
trying to hide it.

## Findings

Measured on this machine after both defects were fixed. Three consecutive runs,
every arm identical to the hundredth in all three, every arm's backdrop assertion
passing in all three. Absolute values are within-run only (see "how the captures are
read").

### 1. A correctly-backdropped arm 1 reads a LARGE seam: 34.33 luminance units.

**This is the headline, because the contingency was live.** If a control measured
over the right backdrop had read near zero, the visible edge the owner sees would not
be a glass-sampling discontinuity and the merge work would be aimed at the wrong
thing. It does not. Arm 1 measures 34.33 against a threshold of 2.00 — seventeen
times the bar — and the seam is plainly visible in
`arm-1-shipped-two-planes.png` without any measurement. **The merge work is aimed at
the right thing.**

Every arm, all three runs:

| Arm | run 1 | run 2 | run 3 | verdict |
|---|---|---|---|---|
| 1 shipped two planes | **34.33** | **34.33** | **34.33** | SEAM |
| 2 container merged | **0.00** | **0.00** | **0.00** | MERGED |
| 3 full-size one plane | **0.00** | **0.00** | **0.00** | MERGED |
| 4 flat control | 14.93 | 14.93 | 14.93 | — (two-tone layout, for scale) |

Threshold 2.00 in all three runs; noise floor 0.00 at all five positions in all
three. The three runs agree exactly, which is far inside the measured noise floor —
there is no run-to-run variation at all to be within.

**These numbers supersede the 38.00 / 26.93 pair this README previously carried.**
Those came from a run whose backdrop happened to survive, but over a backdrop with
only sparse vertical rulers; the grid backdrop the noise-floor work introduced
changes what the glass has to sample and therefore the absolute values. Both figures
moved, the conclusion did not.

Arm 1's step is **more than twice the flat control's** (34.33 against 14.93). That is
the sharpest form of the result: two glass planes meeting produce a much *bigger*
discontinuity than a flat column fill meeting the system titlebar slab. The seam is
not a subtle material artifact — it is the most visible boundary of the four arms.

Both merged arms measure **exactly 0.00**, not "small". Down the strip the luminance
either side of the boundary is identical, which is what one sampling shape means, and
both captures show one continuous panel.

### 2. Both merged arrangements need the same window-level change.

Arm 2's first honest form kept the shipped window style and put the container in
`contentView`. It captured with **no titlebar band at all**: a bare strip of backdrop
where the band should be, traffic lights gone with it. The container merges its own
subviews, so both planes have to be in `contentView`, and an unextended content view
stops below the titlebar and has no band region to put a plane in.

Adding `.fullSizeContentView` is what fixed it. So:

**The container route does not avoid `.fullSizeContentView`. It requires it, exactly
as the single-plane route does.** The two candidate arrangements have the same
precondition, and the choice between them is not a way around that cost.

### 3. Traffic lights survive every arm, and remain hit-testable.

Asked of AppKit after each window is built — visibility and alpha off the real
buttons, and `frameView.hitTest` at each button's own centre, which answers "does a
click here reach the button rather than something laid over it":

```
1-shipped-two-planes  close=visible,hit min=visible,hit zoom=visible,hit
2-container-merged    close=visible,hit min=visible,hit zoom=visible,hit
3-fullsize-one-plane  close=visible,hit min=visible,hit zoom=visible,hit
4-flat-control        close=visible,hit min=visible,hit zoom=visible,hit
```

All three buttons are present, visible and reachable in **all four arms**, including
both merged ones. They are also visible in every capture. This is the expected result
for arms 1 and 3 — the app's `TitlebarGlassBacking` overrides `hitTest` to return
`nil` precisely so it cannot swallow a window-close click, and the probe's glass
carries no such override yet still does not intercept, because both merged
arrangements put their glass *below* the buttons in z-order.

**What is measured and what is not, stated rather than implied:**

- **Measured**: the buttons exist, are unhidden, are at alpha 1, and a hit test at
  their centres reaches them rather than a glass view.
- **Not measured**: that a synthesised click actually closes the window. That needs a
  real CGEvent against a key window, and this probe takes no focus by construction.
- **Not measured**: window drag. `isMovableByWindowBackground` is reported (`false`,
  in every arm) but the titlebar's own drag region is AppKit's and is not routed
  through any view this probe adds. Nothing here suggests it moves, and nothing here
  proves it. **Confirm both by hand in the dev build before shipping either
  arrangement.**

### 4. The container's merge is genuine, not the strip missing it.

Verified independently of the strip, with a two-window side-by-side test: the same
band and column planes, once as plain siblings in `contentView` and once inside an
`NSGlassEffectContainerView` at `spacing = 0`. The plain pair shows a clear step at
the boundary; the container pair renders as one continuous L-shaped panel with the
band and column indistinguishable. Traffic lights present in both.

That matches `glass-backdrop`'s finding 5 on the capsule — `spacing = 0` keeps
adjacent shapes distinct while sharing one sampling pass — applied to two much larger
shapes, where the shared pass is exactly the point.

## Verdict

### Which arrangement gets the merge

**Both arm 2 and arm 3 merge completely (0.00 against a 34.33 seam). Prefer arm 2,
the `NSGlassEffectContainerView`.**

They measure identically down the strip, so the choice is made on what else they cost:

- **Arm 2 keeps the band and the column as two shapes** that the container merges.
  That is the API Apple provides for this, it survives the two shapes having
  different widths (which they do — the band spans the window, the column is 260 pt),
  and it extends to any further glass the window grows without re-cutting one
  rectangle.
- **Arm 3 needs one plane to cover both regions**, and since a view is a rectangle
  and the shape is an L, it can only do that by covering the column's full height and
  leaving the rest of the band to a second plane anyway. It merges down the column
  and re-introduces a boundary at the column's right edge, where this probe does not
  read. Arm 2 has no such untested edge.

### What the app must change, and what it costs

**One change, and it is the expensive one: the titlebar's glass has to leave the
frame view and move into `contentView`, which requires `.fullSizeContentView`.**

That is the answer to "which of the two hierarchies has to move": **the titlebar's.**
The sidebar's plane is already in `contentView` and does not move. Concretely:

1. `WorkspaceWindowController.applyTitlebarGlass()` stops parenting
   `TitlebarGlassBacking` into `contentView.superview` and stops needing the frame
   view at all — the `guard let frameView` and the whole "why the frame view" note
   retire with it.
2. The window gains `.fullSizeContentView` in its style mask.
3. `SidebarHost` gains an `NSGlassEffectContainerView` holding both planes, and the
   titlebar plane's frame becomes the content view's top `bandHeight` points.

**The cost is the one `applyTitlebarGlass()` already measured and rejected this
arrangement for, and this probe does not make it go away.** `.fullSizeContentView`
extends the content view under the titlebar, so `contentLayoutRect` changes and the
pane tree lays out against it: `Diagnostics/titlebar-toolbar`'s `glass-in-content` arm
measured it dropping from 292 to 220 pt, which resizes every ghostty grid and
`SIGWINCH`s every running shell. That is a real cost paid by every pane, and it is
disqualifying on its own unless it is compensated.

**Whether it can be compensated is the open question this probe hands on**, and there
is precedent that it can: `glass-backdrop`'s grid measurement faced the same shape of
problem for the footer and closed it by raising `window-padding-y`, verified against a
real PTY at 0 rows delta. The analogous move here is anchoring the pane tree to the
safe area rather than to `contentLayoutRect`, so the backing extends while the visible
layout does not move — which is exactly what `titlebar-toolbar`'s shipped-shape arms
do with their well. **Neither is measured here.** A follow-up probe wanting a real PTY
and a grid count, on `gridtest.swift`'s pattern, is what would close it.

So the recommendation in one line: **the merge is available and costs a window-style
change whose grid impact is unmeasured; measure that before adopting it, and do not
adopt it on this probe alone.**

### What is not answered

- **Drag and click are inspected, not exercised** (finding 3). A focus-taking probe or
  a hand check in the dev build is what settles them.
- **The key-to-non-key transition is unmeasured**, for `glass-backdrop`'s reason: every
  window here is already non-key, so the probe cannot see what a merged panel does
  when the window loses focus. Ghostty's discussion #10170 reports
  `NSGlassEffectView` flattening on unfocus, and a merged panel is a larger surface to
  flatten. **Check this before shipping.**
- **The tab bar is absent.** These windows have no tab group, and a tab bar changes
  the band's height (which is why `layoutTitlebarGlass()` derives it rather than
  writing 40). A merged panel has to follow that height change too.

## Files

Captures land in the output directory (default `$TMPDIR/baia-titlebar-merge`), which
is outside the repo:

```
arm-1-shipped-two-planes.png    the control: the seam as it ships
arm-2-container-merged.png      NSGlassEffectContainerView, both planes
arm-3-fullsize-one-plane.png    one plane down the column
arm-4-flat-control.png          the same geometry, no glass
<name>-backing.png              the `-l` cross-check for each of the above
backdrop-check-<arm>.png        the off-window strip each arm's backdrop assertion
                                read, one per arm: the evidence that what the glass
                                sampled was the controlled field
measurement.txt                 the strip numbers, the noise floor and the profiles
```

## Focus

This probe is `.accessory`, every window is `orderFrontRegardless()`, `canBecomeKey`
is overridden to `false` on all of them, and it contains no `makeKeyAndOrderFront`,
no `activate`, no `pkill`, and spawns no shell. It puts real windows on screen for
about twenty seconds, over a full-screen backdrop it needs as a controlled thing for
glass to sample, and orders them out again. **The keyboard never leaves the pane that
launched it**, which is the criterion `SAFE_PROBES` enforces — focus, not
invisibility. It qualifies on `glass-backdrop`'s ground and is listed beside it.
