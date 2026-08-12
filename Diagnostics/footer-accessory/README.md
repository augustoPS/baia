# footer-accessory

Plan 5 of the design v6 line (`vault/projects/baia/plans/2026-08-07-design-v6-native-everything.md`):
the accessory-controller probe. The question:

**Does a footer built as an `NSSplitViewItemAccessoryViewController` receive an
optic over scrolling content that baia's hand-managed footer cannot have, and
what does each `preferredScrollEdgeEffectStyle` actually look like beside the
hand-managed control?**

The scroll edge effect is the one platform behavior baia's hand-managed bars
cannot receive (research report: DTS confirms custom static content does not get
it, forums 815816; there is no AppKit API for arbitrary custom bars,
FB19629432). 26.1 added `preferredScrollEdgeEffectStyle` (`.automatic` /
`.soft` / `.hard`) on accessory controllers only. V5 ruled adoption out on
sidebar grounds; ruling 1 ("go full macOS") reopened it for the footer as an
exploration, per ruling 4 with no cost threshold.

What would be false if this probe rendered four indistinguishable bars and the
platform were behaving as documented: either the effect does not engage for a
bottom-aligned accessory in this window arrangement (a real finding — it bounds
what adoption would buy), or the probe failed to put scrolled content under the
bar (a harness bug, checkable in the captures: the content rows must visibly
continue beneath the bar's strip).

## The arms

Four windows, side by side, same content: a dark theme-background document of
monospaced rows (drawn at the terminal's 11.5 pt scale) scrolling slowly under a
22 pt bar. The bar's segments and geometry are read off `PaneChrome`
(`PaneStatusBarMetrics`, `MaterialSet.dark`) rather than transcribed.

| Arm | Bar construction | Edge effect |
|---|---|---|
| `1-hand-managed` | The shipped construction, reproduced: custom view, `fillChrome` fill (α 0.44), hairline on the outer edge, drawn segments. Overlaid on the scroll view; content slides under it. | None, and none possible. The control every accessory arm is read against. |
| `2-accessory-automatic` | `NSSplitViewItemAccessoryViewController`, bottom-aligned, segments drawn with **no fill** — the system supplies the bar's material. | Whatever `.automatic` decides. This is what 26.0 would give. |
| `3-accessory-soft` | Same. | `preferredScrollEdgeEffectStyle = .soft` (26.1+). |
| `4-accessory-hard` | Same. | `preferredScrollEdgeEffectStyle = .hard` (26.1+). |

The accessory arms draw no background on purpose. The research's adoption note
("remove custom backgrounds from bars — they might overlay or interfere with
Liquid Glass or other effects the system provides") means the honest accessory
arm lets the system own the material. An accessory arm that kept the
`fillChrome` fill would measure the interference, not the offer.

## What this probe deliberately does not measure

- **Adoption cost.** Session restore, focus rules, and the hand-managed pane
  tree are plan 6's blast radius, written only if the ruling is adopt. This
  probe's windows have no PTY, no pane tree, and no `SIGWINCH` exposure.
- **The focused bar.** `fillThick` steps on focus; every arm here is unfocused.
- **Bright content.** One controlled backdrop (the dark theme background), same
  reasoning as `glass-backdrop/`: an arm graded over wallpaper grades against a
  photograph. The live pass owns the bright-desktop question.

## Running it

```
./run.sh [output-directory]
```

Builds `PaneChrome` (+ deps) via `Diagnostics/lib/build-packages.sh`, compiles
the probe, puts four windows on screen for about eighteen seconds while the
content scrolls, and writes two captures per arm into the output directory
(default: a scratch directory under `TMPDIR`): `<arm>.png` from
`screencapture -l` (the window's own backing store) and `<arm>-screen.png` from
`-R` (the composite cross-check; its absolute values move with display
brightness and are not graded — see `glass-backdrop/`'s capture notes for the
measured divergence).

Meets the `SAFE_PROBES` standard: `.accessory` activation policy,
`orderFrontRegardless()`, no window can become key or main, nothing is quit or
relaunched. Windows appear over whatever is in front for the duration and are
ordered out again.

Version gate: `.soft`/`.hard` need macOS 26.1+. On an older system arms 3 and 4
still run but print that the style request was unavailable, so a capture from
such a machine cannot be mistaken for a styled arm.

## Exit

The owner rules adopt, reject, or partial — on the captures plus the live look,
against the control. The ruling lands in the v6 plan; plan 6 exists only on
adopt.
