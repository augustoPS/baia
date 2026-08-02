# Theme catalog sweep

`./run.sh` from anywhere. It builds `BaiaSettings`, `PaneChrome` and ghostty's
theme catalog from source, crosses all 485 shipped themes with all seven
`FocusAccent` cases, and grades every one of the 3395 rows through
`PaneTheme.accent(for:)` and `PaneTheme.attentionColour(_:behavior:)`. Nothing is
drawn, no window opens, no app is touched.

## The question

**Whether a contrast promise measured on one theme holds on the other 484, and
whether the numbers the doc comments quote are still true.**

`PaneChrome`'s package tests grade six themes: Dark Pastel, a light one, and four
constructed to have a specific defect. That is the right scope for them, because
a test asserts a rule and six themes chosen for their shapes exercise a rule
better than 485 chosen by nobody. What six themes cannot do is notice that the
catalog they are a sample of has changed underneath the prose.

It had. Every present-tense figure in `PaneTheme` and `ChromeStyle` said 463
themes and 2315 rows while the shipped catalog held 485 and 3395, and
`Sources/SettingsView.swift` had said 485 since the day it was written. Nothing
in the repo could see the disagreement, because nothing in the repo could count.

So this probe fails in two different ways, and they mean different things:

- **A rule broke.** A row does not clear 4.5:1 where it is drawn, or `derive`
  cannot separate the attention fill on a theme whose palette had somewhere to
  go. Fix the code.
- **A pinned figure moved.** A libghostty bump changed the catalog. Nothing is
  wrong. Re-measure, then move the prose in `PaneTheme.swift`, `ChromeStyle.swift`
  and `AttentionColourTests.swift` and the `Pinned` values in `catalogsweep.swift`
  in the same commit.

The second is the one worth having. A number in a doc comment that no longer
holds reads exactly like one that does.

## What it grades

| Rule | What would be false if it passed and the code were wrong |
|---|---|
| repair | A focused pane's own name is unreadable on its own footer on some theme nobody tried. `inkFocus` is graded, not the raw derivation: the accent is repaired on the way to the screen and grading it before the chain is measuring a colour where it is not drawn |
| ink, mutedInk | An asking pane's footer is filled with a colour its own text cannot be read on. Both tiers, on every fill the two repair behaviours can produce |
| tier order | Tier 4 comes back louder than tier 3 on a mid-luminance fill, so a filled footer reads with its quietest tier shouting |
| the floor | `derive` hands back a colour under ΔE00 10 from focus, from the bar or from the terminal, on a theme whose palette had a slot that would have cleared it. Retro is the one theme allowed to miss, and `deriveOnAThemeWithNothingToBlendTowardsStillAnswers` is why |
| the pins | The catalog moved and the prose did not |

`stock` is not graded. Its documented answer to a collision is "nothing", and
`aFillThatIsTheBarItFillsIsACollisionToo` pins that on purpose. `noCollision` is
not graded either: it falls back to `alert` by definition, so on a theme whose
alert is itself the colliding colour it lands short, and that is the setting
doing what it says.

## The controls, and why there are three

Each imitates one specific wrong measurement, and `run.sh` inverts all three.

| Control | The mistake it imitates |
|---|---|
| `break-repair` | Grading the raw derivation instead of the repaired ink. 1851 rows fail |
| `break-derive` | Grading `stock`, which promises nothing, and reporting on `derive`, which promises the floor. 484 themes fail |
| `break-pins` | Every accent replaced by the bar it is drawn on, so the counted figures move. 8 pins fail |

**This started as one control and the one control passed.** It replaced
`nightshade` with the bar it is drawn on, which sounds like maximum damage and is
not: `nightshade`'s pinned raw-clear count is already 0 of 485, the repair chain
lifts a bar-coloured accent like any other, and `derived(from:)` still had a full
palette to walk. The sabotage was invisible to every pin and every rule, and the
run reported a clean sweep. That is the failure this whole directory's README
warns about, found here rather than believed away, and it is why the controls are
now one per rule instead of one per probe.

## Where it sits relative to the package tests

The packages own the rules. This owns the population.

A rule asserted here and nowhere else would be a rule with no home: it would be
re-derived in a script that has to be run by hand rather than living in the
one-second loop `make test` gives. So the probe adds no rule of its own. Every
threshold it uses is read off `PaneTheme` — `minimumTextContrast`,
`minimumAttentionSeparation` — rather than written down again.

The one exception is `separation(_:in:)`, which restates
`PaneTheme.attentionSeparation(of:)` because that method is internal to the
package and this is a separate binary. The package tests must never do this, for
the reason `attentionSeparation` is internal rather than private in the first
place: a test that spells the rule out again asserts its own copy of it. Here the
cost is that a change to the measure has to be copied by hand, and the header
says so.

## Running it

`upstream/libghostty-spm` is gitignored and reproduced from two tracked files, so
`run.sh` calls `make upstream` when the checkout is absent. That target clones and
patches; it does not generate, build or launch anything.

The probe opens no window and restarts nothing, so it is safe from inside a baia
pane. `guard-baia-alive.sh` blocks it anyway: its rule is
`Diagnostics/<name>/run.sh` with no exceptions, which is the right shape for a
guard that cannot read a script to find out what it does. Run it from a terminal
outside baia, or call `catalogsweep` directly.
