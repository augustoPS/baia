# Four activity rules live in the app target

You are working in a git worktree of baia on branch `observer/activity-rules`.

## The item

`Diagnostics/observer-pane/app-target-candidates.md` surveyed `Sources/` for
logic that needs no `NSWindow` and found four in `PaneActivityTracker`, all of
them operating on types `PaneActivity` already owns:

| where | what |
|---|---|
| `Sources/PaneActivityTracker.swift:188` | `private static func isIdle(_ activity: PaneActivity) -> Bool` |
| `Sources/PaneActivityTracker.swift:297` | `private static func isWorkingAgent(_ activity: PaneActivity) -> Bool` |
| `Sources/PaneActivityTracker.swift:199` | `private func shellPid(above pid: pid_t, in tree: [ProcessSnapshot]) -> pid_t?` |
| `Sources/PaneActivityTracker.swift:217` | `private static func normalized(_ name: String) -> String` |

The rule they break: anything answerable without a descriptor or an `NSWindow`
belongs in a package, and the app target keeps only what needs AppKit. Three of
the five rules that moved out before this were **wrong or unenforced** when they
arrived, which is the argument for moving them rather than for trusting them.

## The goal, and it is the same size as the scope

The four functions live in `Packages/PaneActivity`, are exercised by package
tests, and the app target compiles against them.

Not "activity detection is correct". You are moving code and pinning what it
already does. If a move reveals the behaviour was wrong, say so in your final
message and leave it wrong: a fix smuggled inside a move is a change nobody can
bisect.

## The first step, and it comes before any move

**`shellPid` gets its package test written first**, against the copy still in the
app target, and the test must pin the two things the survey names:

- the 64-iteration cap, so a cycle in the process tree terminates
- that the answer excludes the shell's own pid

The survey's words: those are "exactly the kind of thing worth a package test
rather than a comment". A test written after the move tests whatever the move
produced, which is the one thing it must not do.

Only once that test exists and passes should `shellPid` move. The other three are
small enough to move test-first in one step each.

## Scope

`Packages/PaneActivity` and the call sites in `Sources/PaneActivityTracker.swift`.

**The app target is in scope**, and it has to be: a function that moves out of a
file leaves a call site behind, and a call site that does not compile is not a
move. This is the correction to the 2026-08-01 briefs, which forbade the app
target and then asked for changes that reach it.

Nothing else in `Sources/`. If a move seems to need a fifth file, stop and say so.

## Verify

`make build` **and** `make test`, from the worktree root.

Both, and neither is optional. `make test` never compiles `Sources/`, so it
cannot see a call site you broke; `make build` never runs a test, so it cannot see
behaviour you changed. On 2026-08-01 a branch was merged-blocked because its brief
named only the second of those. The first `make test` compiles cold and takes
about 95 seconds; every run after is about 8.

## Rules

Commit each green step, one move per commit. Never run a `Diagnostics/*/run.sh`,
`make run`, or anything that quits baia: you are running inside it.
