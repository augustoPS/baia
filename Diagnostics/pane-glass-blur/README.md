# Pane-glass-blur probe

`./run.sh [output-directory]` from anywhere. Writes one reference capture, four
controlled arms, a wallpaper-dependent pair, a `-window.png` companion for the
two glass arms, and `metrics.txt`; exits non-zero if a capture fails or the
controlled backdrop never renders. Windows appear over whatever is in front for
roughly twenty seconds, take no focus (`.accessory` +
`orderFrontRegardless()`, the `SAFE_PROBES` standard), and are ordered out.

## The question

baia's background blur is **window-wide**: `CGSSetWindowBackgroundBlurRadius`
(the same CGS SPI ghostty, iTerm2 and Alacritty use, declared here exactly as
`Sources/WorkspaceWindowController.swift` declares it) frosts whatever the
compositor has behind the window, at `PaneChrome.parityBlurRadius` — resolved
at run time through
`windowBlurRadius(backgroundBlur:backgroundOpacity:appearance:paneGlassActive:)`
against the shipped defaults (blur on, opacity 0.42, `paneGlassActive: false`),
which is **20** on this run. In-window glass then samples that already-frosted
composite.

The pane-as-glass plan ships with the compositor blur **off** so the glass does
all the lensing. This probe measures what an `NSGlassEffectView` plane over
terminal-ish content looks like with the compositor blur on versus off, to give
the spec the evidence for "blur off" and to show what double-lensing costs if
the blur stays on.

## Method

