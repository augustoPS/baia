# The focus accent set: one honest rename and two new derivations

You are working in a git worktree of baia on branch `observer/accent-set`.

## The item

`FocusAccent` has five cases. Four of them name their derivation honestly. One
does not, and its own documentation says so:

> Midnight names the hue, not the value. A footer ink has to clear 4.5:1 on the
> bar, so the repair chain decides how dark it is allowed to be and it lands
> lighter than the name suggests.
> `Packages/BaiaSettings/Sources/BaiaSettings/ChromeStyle.swift:35`

So `midnight` promises a darkness the repair chain is not allowed to deliver.
The fix is to give that derivation a name that matches where it lands, and to add
a genuinely dark option beside it rather than pretending the existing one is it.

The standing rule this works inside, and it does not change: a config names a
derivation and lets the theme decide what it resolves to
(`ChromeStyle.swift:5-10`). No case gains a hex. Every new case is a blend of
slots the theme already owns.

## The goal, and it is the same size as the scope

`FocusAccent` has seven cases, `PaneTheme.accent(for:)` resolves each, and the
catalog rows the contrast work is measured against go from 2315 to 3241, every
new row passing repair and the collision guard.

| case | derivation | change |
|---|---|---|
| `accent` | `focusedAccent` | unchanged, still the default |
| `bone` | `foreground` → `ansi[15]`, 0.55 | unchanged |
| `ansi5` | raw `ansi[5]` | unchanged |
| `ansi6` | raw `ansi[6]` | unchanged |
| `twilight` | `ansi[4]` → `ansi[5]`, 0.5 | **renamed** from `midnight`, same value |
| `nightshade` | `ansi[5]` → `background`, 0.5 | **new** |
| `sea` | `ansi[6]` → `ansi[4]`, 0.5 | **new** |

Not "the accents look good". You are moving one name and adding two derivations
that the existing measurement machinery then judges. If the catalog says a new
blend cannot be repaired into range on some themes, that is a result: report it
with the theme names and leave the case in. Do not tune a fraction until the
number looks nice.

The two fractions given for `nightshade` and `sea` are starting values, not
findings. If the catalog run argues for a different one, change it and say why in
the commit.

## The first step, and it comes before either new case

**The rename lands as its own commit, with nothing else in it.** `midnight`
becomes `twilight` in `FocusAccent`, `midnightAccent` becomes `twilightAccent` in
`PaneTheme`, and every reference follows. `make build` and `make test` are green
before a single new case exists.

A rename and an addition in one commit cannot be bisected, and this is the commit
most likely to be blamed later: it is the one that touches the value the owner is
already using.

## The compatibility alias, and it is required

The old spelling `midnight` must keep decoding, to `twilight`, and there must be
a test that proves it.

This is not reuse and the distinction matters. `midnight` always meant the
`ansi[4]`→`ansi[5]` blend, and after this it still resolves to exactly that
colour under its new name, so an existing `~/.config/baia/config.json` renders
identically and silently, which is correct. What would be wrong is pointing
`midnight` at `nightshade`: the value would stay valid, get reported by nothing,
and quietly change what the owner sees. `SettingsDecoder` only reports spellings
it does not recognise (`SettingsDecoder.swift:69-70, 256`), so it cannot catch
that for you.

`nightshade` is a new spelling and gets no alias.

## Scope

`Packages/BaiaSettings` and `Packages/PaneChrome`, plus their tests.

The app target is in scope **only** if a call site fails to compile. If it does,
fix the call site and nothing else in `Sources/`. If it seems to need a design
change there, stop and say so.

## Verify

`make build` **and** `make test`, from the worktree root.

Both, and neither is optional. `Sources/` imports both packages you are changing,
so `make test` cannot see a call site you broke; `make build` runs no test, so it
cannot see a derivation you got wrong. The catalog assertions live in the package
tests and they are the actual verification here.

Measured in a fresh worktree: `make build` about 25 seconds cold, the first
`make test` about 95 across twelve suites, every `make test` after that about 8.
A command that looks stuck is usually building.

## Rules

Commit each green step separately. Never run a `Diagnostics/*/run.sh`, `make run`,
or anything that quits baia: you are running inside it.
