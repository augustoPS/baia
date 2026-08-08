# Pane glass inactive probe

`./run.sh [output-directory]` from anywhere. Compiles the probe, produces the
KEY/INACTIVE capture pairs under `captures/`, and measures them; exits non-zero
if the window never becomes key or if any capture was occluded by another
process's window.

**NOT safe from inside a baia pane, and deliberately not in the guard's
`SAFE_PROBES` list.** This probe takes the keyboard for about two seconds,
because the question is what glass looks like while its window IS key, and a key
state cannot be photographed without holding key. Same standing as
`design-panel-key`. The discipline: the frontmost app is recorded before
anything appears, key is held only across one capture, activation is yielded
back to that app immediately, and the run verifies it landed (`state-log.txt`
records frontmost before and after). The probe reads no keyboard input; a
keystroke typed during the two seconds lands in a window that ignores it, which
is exactly the cost. Run it from a second terminal or a pane nobody is typing
into. It also covers the screen with its wallpaper underlay for about twelve
seconds (see below), the same visible-but-focusless cost `glass-backdrop` pays.

## The question

Constraint 6, the standing rejection. `NSGlassEffectView` renders "live" while
its window is key and changes appearance when it is not, and ghostty's own
`macos-glass-*` option was rejected in baia's hub for exactly that
inactive-state shift, while the terminal pixels ignore key state entirely. A
glass plane behind every pane inherits the behaviour. The owner rules on the
pairs below: is the key/inactive transition acceptable over the real wallpaper,
and does any style or tint variant escape it?

## The capture pairs (the owner rules on these)

All under `Diagnostics/pane-glass-inactive/captures/`, all from one run, same
display, same backdrop, seconds apart:

