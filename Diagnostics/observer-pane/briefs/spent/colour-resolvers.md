# Four colour resolvers were written fresh, and only two of them agree

You are working in a git worktree of baia on branch `observer/colour-resolvers`.

## The item

`Diagnostics/observer-pane/app-target-candidates.md` found four separate
"map a semantic role to an `RGB` through a `PaneTheme`" functions in `Sources/`,
plus one layout-constant lookup beside the last of them:

| where | what |
|---|---|
| `Sources/ChangesSurface.swift:508` | `static func colour(_ role: Role, in theme: PaneTheme) -> RGB` |
| `Sources/FilesSurface.swift:388` | `private func colour(of mark: FileChangeMark) -> RGB` |
| `Sources/CommandPaletteView.swift:312` | `private func colour(for emphasis: PaneStatusEmphasis) -> RGB` |
| `Sources/PaneStatusBarView.swift:589` | `private func colour(for emphasis: PaneStatusEmphasis) -> RGB` |
| `Sources/PaneStatusBarView.swift:574` | `private func leading(for role: PaneStatusSegmentRole, busy: Bool) -> Double` |

All five return a value, none takes a view, and none returns an `NSColor`.
`PaneTheme` already owns one tested resolver of this shape,
`PaneTheme.accent(for:)`.

The line number for `FilesSurface` is `388` and not the survey's `372`: the
byte-carrying work moved it. Trust the signature over the number in every row
here.

**The survey calls all four "near-identical" and that is wrong for one pair**,
which is the first thing to know before you consolidate anything:

- `ChangesSurface.colour(_:in:)` and `FilesSurface.colour(of:)` genuinely are one
  policy over two enums. Both send staged to `theme.staged`, unstaged to
  `theme.warn`, untracked to `theme.inkFaint` and conflict to `theme.alert`.
- The two `colour(for emphasis:)` share a name and a signature and nothing else.
  `CommandPaletteView`'s is one line, `theme.color(for:focused:on:)` with
  `focused: true` and the panel background. `PaneStatusBarView`'s takes the same
  call as its ordinary arm but has a second: when `fillsBarForAttention` is set,
  every tier collapses onto `mutedInk`/`ink` over the terminal background, for the
  reason its doc comment gives about a fill reversing the direction the repair
  chain pushes in.

## The goal, and it is the same size as the scope

The mark-colour policy lives once in `Packages/PaneChrome`, exercised by a package
test, with both surfaces calling it. The attention-fill collapse lives in
`PaneChrome` beside `PaneTheme.color(for:focused:on:)`, exercised by a package
test. `leading(for:busy:)` lives in `PaneChrome` beside the other bar metrics.
The app target compiles against all of them.

Not "the colours are right". You are moving code and pinning what it already does.
Where two copies disagree, that is a finding for your final message, not something
to reconcile: a fix smuggled inside a move is a change nobody can bisect.

## The first step, and it comes before any move

**Prove the pair agrees before making it one.** Write a package test that pins the
four-arm mark policy, then check each surface's enum against it arm by arm, in
that order, before either call site changes. "Consolidated rather than copied" is
only safe once you have shown there is one behaviour to consolidate, and the
survey's own claim of four near-identical functions already failed that test for
the other pair.

Take `PaneStatusBarView`'s resolver as **two** package functions or one with the
fill as a parameter, never as an override of the palette's. The one-line
`CommandPaletteView` version is a call with `focused: true` and a different
background; it is a call site, not a rule, and may simply call
`theme.color(for:focused:on:)` directly once the rule it does not share has moved.

## Scope

`Packages/PaneChrome` and the call sites in `Sources/ChangesSurface.swift`,
`Sources/FilesSurface.swift`, `Sources/CommandPaletteView.swift` and
`Sources/PaneStatusBarView.swift`.

Inside `PaneChrome`, this work lands in `PaneTheme.swift` /
`PaneTheme+Palette.swift` and in `PaneStatusBarMetrics.swift` for
`leading(for:busy:)`.

**Another brief in this wave is also landing in `PaneChrome`**, in
`PaletteRow.swift` and `PaneStatusSegments.swift`. Those two files and the three
above are the boundary between you: do not edit them, and do not add a shared
helper either of you would have to own. If your move seems to need one, stop and
say so rather than reaching across.

**The app target is in scope**, and it has to be: a function that moves out of a
file leaves a call site behind, and a call site that does not compile is not a
move.

Nothing else in `Sources/`. Four app-target files is the whole of it; if a move
seems to need a fifth, stop and say so.

## Verify

`make build` **and** `make test`, from the worktree root.

Both, and neither is optional. `make test` never compiles `Sources/`, so it cannot
see a call site you broke; `make build` never runs a test, so it cannot see
behaviour you changed. On 2026-08-01 a branch was merge-blocked because its brief
named only the second of those.

Measured in a fresh worktree on 2026-08-01, so a slow command is not a stuck one:
`make build` takes about 25 seconds cold, and the first `make test` about 95, with
every `make test` after that about 8.

## Rules

Commit each green step, one move per commit. Never run a `Diagnostics/*/run.sh`,
`make run`, or anything that quits baia: you are running inside it.
