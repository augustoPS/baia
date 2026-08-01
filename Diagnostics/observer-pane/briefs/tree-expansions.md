# Tree expansions do not survive a relaunch

You are working in a git worktree of baia on branch `observer/tree-expansions`.

## The item

The focus round trip is fixed: on 2026-07-31 the open set moved off
`FilesSurface.tree`'s `didSet` and onto the anchor, as `FileTreeExpansions` in
PaneChrome (`retarget(to:keeping:)`, five tests). The storage question was
answered session-scoped, so the map lives on the surface and dies with the
window. What is left is the half that was priced and deferred: a quit still
forgets.

## What to build

`fileTreeExpansions: [String: [String]]?` beside `sidebar` in `SessionSnapshot`,
optional so an old file decodes as nil, pruned in `SessionStore.reconciled` to
the anchors of surviving panes so the file cannot outgrow the workspace.

## Scope, and it is hard

**Package code only.** `SessionSnapshot` is at
`Packages/WorkspaceLayout/Sources/WorkspaceLayout/SessionSnapshot.swift:9`,
`SessionStore.reconciled` at `.../SessionStore.swift:109`, and
`FileTreeExpansions` at
`Packages/PaneChrome/Sources/PaneChrome/FileTreeExpansions.swift:21`.
Everything you write must be verifiable by `make test`.

**Do not wire the app target.** `Sources/FilesSurface.swift` and
`Sources/PaneTreeController.swift` are where this eventually connects, and the
app target has no test target, so a change there is unverifiable from here. Stop
at the package boundary and say in your final message what the wiring would need.

## Verify

`make test` from the worktree root. The first run compiles cold and takes about
95 seconds; every run after is about 8.

## Rules

Test first. Commit each green step. Never run a `Diagnostics/*/run.sh`, `make
run`, or anything that quits baia: you are running inside it.
