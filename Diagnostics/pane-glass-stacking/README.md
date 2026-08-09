# Pane-glass-stacking probe

`./run.sh [output-directory]` from anywhere. Puts a controlled backdrop and six
pane-shaped windows on screen for ~25 seconds, writes seven captures with their
`-screen.png` companions, and prints the band means and corner probes the
findings below cite. Captures land outside the repo (default
`$TMPDIR/baia-pane-glass-stacking`). Exits non-zero if a capture fails, a glass
view never samples, the shipped arm shows a seam, or the negative control stops
showing one.

**Two halves, and only the second is a test.** The four MOCK arms answered the
spec's fork in the 2026-08-08 spike; their numbers are recorded below and
nothing asserts them. The two SHIPPED arms, added 2026-08-09 after ABSORB
shipped, are compiled from `Sources/` and asserted on every run.

**No focus is taken.** `.accessory` activation, `orderFrontRegardless()` only,
every window refuses key and main — the `SAFE_PROBES` standard `glass-backdrop`
set. What this probe does more loudly than glass-backdrop: its backdrop floats
(`.floating` level), so for those ~20 seconds the whole screen is a white/black
field with the probe panes on it. The keyboard never leaves the owner. See
"method corrections" for why the backdrop cannot sit below normal windows here.

## The question

Pane-as-glass puts a pane-wide `NSGlassEffectView` plane behind the whole pane.
The footer already wears its own `NSGlassEffectView` backing inside the pane's
bounds (`PaneStatusBarView.glassBacking`), so the naive port stacks the footer's
glass on top of the pane's glass — glass sampling glass, which the HIG bans and
the sibling-glass audit comment in `Sources/PaneStatusBarView.swift`
(`applyResolvedChrome()`) explicitly defers: "the moment a second glass element
joins this footer, both belong inside one `NSGlassEffectContainerView`". The
spec has to choose between two resolutions, and this probe measures both, plus
the violation they exist to avoid:

| Arm | Arrangement |
|---|---|
| `absorb` | One pane-wide plane, the footer's own backing deleted; footer content draws directly over the plane's bottom strip, and the window-corner mask lives on the shared plane |
| `container` | Plane + separate footer glass, grouped in one `NSGlassEffectContainerView` (`spacing = 0`) — the HIG-permitted shape |
| `violation` | Plane + separate footer glass, hand-stacked, no container — the naive port, the thing the ban is about |
| `container-outermask` | Supplementary, added mid-spike: `container` with the corner mask on the container itself instead of on the child glasses, because the first run showed the container drops child masks (finding 3) |

ABSORB was chosen (spec fork 1) and shipped: `Sources/PaneGlassPlane.swift`
plus the footer's backing deleted (`a15d28e`), the mask relocated to the plane
(`cbf3f90`). Two further arms measure **that code** rather than the mock, and
are asserted rather than tabulated:

| Arm | Arrangement |
|---|---|
| `shipped-absorb` | The shipped types, compiled verbatim: `PaneGlassPlaneView` + `PaneGlassWashView` at pane size wearing the real `WindowCorner.cgPath` mask, hosted as `TerminalPaneController.installGlassPlane()` hosts them, with a real `PaneStatusBarView` (`resolvedChrome = .glass`) over the bottom `PaneStatusBarMetrics.height` points. **Asserts no seam** at the footer's top edge |
| `shipped-violation` | The negative control: `shipped-absorb` with the deleted footer glass put back, one bare `NSGlassEffectView` hand-stacked under the bar region. **Asserts the seam returns.** Inverted by `run.sh` — this arm passing its own check is what the run needs; a control that stops failing makes the shipped arm's PASS meaningless, and fails the run |

## The mock, and how faithful it is

Each arm is a 720x200 pt borderless non-opaque window: untinted `regular`
glass, `cornerRadius = 0`, a `CAShapeLayer` squircle mask — the exact settings
`PaneStatusBarView.applyResolvedChrome()` and `updateGlassMask()` write, with
the footer strip at the real `PaneStatusBarMetrics.height` read off `PaneChrome`
at run time. Content (terminal rows, the drawn capsule, the footer segments) is
drawn as siblings *above* the glass, which is the shipped hierarchy (content
never goes through `contentView`), and is identical across arms, so any band
difference between arms is the glass arrangement and nothing else.

