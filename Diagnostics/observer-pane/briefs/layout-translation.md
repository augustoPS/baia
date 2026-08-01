# Four translation rules live in the app target

You are working in a git worktree of baia on branch `observer/layout-translation`.

## The item

`Diagnostics/observer-pane/app-target-candidates.md` found four in
`ControlAdapter` that translate between two packages' vocabularies and touch no
window on the way:

| where | what | belongs in |
|---|---|---|
| `Sources/ControlAdapter.swift:604` | `private static func direction(of direction: ControlDirection) -> FocusDirection` | `WorkspaceLayout`, beside `FocusDirection` |
| `Sources/ControlAdapter.swift:565` | `private static func build(_ node: ControlLayoutNode, createdBy: PaneID, into states: inout [PaneState]) -> PaneTree` | `WorkspaceLayout`, beside `PaneTree` and `PaneState` |
| `Sources/ControlAdapter.swift:592` | `private static func existingDirectory(_ path: String) -> String?` | `WorkspaceLayout` or `PaneControl`, your call, say which and why |
| `Sources/ControlAdapter.swift:156` | `private static func name(of attention: PaneStatus.Attention) -> String?` | `PaneChrome`, beside `PaneStatus.Attention` |

## The goal, and it is the same size as the scope

The four functions live in `Packages/WorkspaceLayout` and `Packages/PaneChrome`,
are exercised by package tests, and the app target compiles against them.

Not "control-to-workspace translation is correct". You are moving code and pinning
what it already does. If a move reveals the behaviour was wrong, say so in your
final message and leave it wrong.

## The first step, and it comes before any move

**`direction(of:)` gets an exhaustive case test before it moves**, one assertion
per `ControlDirection` case, written against the copy still in the app target.

The survey names why, and it is not a general preference: the mapping has no
`default:` arm, and it is "the exact shape the `--kinds` mapping was wrong in when
it first moved". A mapping of that shape moved without exhaustive coverage has
already been wrong once in this codebase, in this exact way. A test written after
the move pins whatever arrived rather than what was there.

`build(_:createdBy:into:)` is recursive and takes an `inout`, so it gets its own
test before moving too: a tree builder is the kind of thing that looks right and
produces the wrong shape at depth two.

The other two are small enough to move test-first in one step each.

## Scope

`Packages/WorkspaceLayout`, `Packages/PaneChrome`, and the call sites in
`Sources/ControlAdapter.swift`.

**The app target is in scope**, and it has to be: a function that moves out of a
file leaves a call site behind, and a call site that does not compile is not a
move. This is the correction to the 2026-08-01 briefs, which forbade the app
target and then asked for changes that reach it.

Nothing else in `Sources/`. If a move seems to need a second file, stop and say so.

## Verify

`make build` **and** `make test`, from the worktree root.

Both, and neither is optional. `make test` never compiles `Sources/`, so it cannot
see a call site you broke; `make build` never runs a test, so it cannot see
behaviour you changed. On 2026-08-01 a branch was merged-blocked because its brief
named only the second of those. The first `make test` compiles cold and takes about
95 seconds; every run after is about 8.

## Rules

Commit each green step, one move per commit. Never run a `Diagnostics/*/run.sh`,
`make run`, or anything that quits baia: you are running inside it.
