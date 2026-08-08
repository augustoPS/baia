# Pane-wash legibility sweep

`./run.sh [output-directory]` from anywhere. Writes a calibration strip, fourteen
sweep captures (each with a `-screen.png` companion), two wallpaper shots, and
`results.txt`; exits non-zero if a capture fails or the glass never samples its
backdrop. Needs only `swiftc` and stdlib `python3`; no app build.

Not yet on `guard-baia-alive.sh`'s `SAFE_PROBES` list. It meets the list's
criterion — `.accessory` activation policy, every window `orderFrontRegardless()`
and `canBecomeKey == false`, no `NSApp.activate`, nothing quit or launched — and
puts windows on screen for roughly 35 seconds without ever taking the keyboard,
the same shape as `glass-backdrop`. Adding it to the list is the guard owner's
call, not this probe's.

## The question

Design v6 puts the terminal on a real `NSGlassEffectView` plane, and terminal ink
straight over glass fails legibility (glass-backdrop finding 6b: ink at 1.19:1
over bright glass). The planned repair is a **pane wash**: `theme.background`
(`#141414` on the owner's Dark Pastel) painted at opacity α over the glass plane,
under the text. This probe sweeps α and produces the curve — contrast of the
terminal ink (`#bbbbbb`, the theme foreground) over glass-plus-wash as a function
of α — and answers where WCAG AA's 4.5:1 holds.

## Method

One pane-shaped window (640×360 pt, non-opaque, borderless, `isMovable = true`
against the 26.2 non-movable-window sampling regression) per α, holding bottom to
top: an untinted `.regular` `NSGlassEffectView` filling the window; a wash view
filling it with `theme.background` at α; terminal-like rows at 11.5 pt monospaced
in `theme.foreground`. Wash and text are siblings *above* the glass, not its
`contentView`, so AppKit's `contentView` legibility treatments cannot join the
measurement. Theme values are read off `PaneChrome` (`PaneTheme.darkPastel`) at
run time, not transcribed.

**The ink-free band.** Glyph rows are held out of height × 0.55–0.80, and the
backdrop is sampled at y 0.60–0.75 only — a band that contains no ink, per the
ink-contamination lesson in glass-backdrop (a band through glyph rows compares
the ink against a region containing that same ink and inflates the ratio). The
ink itself is sampled separately, as the brightest pixel in the dense glyph band
(y 0.20–0.45), from the same capture.

**The controlled backdrop.** A full-screen window, pure white beside pure black,
sits under the probe window, which straddles the vertical seam: every capture
carries the bright extreme (x 0.10–0.35) and the dark extreme (x 0.65–0.90) in
one frame, and the whole sweep is one capture session. Two wallpaper shots
(α 0.00 and 0.65) are taken after the backdrop is ordered out, for the record
only: they photograph the owner's wallpaper and transfer to no other machine.

**The sweep.** α ∈ {0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75,
0.8, 0.9, 1.0}, finer between 0.5 and 0.8 where the prior numbers predicted the
crossing. 1.0 is the shipped-equivalent reference: a fully opaque wash, today's
near-solid well.

## How the captures are read

**The measured route is `-R`, and finding that out is itself a result.** The
first version of this probe read the `-l` window-buffer files, following
glass-backdrop's rule that `NSGlassEffectView` composites its sampled backdrop
into its own window's buffer. That rule held for glass-backdrop's 22 pt bars and
does **not** hold here:

- **A pane-sized glass plane composites at the window-server level.** Its `-l`
  band reads a flat, opaque `(20, 20, 20, 255)` slab at every α *including
  α = 0, where no wash exists* — the material's dark-appearance placeholder,
  which happens to sit at the same `#141414` as the Dark Pastel background (a
  coincidence; the slab is there with the wash absent). The `-R` companions
  carry the white/black split at the same instant. This is the same behaviour
  glass-backdrop recorded for its 220 pt sidebar column; the boundary between
  the two regimes (their 22 pt bars read fine through `-l`) is somewhere between
  bar-sized and pane-sized, and this probe did not chase it. `measure.py` prints
  the flat `-l` bands every run as the standing record of this negative result,
  and would flag a split if the behaviour ever changed.
- Consequence, inherited with the route: `-R` applies the display's brightness
  and EDR tone response at capture time, so **every absolute in this README is
  within-run only**. Both sides of each contrast are sampled from the same file
  (ink from the glyph band, backdrop from the ink-free band), which keeps each
  ratio internally consistent; the ratios still move between runs, and the probe
  measured that directly — see finding 5.
- Each run writes `calibration.png`, a strip of the *bare* backdrop through the
  same route, so a reader can see how far apart two runs' tone curves were
  before comparing anything else.

## Findings

Run of record: 2026-08-08, `results.txt`. This run's calibration: bare white
reads `#3a3a3a`, bare black `#111111` — a dark tone-response day (glass-backdrop
measured bare white at `#7d7d7d` on its brightest recorded day).

### 1. The curve

Ink sampled from each capture read back `#bbbbbb` exactly on every file (and the
α = 1.0 row's 9.60:1 equals the nominal `#bbbbbb`-on-`#141414` arithmetic to the
second decimal), so the ink side carried no tone-curve loss this run.

| α | band over WHITE | contrast | ≥4.5 | band over BLACK | contrast | ≥4.5 |
|---|---|---|---|---|---|---|
| 0.00 | `#454545` | 4.99:1 | yes | `#252525` | 7.98:1 | yes |
| 0.10 | `#404040` | 5.40:1 | yes | `#232323` | 8.19:1 | yes |
| 0.20 | `#3b3b3b` | 5.83:1 | yes | `#222222` | 8.29:1 | yes |
| 0.30 | `#363636` | 6.29:1 | yes | `#202020` | 8.49:1 | yes |
| 0.40 | `#313131` | 6.78:1 | yes | `#1e1e1e` | 8.68:1 | yes |
| 0.50 | `#2c2c2c` | 7.27:1 | yes | `#1c1c1c` | 8.88:1 | yes |
| 0.55 | `#2a2a2a` | 7.48:1 | yes | `#1c1c1c` | 8.88:1 | yes |
| 0.60 | `#282828` | 7.68:1 | yes | `#1b1b1b` | 8.97:1 | yes |
| 0.65 | `#252525` | 7.98:1 | yes | `#1a1a1a` | 9.07:1 | yes |
| 0.70 | `#232323` | 8.19:1 | yes | `#191919` | 9.16:1 | yes |
| 0.75 | `#202020` | 8.49:1 | yes | `#181818` | 9.25:1 | yes |
| 0.80 | `#1e1e1e` | 8.68:1 | yes | `#171717` | 9.34:1 | yes |
| 0.90 | `#191919` | 9.16:1 | yes | `#161616` | 9.43:1 | yes |
| **1.00** | `#141414` | **9.60:1** | yes | `#141414` | 9.60:1 | yes |

**Minimum α clearing 4.5:1 on the bright (worst) half, this run: 0.00.** Every
value in the sweep clears, the curve is monotonic with no crossing inside the
sweep, and its shape is a straight line in capture byte space (finding 3) whose
contrast payoff flattens toward opaque: the first half of the α range buys
4.99 → 7.27, the second half 7.27 → 9.60.

### 2. Why α = 0 passing does not contradict the 1.19:1 that motivated the wash

Two differences, both load-bearing:

- **Different ink.** The 1.19:1 graded `theme.inkFaint` (`#898989`) — the
  sidebar's *faint* tier. This probe grades the terminal's body ink,
  `theme.foreground` `#bbbbbb`. Against this run's bright-half glass
  (`#454545`), `#898989` would score 2.74:1 — still failing — and `#bbbbbb`
  scores 4.99:1.
- **Different day.** The 1.19:1 run's bright glass composited at `#7c7c7c`
  (bare white `#7d7d7d` beside it); this run's composited at `#454545` (bare
  white `#3a3a3a`). Same code, roughly 1.8× apart, which is the tone-curve
  caveat doing what it always does.