Two deliberate infidelities, both named:

- The corner squircle is transcribed (`radius 16`, `.continuous`) because
  `Sources/WindowCorner.swift` is app-target code a probe cannot link. If
  `WindowCorner.radius` moves, this probe is stale.
- The plane samples the controlled backdrop directly. A real pane-as-glass may
  keep some well wash above the plane; that would damp every delta below, not
  change its sign. (The two shipped arms below carry the wash, and it does
  exactly that.)

## The shipped arms carry no mock at all

Both are built from `Sources/`, compiled verbatim by `run.sh` — the same
arrangement `Diagnostics/footer-corners` uses, and the reason its comment about
new edges showing up in the `swiftc` line is worth keeping. Four files link:
`PaneGlassPlane.swift`, `PaneStatusBarView.swift`, `WindowCorner.swift`, and
`PaneOverlayView.swift` (needed only to link, as `WindowCorner`'s other
consumer). Nothing else in `Sources/` is reachable from them. The squircle is
`WindowCorner.cgPath`, not `ProbeCorner`; the footer is a real
`PaneStatusBarView` with a real `PaneStatus`, not `FooterTextView`; the plane,
the wash and the mask are the four lines `installGlassPlane()` and
`updateGlassPlaneMasks()` write, in the same order.

Four differences from a live pane, all named:

- **No ghostty surface.** The terminal ink is the same drawn `TerminalTextView`
  stand-in the mock arms use, because a real surface needs Metal and a PTY and
  paints nothing into either measurement band.
- **Frame-set rather than autolayout-pinned.** This window has no pane tree to
  constrain against. The bar draws from `bounds`, so the route in does not reach
  the pixels.
- **`RGB` → `NSColor` is spelled in the probe.** The shipped wash colour goes
  through `ChangesSurface.nsColor`, which lives in a 583-line file that builds a
  whole scrolling changes view; linking it to reach a six-line explicit-sRGB
  conversion would drag the probe into the app target for nothing. The
  conversion is identical, and both *inputs* (`PaneTheme.darkPastel.background`,
  `ChromeMaterials.PaneWash.opacity` at `Settings.defaultSettings
  .backgroundOpacity`) are read off the packages at run time, so a move of the
  wash floor reaches this probe without an edit.
- **`isFocused` is false.** A measurement decision, not a claim about the common
  state: the focus frame is a 2 pt stroke on the bar's own top edge, which in
  pane coordinates is y 178-180 — the exact rows the seam band reads. The first
  run of these arms had it on and both arms measured a step (+27 and +44) that
  was the stroke rather than the glass. It draws identically in the arm and in
  its control, so it could not have made the control pass falsely; it hid what
  the glass was doing in both.

## How the captures are read

- **`-R` (the `-screen.png` files) is the measured route.** A pane-sized
  `NSGlassEffectView` composites at the *window-server* level: its `-l` buffer
  is a flat unsampled slab (`(20,20,20)` with text ink on top) at every settle,
  the same behaviour glass-backdrop's README documents for its 220 pt sidebar
  column. The 22 pt strips glass-backdrop measured through `-l` composite
  in-buffer; a pane-sized plane does not. `-R` absolutes carry the display's
  tone response at capture time, so **every number below is within-run only**.
- **`-l` still earns its keep through its alpha channel**, which carries each
  arm's mask geometry exactly: α=0 outside the squircle, α=255 inside. That is
  what the corner probes read.
- **The measured captures are solo** — one arm on screen at a time — and each
  `-R` grab extends 40 pt past the window, so its margins are raw controlled
  backdrop: per-capture tone references that prove the display held still
  between grabs (they agreed within 5/255 in the recorded run).
- `all-arms-screen.png` is all four arms in one frame, **by eye only**: stacked
  16 pt apart the planes sample each other (see method corrections).

## Findings

Recorded run 2026-08-08. Bands: footer = the strip's bottom ~3 pt (below glyph
descenders), surface = glass-only rows above the footer, white/black = either
side of the seam at the pane's midline; margins as tone refs. All within-run.

