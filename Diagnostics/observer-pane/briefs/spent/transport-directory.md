# The socket directory is created twice, and the package copy is the untested one

You are working in a git worktree of baia on branch `observer/transport-directory`.

## The item

`Diagnostics/observer-pane/app-target-candidates.md` surveyed `Sources/` for logic
that needs no `NSWindow` and found two in `ControlTransport`:

| where | what |
|---|---|
| `Sources/ControlTransport.swift:705` | `private static func createDirectory(for socketPath: String) -> Bool` |
| `Sources/ControlTransport.swift:719` | `private static func reason(_ code: Int32) -> String` |

The first is not merely misplaced, it is a second copy. Its own doc comment says
it exists "the way `SessionStore` creates the one it shares with `session.json`",
and `Packages/WorkspaceLayout/Sources/WorkspaceLayout/SessionStore.swift:250`
holds `private static func createDirectory(atPath path: String) -> Bool` whose
body is the same 0700 component walk, down to treating `EEXIST` as success. One
of the two lives in a package and neither is exercised by a package test, because
the package copy is `private` to a type whose tests reach it only through a save.

`reason(_:)` is a `strerror` wrapper. Its argument is an errno value rather than a
descriptor, so nothing about it needs the app target.

The rule they break: anything answerable without a descriptor or an `NSWindow`
belongs in a package, and the app target keeps only what needs AppKit.

## The goal, and it is the same size as the scope

One directory walk lives in `WorkspaceLayout`, is exercised by package tests,
and both `SessionStore` and `ControlTransport` call it. `reason(_:)` lives in
`PaneControl` and is exercised by a package test. The app target compiles against
both.

Not "socket setup is correct" and not "session saving is correct". You are
consolidating two copies of one walk and pinning what it already does. If the two
copies turn out to disagree, say so in your final message and pick the
`SessionStore` behaviour, since that is the one with the longer doc comment
stating its intent; do not quietly improve either.

## The first step, and it comes before any move

**`SessionStore.createDirectory(atPath:)` gets its package test written first**,
against the copy that is already in the package and while it is still `private`
(widen it to `internal` for the test and no further, in its own commit). The test
must pin the three things its doc comment claims:

- a relative path is refused rather than built from `/`
- `EEXIST` is success, so calling it twice in a row succeeds twice
- a component that already exists as a regular file fails, via `ENOTDIR` on the
  next `mkdir`

Only once that test exists and passes should `ControlTransport` lose its copy. The
socket-path-to-parent-directory derivation (`deletingLastPathComponent`) is the
caller's business and stays at the call site: what moves is the walk, not the
derivation.

`reason(_:)` is small enough to move test-first in one step.

## Scope

`Packages/WorkspaceLayout`, `Packages/PaneControl`, and the call sites in
`Sources/ControlTransport.swift`.

**The app target is in scope**, and it has to be: a function that moves out of a
file leaves a call site behind, and a call site that does not compile is not a
move.

Nothing else in `Sources/`. If a move seems to need a second app-target file, stop
and say so.

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