So raw `#bbbbbb` over bare glass **passes on a dark-tone-response day and fails
on a bright one** (against `#7c7c7c` it would read 2.17:1, glass-backdrop 6b's
own number for that literal). α = 0 is not safe; this run alone just cannot show
that, and the next finding is what can.

### 3. What transfers between runs: the wash is a linear floor, and the bound is computable

Across the whole sweep, on both halves, the measured band obeys

```
band(α) = α · wash + (1 − α) · band(0)        (capture byte space, ±1)
```

e.g. bright half: band(0) = 69, wash = 20; α 0.65 predicts 37.2, measures 37
(`#252525`); α 0.9 predicts 24.9, measures 25. Thirteen points, both halves, all
within ±1. The wash composites as plain source-over paint and nothing about the
glass re-adapts as α rises.

That linearity is what the pane wash is *for*: it bounds the worst case
independent of wallpaper. `#bbbbbb` holds 4.5:1 against backdrops of `#4b4b4b`
or darker, so the α that guarantees the floor against a bright glass reading
`B` is `α ≥ (B − 75) / (B − 20)`:

| worst case guarded against | B | α needed |
|---|---|---|
| this run's bright-half glass | `#454545` | 0.00 |
| brightest glass ever measured in this repo (glass-backdrop 6b, `#7c7c7c`) | `#7c7c7c` | **0.47** |
| theoretical ceiling: backdrop composites to pure white | `#ffffff` | 0.77 |

