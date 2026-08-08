# Pane-glass-stacking probe

`./run.sh [output-directory]` from anywhere. Puts a controlled backdrop and four
pane-shaped windows on screen for ~20 seconds, writes five captures with their
`-screen.png` companions, and prints the band means and corner probes the
findings below cite. Captures land outside the repo (default
`$TMPDIR/baia-pane-glass-stacking`). Exits non-zero if a capture fails or a
glass view never samples.

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
  change its sign.

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
- **Tint path.** The shipped tint is nil, but the debug design panel's
  `fillMaterial` override writes `NSGlassEffectView.tintColor` on the footer's
  backing (`updateGlassTint()`). ABSORB deletes that target: a footer-only tint
  would have to become a drawn translucent wash above the plane, or tint the
  whole plane. CONTAINER keeps a footer glass to tint, and glass-backdrop's
  finding 5 says a tinted child inside a container renders as a distinct shape.
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
pane-<arm>-screen.png            -R solo with 40 pt backdrop margins: the
                                 measured files
all-arms-screen.png              all four arms, one frame, by eye only
```