| Pair | KEY | INACTIVE |
|---|---|---|
| full frame, all three planes | `pair-KEY.png` | `pair-INACTIVE.png` |
| regular glass, no tint (the candidate) | `pair-regular-KEY.png` | `pair-regular-INACTIVE.png` |
| clear glass, no tint | `pair-clear-KEY.png` | `pair-clear-INACTIVE.png` |
| regular glass, neutral tint (ghostty's arrangement) | `pair-regular-tinted-KEY.png` | `pair-regular-tinted-INACTIVE.png` |

Also there: `pair-INACTIVE-before-key.png` (the same window before it ever took
key), `backdrop-reference.png` (the wallpaper as the glass sampled it),
`override-pretend-key.png` and the `pair-*-OVERRIDE.png` crops (the escape-hatch
arm), `state-log.txt`, `analysis.txt`, `geometry.json`.

Each plane carries a 0.42 wash of `rgb(18,20,24)` over its top half with
terminal-like `#bbbbbb` monospaced text on it (a stand-in for a pane's well, a
plausible opacity rather than a reading off `PaneChrome`), and bare glass on its
bottom half, so one pair shows both what a pane would show and what the material
does undamped.

## Findings

Measured by `analyze.py` (which reuses `Diagnostics/lib/pixel.py`) over two
bands per plane: `washed` (wash over glass, below the glyphs) and `bare` (glass
alone). Luminance is the 0..255 Rec.709-weighted mean; saturation is mean HSV S.
Two clean runs reproduced every number below to the decimal.

| Plane | Band | KEY lum | INACTIVE lum | Δ lum | KEY sat | INACTIVE sat | Δ sat |
|---|---|---|---|---|---|---|---|
| regular | washed | 71.4 | 68.8 | **+2.6** | 0.213 | 0.219 | -0.006 |
| regular | bare | 53.3 | 39.3 | **+14.0** | 0.169 | 0.183 | -0.013 |
| clear | washed | 94.0 | 79.9 | **+14.1** | 0.221 | 0.222 | -0.000 |
| clear | bare | 63.0 | 48.8 | **+14.2** | 0.228 | 0.236 | -0.008 |
| regular-tinted | washed | 51.4 | 87.4 | **-36.0** | 0.105 | 0.069 | +0.036 |
| regular-tinted | bare | 47.2 | 78.3 | **-31.0** | 0.183 | 0.193 | -0.010 |

### 1. Untinted regular glass darkens on unfocus. It does not desaturate.

The bare band drops 14 luminance units (53.3 to 39.3, about a quarter of its
key-state value; 5.5% of full scale) and saturation holds within 0.013. By eye
(`pair-regular-*.png`): the inactive pane reads darker and murkier, like a shade
pulled behind it; the text stays where it was and stays legible. It is a visible
step, not a subtle one, but it is not the gray-slab flatten ghostty's reports
describe. Through the 0.42 wash the step shrinks to 2.6 units, so a pane's
washed interior moves much less than its bare-glass margins would.

### 2. Clear glass changes character entirely. The means understate it.

`pair-clear-KEY.png` shows what the numbers cannot: when key, `clear` style is
nearly transparent with real lensing, and the wallpaper's detail comes through
sharp (the text is barely legible over bright backdrop regions, which
disqualifies it as a pane plane on its own). When inactive it falls back to a
frosted blur that looks like `regular`. A 14-unit luminance delta plus a
sharpness collapse a region mean cannot see. Compare the wheel detail in the
pair's lower halves.

### 3. Tinted glass inverts: the pane lights up when unfocused.

This is ghostty discussion #10170 reproduced. The neutral dark tint
(`rgb(18,20,24)` at 0.5) holds the pane dark while key, and is dropped by the
system on unfocus: the bands brighten by 31-36 units and the backdrop's chroma
comes through (the wallpaper's amber lamps pop in
`pair-regular-tinted-INACTIVE.png`). The shift is larger than the untinted one
and in the wrong direction, an unfocused pane drawing more attention than a
focused one. Ghostty shipped a manual `isKeyWindow`-driven overlay to hide
exactly this; the finding here says the tint, not the glass, is what makes the
transition jarring.

### 4. No escape hatch. The transition is applied outside the process.

What the API offers, from the macOS 26 SDK header (`NSGlassEffectView.h`):
`contentView`, `cornerRadius`, `tintColor`, `style` (`.regular`/`.clear`), and
nothing else until `effectIsInteractive` (macOS 27). No state override exists in
public API, and `NSVisualEffectView.state` has no glass counterpart.

The private surface was enumerated at runtime and tried:

- `_subduedState` (Int) reads 0 in every phase, key or not. It never tracks the
  transition, so there is nothing to pin.
- `_windowChangedKeyState` is the hook AppKit calls on key transitions. The
  probe's window lied `isKeyWindow == true` while genuinely inactive and invoked
  that hook on every glass view: `override-pretend-key.png` came back identical
  to `pair-INACTIVE.png`, band for band, to the decimal.
- `_tintOpacityReduced`, `_scrimState`, `_interactionState`, `_contentLensing`,
  `_variant` (1 for regular, 2 for clear), `_adaptiveAppearance`: all constant
  across the transition (`state-log.txt`).

Nothing in the view's state moves when the appearance visibly does, so the
inactive rendering is decided compositor-side from the window server's own key
state, which no in-process property can reach. If the transition must be hidden,
the ghostty-style remedy (an overlay driven by `isKeyWindow`, compensating above
the glass) is the only route this probe found; a faithful "keep it live" knob
does not exist.

### 5. Never-key and resigned-key are the same inactive.

`pair-INACTIVE-before-key.png` (window shown, never key) matches
`pair-INACTIVE.png` (after holding and resigning key) exactly on every band.
One inactive appearance, however it was reached, and rendering is deterministic:
two clean runs reproduced every number.

## Caveats, all load-bearing

- **This wallpaper, this brightness, this day.** The subject is the owner's real
  wallpaper (`~/Wallpapers/wp1941634-toyota-ae86-wallpapers.jpg`), a mostly
  dark, low-chroma photo (sampled region mean luminance 99, mean saturation
  0.40, with its chroma concentrated in the amber lamps). A bright or vivid
  wallpaper would move every absolute and could change how visible finding 1
  looks by eye. The captures are `screencapture -R`, which carries the display's
  brightness and tone response at capture time (measured in glass-backdrop's
  README), so absolutes are within-run only; the deltas are the result.
- **The wallpaper is re-presented, not the live desktop.** The desktop was
  unreachable for the whole session: the orchestrator's fullscreen terminal
  covered it at layer 0, and a probe window ordered below layer 0 gets no live
  glass sampling at all (measured first: fully occluded, `occlusionState` not
  visible, `-l` returns a flat `#141414` at every position). So a probe-owned
  underlay shows the owner's actual wallpaper file at desktop geometry
  (aspect-fill), and the glass samples that: the same pixels the desktop shows,
  minus desktop icons. `backdrop-reference.png` is the proof of what was
  sampled. When the desktop is clear, re-running gives the pairs over the real
  thing with no code change to the arrangement's meaning.
- **Sibling contamination is guarded, not assumed away.** A sibling probe's
  floating window slid over the capture rect mid-run once and was photographed
  as a flat `#b7b7b7` slab. The windows now sit above `.floating`, and every
  capture re-checks the rect for other-process occluders and fails the run if
  any appear.
- **The focus steal is real and bounded.** One key hold of about two seconds,
  no keyboard input read, focus verified returned (`state-log.txt`). `run.sh`
  must never run from inside a baia pane: keystrokes during the hold would leave
  the pane.

## What this answers for constraint 6

The standing rejection was aimed at ghostty's arrangement, and the measurement
splits it: the jarring inactive transition belongs to the **tint** (finding 3),
which baia's candidate plane does not carry. What an untinted plane inherits is
a bounded darkening (14 units bare, 2.6 through the wash) with saturation held
(finding 1), it cannot be opted out of (finding 4), and `clear` style is
disqualified twice over (finding 2). Whether the untinted step is acceptable is
the owner's call, on `pair-regular-KEY.png` versus `pair-regular-INACTIVE.png`.