The `0.47` row uses the one recorded run whose tone response was nearest
identity (bare white `#7d7d7d`), which is the honest anchor for "bright day"
arithmetic. Glass-backdrop 6b closed by recording that a grading constant cannot
track a wallpaper-dependent backdrop and that fixing it "needs a floor under the
wash" — this table is that floor, quantified: **α ≈ 0.5 buys AA against the
worst backdrop ever measured here; α ≈ 0.8 buys it against anything the
compositor can produce.** Above 0.8 the wash buys robustness no real backdrop
has yet demanded, at the cost of erasing the glass (the pane reads as an opaque
panel — the same aesthetic cliff the glass-backdrop well sweep named).

### 4. The shipped-equivalent reference

α = 1.0, the opaque wash, measures **9.60:1** on both halves — the ceiling of
the curve, backdrop-independent by construction, and the arithmetic equal of
`#bbbbbb` on `#141414`. Today's near-solid well at 0.90+ sits within 0.44 of it
(9.16:1 at α 0.9). The entire robustness question above is about the *other*
end of the curve.

### 5. Between-run instability, observed live

A discarded earlier run the same evening read the α = 0 bright-half band at
`(126, 126, 126)` where the run of record reads 69 — the display's adaptive
tone response moved by ~1.8× between two runs minutes apart, without a
brightness key being touched. Within the run of record the linear fit in
finding 3 holds to ±1 across all fourteen captures, which is the evidence the
tone response held still *during* the ~35-second sweep. One run, one capture
session; never mix runs.

### Wallpaper, for the record

Over the owner's real wallpaper (backdrop window removed; wallpaper-dependent,
comparable to nothing): α 0.00 reads 7.48:1 / 7.06:1 (left/right bands), α 0.65
reads 8.97:1 / 8.77:1. His wallpaper is darker than the white extreme, as most
are; the white half of the controlled backdrop stays the worst case the design
must survive.

## Caveats, restated

- **Every absolute carries the wallpaper caveat.** The bright-white underlay is
  the worst case; real wallpapers vary, and the wallpaper rows above are
  photographs of one machine on one day.
- **Within-run comparisons only.** The `-R` route bakes the display's
  brightness and EDR response into every byte at capture time (finding 5
  measures the swing). The curve's shape, the linear model, and the ordering
  transfer; the absolutes do not. `calibration.png` is each run's tone-response
  fingerprint.
- **The `-l` route is blind to this material** (see "How the captures are
  read"); anything that reads a pane-sized glass plane through the window's own
  buffer sees the placeholder slab, not the composite.

## Files

Captures land in the output directory (default
`$TMPDIR/baia-pane-glass-legibility`), outside the repo:

```
calibration.png            bare backdrop through this run's tone response
sweep-aNNN.png             -l window buffer at α = 0.NN (flat-slab negative result)
sweep-aNNN-screen.png      -R screen composite, the measured file
wallpaper-a000.png         α 0.00 over the real wallpaper (+ -screen companion)
wallpaper-a065.png         α 0.65 over the real wallpaper (+ -screen companion)
results.txt                measure.py's tables, the run of record
```

`washsweep.swift` renders and captures; `measure.py` reads the captures with
`Diagnostics/lib/pixel.py`'s decoder and prints the tables. The band fractions
are a contract between the two files; change one, change both.
