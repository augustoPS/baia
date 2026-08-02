# Verify wave five by mutation

You are verifying baia's fifth executor wave, which was reviewed only by an
in-pane observer agent and then merged. You are in a detached worktree at the
current `main` tip. Everything the wave produced is in your history.

## Read first, before touching code

- `CLAUDE.md` at the root of this worktree. Build and test rules. Never run bare
  `xcodebuild`. `make build` (~25s cold) compiles the app target; `make test`
  (~95s cold, ~8s after) runs the twelve package suites and **never** compiles
  `Sources/`. Work touching a package the app target imports needs both.
- `~/Projects/vault/journal/2026-08-02-appearance-wave-and-the-command-anchor.md`,
  this wave's own account of itself.

**Never run a `Diagnostics/*/run.sh` and never run `make run-attached`.** Several
probes quit or relaunch the app you are sitting in. You are sitting in it.
`Diagnostics/theme-catalog/run.sh` is the one exception you may need; read it
first and only run it if it launches nothing.

## The wave under review

Two branches, both already merged into `main`:

- `observer/accent-set`, merge commit `e8b1020`. Took the focus accents from five
  named derivations to seven, adding `nightshade` and `sea`, plus a theme-catalog
  sweep tool. Diff: `git diff e8b1020^1 e8b1020`.
- `observer/dev-icon`, merge commit `aa7c543`. Gave the Debug build its own icon
  through a per-icon accent in `Icon/make-icon.swift`, wired through `project.yml`
  and `Info.plist`. Diff: `git diff aa7c543^1 aa7c543`.

## Why you are here

The observer that passed this wave judges what a screen asserts, not what the
code does. On the previous wave it passed a test that could not fail:
`palette-mapping` claimed a fourth `Project.Kind` case would fail its file to
compile, but the test was three assertions with no switch of its own, so the
guarantee belonged to the implementation and the test took credit for it. That
defect was found only by **mutation**: breaking the implementation and watching
the suite stay green.

Assume the same class of defect is present here until you have proved otherwise
the same way.

## Method

For every substantive claim a test or a doc comment in this diff makes, do not
read it and agree. Break the thing it claims to protect, run `make test` (and
`make build` where the app target is involved), and record whether the suite
actually goes red.

- A test that stays **green** against a mutation of the exact behaviour it names
  is a finding.
- Revert every mutation with `git checkout --` before moving to the next one.
- Never commit, never amend, never push, never leave the tree dirty. Check
  `git status --porcelain` is empty before you finish.

## Hypotheses to attack

These are starting points, not a checklist. Follow what you actually find.

1. `nightshade` is documented as dark in the derivation and lifted in the ink for
   all 485 shipped themes, asserted by a test named
   `nightshadeIsDarkInTheDerivationAndLiftedInTheInk`. Does that test fail if the
   derivation stops being dark, or if the repair chain stops lifting? Or does it
   assert two things that are both true by construction?
2. The seven-accent set is enum-shaped. Would an eighth case fail to compile, or
   is there a `default:` somewhere that would silently take it? This is exactly
   the shape of the previous wave's defect and of the historical `--kinds` bug.
3. `Diagnostics/theme-catalog/catalogsweep.swift` produced the contrast figures
   the wave's claims rest on. Does its arithmetic implement the contrast ratio it
   says it does, and does the 485-theme count match what the code can enumerate?
   A sweep that measures the wrong thing makes every figure downstream of it
   wrong while looking authoritative.
4. `dev-icon` wired an accent per configuration through `project.yml` into
   `Info.plist`. `CLAUDE.md` warns that XcodeGen silently overwrites `Info.plist`
   and `baia.entitlements` with stubs if `info:` or `entitlements:` keys are added
   to the target. Check the wiring did not introduce that, and that `make gen` is
   idempotent: run it, then `git status --porcelain`. A dirty `Info.plist` after
   `make gen` is a finding.
5. Anything matching a bundle path must accept both `baia.app` and `baia-dev.app`,
   and `baia-dev.app` does not contain the substring `baia.app`. Did this wave
   introduce a new path or substring match handling only one of them?

## Output

Write your report to `VERIFY-WAVE-FIVE.md` at the root of this worktree, and also
print it. No preamble.

For each finding: `file:line`, one sentence naming the defect, the exact mutation
you ran, and what the suite did. Green against the mutation means confirmed;
red means the test works.

Separate **CONFIRMED** findings from what you suspected and **REFUTED**, and
state the refutations too. A refutation you verified is worth as much as a
finding. If the wave is clean, say so plainly and show the mutations that failed
to break anything. Rank findings most severe first.

Do not fix anything. This is a read-and-prove pass only.
