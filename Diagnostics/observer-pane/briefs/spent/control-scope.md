# Four control-channel rules live in the app target

You are working in a git worktree of baia on branch `observer/control-scope`.

## The item

`Diagnostics/observer-pane/app-target-candidates.md` found four in
`ControlServer`, each expressed entirely in types `PaneControl` already owns:

| where | what | the survey's note |
|---|---|---|
| `Sources/ControlServer.swift:747` | `private func scope(of actor: ControlPaneID) -> [ControlPaneID]` | walks `children(of:)` and `peers(of:)` into one ordered, deduplicated list. A graph traversal with no reason to sit outside the package that owns the graph |
| `Sources/ControlServer.swift:523` | `private func gate(_ verb: ControlVerb) -> ControlError?` | a pure switch over `verb.settingGate` and two `Bool`s, `isReadAllowed` and `isRunAllowed`, which are the only `self` state it reads and **could both be parameters** |
| `Sources/ControlServer.swift:1125` | `private func answer(for drain: Drain) -> ControlResponse` | pure formatting, both types are the package's |
| `Sources/ControlServer.swift:1129` | `private func answer(for batch: EventBatch) -> ControlResponse` | the same shape |

`scope(of:)` is worth a package test on its own account: it is what decides which
panes an actor may see, and it is the rule the observer's whole topology rests on.
A sibling-blind scope is why an observer opened as a fourth split sees one pane.

## The goal, and it is the same size as the scope

The four functions live in `Packages/PaneControl`, are exercised by package tests,
and the app target compiles against them.

Not "the capability model is correct". You are moving code and pinning what it
already does. If a move reveals the behaviour was wrong, say so in your final
message and leave it wrong.

## The first step, and it comes before the move it belongs to

**`gate` is two commits, not one.** It reads `isReadAllowed` and `isRunAllowed`
off `self`, so it cannot move as it stands.

1. Lift the two `Bool`s to parameters **in place**, in `Sources/`, with the
   function still where it is. Commit that alone, green.
2. Then move it.

One commit doing both is a relocation and a signature change entangled, and a
bisect over it cannot say which one broke anything. The survey gives this exact
caveat to `gate` and to nothing else in the group, so it is the one row that
cannot be done the quick way.

`scope(of:)`, being a traversal, gets its package test before it moves rather than
after: a test written against the moved copy pins whatever arrived.

## Scope

`Packages/PaneControl` and the call sites in `Sources/ControlServer.swift`.

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
named only the second of those.

Measured in a fresh worktree on 2026-08-01, so a slow command is not a stuck one:
`make build` takes about 25 seconds cold, and the first `make test` about 95, with
every `make test` after that about 8.

## Rules

Commit each green step, one move per commit. Never run a `Diagnostics/*/run.sh`,
`make run`, or anything that quits baia: you are running inside it.
