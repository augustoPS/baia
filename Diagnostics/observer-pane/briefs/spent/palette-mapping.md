# Two palette mappings live in the app target, one of them the shape that broke before

You are working in a git worktree of baia on branch `observer/palette-mapping`.

## The item

`Diagnostics/observer-pane/app-target-candidates.md` surveyed `Sources/` for logic
that needs no `NSWindow` and found two in `CommandPaletteController`:

| where | what |
|---|---|
| `Sources/CommandPaletteController.swift:268` | `private static func kind(of kind: Project.Kind) -> PaletteRowKind` |
| `Sources/CommandPaletteController.swift:372` | `private static func runs(for status: RepositoryStatus) -> [PaneStatusRun]` |

Both map between two packages' own vocabularies with nothing of the controller in
them. `runs(for:)` is built entirely through `PaneStatusSegments.build`, which is
already a package function. `kind(of:)` maps `GitWorkspace.Project.Kind` to
`PaneChrome.PaletteRowKind`.

The rule they break: anything answerable without a descriptor or an `NSWindow`
belongs in a package, and the app target keeps only what needs AppKit.

**`kind(of:)` carries the risk this wave exists to catch.** The survey records it
as a three-case enum-to-enum mapping with no `default:` arm, "the same risk shape
as `direction(of:)` and as the historical `--kinds` bug". `--kinds` was wrong the
first time it moved, and it was wrong in exactly this shape: a mapping whose arms
were never all exercised.

## The goal, and it is the same size as the scope

Both functions live in `Packages/PaneChrome`, are exercised by package tests, and
the app target compiles against them.

Not "the command palette is correct". You are moving code and pinning what it
already does. If a move reveals the mapping was wrong, say so in your final message
and leave it wrong: a fix smuggled inside a move is a change nobody can bisect.

## The first step, and it comes before any move

**`kind(of:)` gets an exhaustive package test written first**, against the copy
still in the app target, with one assertion per case of `Project.Kind` and no
`default:` in the test either. Exhaustive means the test fails to compile when a
case is added, not that it happens to cover three today.

That ordering is the whole point. A test written after the move tests whatever the
move produced, and the `--kinds` mapping is on record as having moved wrong once
already.

`runs(for:)` is a composition over `PaneStatusSegments.build` and is small enough
to move test-first in one step.

## Scope

`Packages/PaneChrome` and the call sites in
`Sources/CommandPaletteController.swift`.

Inside `PaneChrome`, `kind(of:)` lands beside `PaletteRowKind` in
`PaletteRow.swift` and `runs(for:)` beside `PaneStatusSegments.build` in
`PaneStatusSegments.swift`.

**Another brief in this wave is also landing in `PaneChrome`**, in
`PaneTheme*.swift` and `PaneStatusBarMetrics.swift`. Those two files and the two
above are the boundary between you: do not edit them, and do not add a shared
helper either of you would have to own. If your move seems to need one, stop and
say so rather than reaching across.

**The app target is in scope**, and it has to be: a function that moves out of a
file leaves a call site behind, and a call site that does not compile is not a
move.

Nothing else in `Sources/`.

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