| Arm | footer@white | footer@black | surface@white | surface@black |
|---|---|---|---|---|
| absorb | `#7d7d7d` | `#181818` | `#7d7d7d` | `#191919` |
| container | `#7d7d7d` | `#161616` | `#7d7d7d` | `#191919` |
| violation | `#7b7b7c` | **`#2c2c2c`** | `#7d7d7d` | `#191919` |
| container-outermask | `#7d7d7d` | `#161616` | `#7d7d7d` | `#191919` |

Tone refs: white `#f8f8f8`–`#fdfdfd`, black `#010101`–`#060606` across the four
solo grabs — stable, so the columns compare.

Run of record for the two shipped arms, 2026-08-09, same session, same backdrop:

| Arm | footer@white | footer@black | surface@white | surface@black | edge above/below (dark) |
|---|---|---|---|---|---|
| shipped-absorb | `#3f4043` | `#1e1f21` | `#484848` | `#161616` | `#171717` / `#171717` |
| shipped-violation | `#484a4c` | `#2b2c2f` | `#484848` | `#161616` | `#171717` / **`#2b2b2b`** |

Tone refs on both: white `#fdfdfd`, black `#010101`. The shipped absolutes sit
higher than the mock arms' because the pane wash is above the plane in these
two and the mock arms have none; the wash damps the white/black spread rather
than removing it, which is the finding-2 caveat from
`Diagnostics/pane-glass-legibility` arriving here.

### 1. The violation's visible cost is real, and it is one-sided: dark backdrops.

Over the black half the hand-stacked footer reads `#2c2c2c` against `#191919`
for the plane it sits on — a **+19..21/255 milky lift** across the whole strip,
with a hard step at the strip's top edge (rows just above / just below the
boundary: `#1a1a1a` / `#2d2d2d`). By eye it is a distinct lighter band with a
visible seam where the footer glass begins. Over the white half the same
arrangement measures **nothing**: `#7b7b7c` against `#7d7d7d`, a 2-unit
*darkening*, invisible. So "glass over glass doubles the effect" is true over
dark content and unmeasurable over bright content — on this backdrop, at this
display state. A terminal is dark most of the time, so the failing half is the
common case.

### 2. The container erases the footer. CONTAINER and ABSORB are visually indistinguishable.

`container` matches `absorb` within 1–2 units in every band, on both halves,
and shows no top-edge step at all (`#1a1a1a` / `#1a1a1a`). The merge is total:
an untinted footer glass fully overlapping the plane inside one container does
not read as a distinct surface — it reads as if it were not there. What these
numbers cannot distinguish is "merged into one sampling pass" from "contributing
nothing"; either way the pixels are ABSORB's. (glass-backdrop's finding 5 shows
a *tinted* child in a container does stay distinct, so children do render — the
disappearance here is the untinted, fully-overlapped case.)

### 3. The container drops the children's corner masks. An outer mask works.

Corner probes, `-l` alpha (want α=0 at the bottom corners, α=255 at the top):

| Arm | bottom-left | bottom-right | top-left | top-right |
|---|---|---|---|---|
| absorb | α=0 | α=0 | α=255 | α=255 |
| container | **α=255** | **α=255** | α=255 | α=255 |
| violation | α=0 | α=0 | α=255 | α=255 |
| container-outermask | α=0 | α=0 | α=255 | α=255 |
| shipped-absorb | α=0 | α=0 | α=255 | α=255 |
| shipped-violation | α=0 | α=0 | α=255 | α=255 |

The two shipped rows are the stricter reading, and they are the one place this
probe checks the fix `cbf3f90` made rather than the mock's transcription: they
wear the real `WindowCorner.cgPath`, whose documented precondition is a flipped
view, on the real `PaneGlassPlaneView` and `PaneGlassWashView`. Both declare
`isFlipped: true` for that reason. If either loses the override the corners come
back rounded at the TOP — a silent failure in the app, a visible α flip here.