A full-screen **controlled backdrop** of deliberate high-frequency detail
(vertical gratings at 1/4/8/16 pt stripe widths repeating every 80 pt, thin
horizontal rules, small text in the top third — fine detail is what blur
destroys, so the backdrop is made of it) sits below a 720x420 pt non-opaque
probe window. The window's left ~100 pt stays bare, so the compositor blur is
measured on its own through the transparent region; the rest holds either an
untinted `.regular` `NSGlassEffectView` plane whose `contentView` is a
terminal stand-in (the shipped 0.42 well wash plus monospaced rows, mimicking
pane-as-glass), or the same stand-in with no glass (today's arrangement). No
real ghostty surface: what blur and glass act on is composited pixels, and the
glass-backdrop probe already established the stand-in substitution is sound for
optics questions.

Both windows ride above the normal window band (`.floating` and
`.floating + 1`). The first run copied glass-backdrop's `.normal - 1` backdrop
level and measured someone else's pixels: another probe's windows were
mid-screen at normal level, over this backdrop, and the reference capture
photographed them instead of the pattern. The reference-gradient check caught
it. Window level does not affect key status, so the no-focus arrangement is
untouched.

### Arms, one run, one live window (the SPI is flipped in place; radius 0 removes it)

| Arm | compositor blur | material over the well |
|---|---|---|
| `arm-a-blur-off-glass` | off | glass plane — **the plan as specced** |
| `arm-b-blur-on-glass` | 20 | glass plane — the double-lensing arm |
| `arm-c-blur-on-noglass` | 20 | wash only — **today's shipped arrangement** |
| `arm-d-blur-off-noglass` | off | wash only — the raw show-through control |

Plus `wallpaper-blur-off-glass` / `wallpaper-blur-on-glass` over the real
desktop, **wallpaper-dependent**: nothing measured off those transfers to
another machine or another day.

### How the captures are read

`screencapture -R` over the window's frame is the primary route, because the
compositor blur exists only in the window server's composite; the window's own
backing store never contains it. `-R` carries the display's brightness and EDR
tone response at capture time (glass-backdrop measured pure white crushed to
21% luminance by that curve), so **every number below is within-run comparable
only**; no absolute here is quotable across runs or machines. The
`-window.png` companions (`screencapture -l`) exist for the side question of
whether the SPI changes what glass itself samples — see the surprise below for
what they turned out to show.

Two bands, in window fractions, kept in lockstep between `blurtest.swift`,
`run.sh` and this file:

- **bare** x 0.02–0.11, y 0.60–0.80 — transparent window region left of the
  plane: the compositor blur alone, no material over it. Also the in-probe
  verification band: arm (a) must show the grating essentially intact (blur
  observably off) and arm (b) must show its fine energy collapsed (the SPI
  observably taking effect through the same call the app makes), each with
  escalating re-settles before a capture is accepted.
- **glass** x 0.35–0.85, y 0.60–0.80 — inside the plane, inside the stand-in's
  deliberate text-free gap (window-y 0.56–0.84), so no glyph contaminates the
  show-through numbers.

Metrics per band (`analyze.py`, reusing `Diagnostics/lib/pixel.py`'s decoder):
**mean** luminance (brightness shift), **std** (retained structure/contrast),
and **hgrad** — mean absolute horizontal-neighbour luminance difference, the
detail-retention number: the backdrop is vertical gratings, so surviving fine
detail is horizontal luminance change, and blur is exactly what removes it.

## Findings

Measured 2026-08-08, radius 20 (read off `PaneChrome` at run time). Two runs
produced **bit-identical metrics for every controlled arm** (the scene is
static and the composite deterministic), so the deltas below are not noise;
the wallpaper arms differed between runs, as wallpaper-dependent numbers
should.

| Capture | bare mean | bare std | bare hgrad | glass mean | glass std | glass hgrad |
|---|---|---|---|---|---|---|
| `backdrop-reference` | 125.5 | 82.45 | 28.027 | 133.4 | 82.29 | 25.326 |
| (a) blur off, glass | 125.5 | 82.45 | 28.027 | 73.6 | 3.33 | 0.373 |
| (b) blur 20, glass | 127.8 | 24.16 | 1.148 | 73.9 | 2.58 | 0.334 |
| (c) blur 20, no glass — today | 127.8 | 24.16 | 1.148 | 85.8 | 15.61 | 0.943 |
| (d) blur off, no glass | 125.5 | 82.45 | 28.027 | 86.0 | 47.73 | 14.992 |

("glass" column = the glass band; in arms (c)/(d) the same band holds the bare
wash.)

### 1. The glass plane is a stronger low-pass than the compositor blur at 20.

Detail retention against the reference band's 25.326:

- wash alone (d): 14.992 — **59%** survives the 0.42 well.
- compositor blur + wash (c, today): 0.943 — **3.7%**. Fine detail gone,
  coarse stripes clearly survive (std 15.61; the capture shows soft wide
  banding under the text).
- glass + wash, blur off (a): 0.373 — **1.5%**, std 3.33. The plane is a
  near-featureless smooth surface; only the widest stripes ghost through as
  faint broad shading.

Glass alone destroys more backdrop detail than the CGS blur does. Whatever
"keep the desktop frosted behind the terminal" is worth, the glass plane
already over-delivers it under its own footprint.

### 2. Double-lensing is real but visually nil — and it buys nothing.

Flipping the SPI to 20 under the glass plane moves the plane's pixels from
std 3.33 / hgrad 0.373 to std 2.58 / hgrad 0.334: the residual structure gets
about a quarter smoother, deterministically (exact across both runs). At eye
level `arm-a` and `arm-b`'s planes are indistinguishable; every visible
difference between the two captures is in the bare margin outside the glass.
Brightness shift through the plane: **+0.3** of 255 (73.6 → 73.9); through the
bare region, +2.3. So leaving the blur on under pane-as-glass does not
visibly double-smear — it just pays a compositor pass for a change nobody can
see, plus a frosted look in any window region glass does not cover.

### 3. Yes, the CGS SPI feeds what glass samples — proven by the `-R` delta, not the `-l` files.

The only change between arms (a) and (b) is the SPI radius, and the plane's
own pixels moved (finding 2), so `NSGlassEffectView` samples the
compositor-blurred composite, not the raw content behind the window. The
interaction exists; it is merely too small to matter through glass this
strong.

**Surprise, recorded as a result:** the `-l` route cannot see any of this
here. Both `arm-*-window.png` backing stores are flat slabs in the glass band
(std 0.22 / 0.25 — no trace of the grating in either), unlike glass-backdrop's
22 pt bars, whose `-l` files carried the sampled backdrop. At this plane size
and arrangement, glass adaptation never lands in the probe window's own
backing store, so only screen composites can measure a pane-scale glass plane.
(The two `-l` files' *means* differ, 20.2 against 82.9; with both files
structureless that is backing-store state this probe does not explain, and no
conclusion is drawn from it.)

### 4. What blur-off actually changes, per region.

- **Under the glass plane: nothing visible** (finding 2). The spec's "blur off,
  glass does all lensing" costs no legibility and no frosting under the pane.
- **Bare/transparent window regions** (margins, any gap glass does not cover):
  everything. Blur off returns the raw desktop — the bare band goes from
  hgrad 1.148 back to the full 28.027, sharp grating and legible 9 pt backdrop
  text. If any transparent region survives around the glass planes, blur-off
  makes it a sharp window onto the desktop where today it is frosted.
- **Against today (c):** pane-as-glass with blur off is *darker and flatter*
  than the shipped wash-over-blur — mean 73.6 vs 85.8, std 3.33 vs 15.61. The
  coarse wallpaper ghosting today's arrangement keeps (visible banding under
  the text in arm (c)) is gone under glass; the plane reads as a smooth
  material, not a frosted window. That is an aesthetic trade the spec should
  state, not discover.

### The wallpaper pair (wallpaper-dependent, and contaminated)

Over the real desktop the two glass arms measured identically in the plane
(std 10.58/10.52, hgrad 0.232/0.232 in run 1; 6.03/5.95, 0.217/0.217 in run
2) — consistent with finding 2's "nothing visible through the plane". Every
absolute here is wallpaper-dependent, and this run's "wallpaper" additionally
contained another concurrent probe's windows behind this one (visible in the
captures), so these files are the eye-level illustration only; the controlled
arms are the measurement.