The footer glass **cannot keep its own `CAShapeLayer` mask inside an
`NSGlassEffectContainerView`**: the container renders its children through its
own compositing and the masks are ignored — even re-applied after the
`contentView` assignment, and it takes the plane's mask down too (the
`container` arm draws square bottom corners, visible in its capture). The
fallback works: one pane-shaped mask on the container itself clips correctly,
and since the plane and the footer share the same bottom corners, one outer
mask serves both. `NSGlassEffectView.cornerRadius` as an alternative was not
tested (the mask is the shipped mechanism and `cornerRadius` is the wrong
shape for this bar twice over, per `updateGlassMask()`'s comment). In `absorb`
and `violation` the masks behave: a masked single plane works, and hand-stacked
glasses each keep their own mask.

### 4. What each resolution costs the footer's existing features

- **Corner mask.** ABSORB: moves to the shared plane, works (measured).
  CONTAINER: must move to the *container*, works (measured); the footer glass
  cannot carry its own. Neither loses the curve; both relocate it.
- **Tint path.** *(Past tense as of 2026-08-09: this is what the cost looked
  like when the fork was open, and the fork closed on ABSORB. Both things named
  here are now deleted — `chrome.surfaces.footer`'s `fillMaterial` override in
  `757d98c`, and the backing it wrote to in `a15d28e` — so the paragraph is a
  decision record rather than a description of the code. Kept because the cost
  was real and was accepted knowingly.)* The shipped tint was nil, but the debug
  design panel's `fillMaterial` override wrote `NSGlassEffectView.tintColor` on
  the footer's backing (`updateGlassTint()`). ABSORB deleted that target: a
  footer-only tint would have had to become a drawn translucent wash above the
  plane, or tint the whole plane. CONTAINER would have kept a footer glass to
  tint, and glass-backdrop's finding 5 says a tinted child inside a container
  renders as a distinct shape. What shipped instead is neither: the dial retired
  with the backing, and the other four surfaces kept theirs.
- **Capsule.** Drawn content above the glass in every arm, untouched by all
  three arrangements.

### 5. Method corrections the spike itself forced (kept because they cost runs)

- **Mask orientation.** A probe-built glass view's layer mask evaluates in y-up
  layer coordinates even under a flipped superview: the shipped "round the
  bottom corners" spelling clipped the *top* corners here. The probe now rounds
  the shape's "top" corners and the corner probes re-verify orientation every
  run. Consequence for the app: the mask path's frame of reference has to be
  re-checked wherever the plane is hosted, not copied from `PaneStatusBarView`.
- **Neighbour sampling.** With the four panes stacked 16 pt apart, the
  sandwiched arms' planes measured up to 26/255 darker than the same plane at
  the stack's edge — a plane samples past its own window. Measured captures went
  solo because of this. Any future probe comparing glass windows must not let
  them near each other.
- **The backdrop must out-level the desktop.** At glass-backdrop's
  `.normal - 1` an ordinary window slotted between backdrop and pane mid-run
  and the "white" margin reference came back `#3a4554`. The margin references
  exist because they caught this; the backdrop now floats.

### 6. The shipped code shows no seam; the deleted arrangement brings it back

Recorded run 2026-08-09, the two shipped arms, dark half, `-R` route,
within-run. The band is the footer's top edge: pane y 174-176 (the plane alone)
against y 179-181 (whatever the arm puts in the footer), the boundary at y 178.

| Arm | above | below | step | threshold | |
|---|---|---|---|---|---|
| `shipped-absorb` | 23.00 | 23.00 | **+0.00** | `|step| <= 3` | PASS |
| `shipped-violation` | 23.00 | 43.00 | **+20.00** | `|step| >= 12` | PASS (control fails as it must) |

Two things this settles that the mock arms could not.

**The shipped arrangement is seamless, and exactly seamless.** Not "within the
noise floor" — 0.00 on a band the mock arms could only get to 1-2 units on. The
footer's top edge is not findable, because under ABSORB nothing begins there:
one plane, one wash, and a `PaneStatusBarView` that paints no fill on the glass
path. Two live properties are asserted by that zero rather than assumed. If a
second glass view ever came back under the bar, or if `draw(_:)`'s
`materialSet == nil` fill-skip regressed, this number moves and the run fails.

**The control reproduces the spike's own measurement, on the shipped code.**
+20.00/255 against the mock `violation` arm's +19..21 measured a day earlier
with a transcribed footer and no wash. The agreement matters more than the
number: the wash sits above the plane in the shipped arms and damps every delta
(their surface bands are `#484848`/`#161616` where the mock arms read
`#7d7d7d`/`#191919`), and the seam came through it undamped anyway. That is
finding 1 surviving contact with the real hierarchy, which the mock could only
predict.

The threshold pair is 3 and 12. The floor is one unit above the 1-2 the spike
measured between ABSORB and CONTAINER; the ceiling sits well clear of it and
well under the +19..21 both runs measured, so the control fails for a real
reason rather than a tuned one. `run.sh` inverts the control per
`footer-corners`' rule: if putting the deleted glass back stops producing a
seam, this display, backdrop or macOS build cannot see the difference the
shipped arm claims to avoid, and the shipped arm's PASS means nothing. Verified
both ways on 2026-08-09 by feeding the seamless capture in as the control's
input — the run exits 1.

### 7. Method corrections the shipped arms cost (two more runs)

- **A pane at `.floating` still loses to the Dock.** The shipped arms were first
  parked below the four-pane stack, which put them over the Dock: the captures
  came back with dock icons across the footer band and the desktop wallpaper
  behind the glass, because the Dock outranks `.floating` and the controlled
  backdrop therefore was not what the pane sampled. They now reuse the stack's
  own top slot — solo capture means they can share a frame with an arm they are
  never on screen beside. The backdrop covers the whole screen, but only the
  middle of it is free of system chrome.
- **`backgroundOpacity: 1` is not a state glass reaches, and it silently erases
  the measurement.** The wash is `max(backgroundOpacity, floor)`, so at 1 it is
  fully opaque and there is no glass left to see. The first run of these arms
  passed 1 and both captures read the same 20.00 on the white half and the dark
  half — a pane sampling nothing, which the margin references could not catch
  because the margins were fine. `windowIsTransparent(backgroundOpacity:
  appearance:)` gates the whole glass path on `< 1`; the probe now reads
  `Settings.defaultSettings.backgroundOpacity` (0.42) off the package.
- **Do not measure a seam band that a focus stroke lands in.** With
  `isFocused = true` the bar's 2 pt focus frame draws at pane y 178-180, the
  exact rows the seam band reads, and both arms measured a "step" (+27, +44)
  that was the stroke. It draws identically in the arm and its control, so it
  could not have made the control pass falsely — it hid the glass in both.

## Verdict-shaped summary (the spec chooses; this is what the pixels say)

- VIOLATION is disqualified on its own evidence: a visible milky band with a
  hard seam over dark content, which for a terminal is most content.
- ABSORB and CONTAINER produce **identical pixels** in this mock. The choice
  between them is not visual. ABSORB is structurally cheaper (one glass view,
  no new container type, mask lands on the one plane) and costs the debug-panel
  tint override its `tintColor` target. CONTAINER keeps a tintable footer glass
  and a shape the capsule could later join as a second (tinted) child — but its
  masks must move to the container, and its footer glass is otherwise
  indistinguishable from not existing.

ABSORB shipped. Findings 6 and 7 are the check that what shipped is what was
measured, and they are the half of this probe that keeps running: the four mock
arms are a record, the two shipped arms are a test.

Every absolute above carries the backdrop caveat: measured over a pure
white/black field at one display state, within one run. The bright/dark
asymmetry of finding 1 and the zero-deltas of finding 2 are what transfer;
the numbers do not.

## Files

```
pane-absorb.png                  -l, mask alpha (colour is an unsampled slab)
pane-container.png               -l
pane-violation.png               -l
pane-container-outermask.png     -l
pane-shipped-absorb.png          -l, the shipped types' own mask alpha
pane-shipped-violation.png       -l
pane-<arm>-screen.png            -R solo with 40 pt backdrop margins: the
                                 measured files, all six arms
all-arms-screen.png              the four MOCK arms, one frame, by eye only.
                                 The shipped arms are not in it: six 200 pt
                                 panes do not fit a 900 pt screen, and the
                                 frame is a side-by-side of the spec's fork,
                                 which they postdate
```