## Verdict evidence

**Ship pane-as-glass with the compositor blur off, as planned.** The evidence:

1. Under the plane, blur contributes nothing an eye or the band metrics can
   meaningfully see (std 3.33 → 2.58 on a 0–255 scale; brightness +0.3), while
   still costing the window-server blur pass on every frame.
2. Glass alone is already a stronger detail-destroyer than the blur it
   replaces (1.5% vs 3.7% fine-detail retention), so "the desktop stops being
   frosted" is not a regression pane-as-glass can suffer under its own
   footprint.
3. The one thing blur-off *does* change is regions glass does not cover, which
   become sharp show-through — a layout completeness question for the spec
   (cover the window, or accept sharp margins), not a lensing one.
4. If the blur were left on anyway, nothing visibly breaks (no double-smear);
   it is waste, not damage. `windowBlurRadius` already returns 0 when the
   setting is off, so the existing gate is the right shutoff.

## Files

Captures land in the output directory (default `$TMPDIR/baia-pane-glass-blur`),
outside the repo:

```
backdrop-reference.png          the pattern alone, same rect, no probe window
arm-a-blur-off-glass.png        the plan: glass plane, SPI 0
arm-b-blur-on-glass.png         double-lensing: glass plane, SPI 20
arm-c-blur-on-noglass.png       today: wash over compositor blur
arm-d-blur-off-noglass.png      raw show-through control
arm-{a,b}-*-window.png          -l backing stores (finding 3's surprise)
wallpaper-*.png                 the wallpaper-dependent pair + reference
metrics.txt                     the band numbers, as printed by run.sh
```

## Prior art

`Diagnostics/glass-backdrop/` supplied the harness shape (accessory no-focus
windows, controlled backdrop below, settle-verified captures, `pixel.py`), the
`-R`-tone-curve and `-l`-versus-`-R` capture rules, and the 26.2
`isMovable = true` workaround every window here sets.
`Sources/WorkspaceWindowController.swift` supplied the SPI declarations this
probe mirrors so the measurement uses the app's own blur mechanism, and
`PaneChrome.windowBlurRadius` supplies the radius at run time so the probe
cannot grade against a number that has moved.
