<!-- model: claude-opus-5 -->
# A pane cannot be re-placed without being destroyed

You are working in a git worktree of baia on branch `observer/pane-move`.

## The item

Layout and channel are the same act. `split` splits **the calling pane** and
stamps `createdBy` with it (`Sources/ControlAdapter.swift:303-308`), so where a
pane lands and who may see it are decided together. An orchestrator that wants
three executors stacked beside it must either build a chain, where closing a
middle pane silently orphans the ones below it, or open a second window.

A move breaks the coupling, and it is far cheaper than it sounds.
`PaneTreeController.makeViewController` answers a `.leaf(id)` with `panes[id]`
(`Sources/PaneTreeController.swift:828`), the controller that already exists, so
`rebuild()` re-parents live surfaces rather than making them. The comment at
`:842` states the cost: a rebuild is "a `SIGWINCH` to whatever is running in each
of them".

Nothing is created and nothing is closed, so `PaneGraph` is never called and the
capability model is untouched by construction.

## What to build

`PaneTree.moving(_ id: PaneID, beside: PaneID, axis: SplitAxis, before: Bool)
-> PaneTree?` in `Packages/WorkspaceLayout`, plus the app-target wiring that sets
the tree and calls `rebuild()`, plus a `move` verb in `Packages/PaneControl`
scoped exactly as `read` is, plus its CLI form
`baia move <pane> --beside <pane> --right|--down`.

**The moved pane keeps its `PaneID`, and that is the hard requirement.** Written
as `closing` then `splitting` it would mint a fresh id, and a fresh id is a fresh
surface: the shell in that pane dies and the pane graph loses an edge. The vacated
split collapses exactly as `closing` already collapses it; the pane is inserted
beside its target carrying the id it arrived with.

## The goal, and it is deliberately smaller than the feature

The tree operation, the verb, and the CLI exist; `make test` exercises the tree
operation; `make build` compiles the app target against all of it.

**Not "panes visibly move and their shells survive".** That needs a real window
and a live surface, so it cannot be verified from here, and a probe launches its
own baia and would end this run. It is the owner's pass, and it is owed rather
than done. Say in your final message what it should check: something typed in a
pane before the move still on its screen after, and the pane's pid unchanged.

This narrowing is the point rather than a compromise. The 2026-08-01 morning wave
produced two branches whose briefs claimed a goal their scope could not reach, and
the rule that came out of it is that a brief's goal and its scope must be the same
size. Yours is the wiring; the sighting is not.

## The first step, and it comes before the implementation

**Three tests, written and failing, before `moving` has a body:**

1. The moved pane keeps its `PaneID`, and `paneIDs` is the same set before and
   after. A move never changes which panes exist.
2. A move and a move back returns a tree **equal to** the original, for a pane
   whose sibling is a `.split` rather than a `.leaf`. That is the shape a naive
   implementation gets wrong, and a round trip over two leaves passes whatever you
   write.
3. Moving a pane beside itself, and moving a pane that is not in the tree, both
   answer nil rather than trapping or returning a tree with a pane missing.

Write all three red first. A test written after the implementation pins whatever
the implementation does, which for tree surgery means it pins the bug.

## Scope

`Packages/WorkspaceLayout`, `Packages/PaneControl`, `Packages/PaneCLI`, and the
call sites in `Sources/PaneTreeController.swift` and `Sources/ControlAdapter.swift`.

**The app target is in scope**, and it has to be: a verb that reaches a controller
is not a verb until the controller answers it.

Do not touch `PaneGraph`, `createdBy`, peer edges, or anything in the capability
model. If a move seems to need one of them, stop and say so in your final message:
that would mean the premise this item rests on is wrong, and it is worth more than
the feature.

## Verify

`make build` **and** `make test`, from the worktree root.

Both, and neither is optional. `make test` never compiles `Sources/`, so it cannot
see a call site you broke; `make build` never runs a test, so it cannot see
behaviour you changed.

Measured in a fresh worktree on 2026-08-01, so a slow command is not a stuck one:
`make build` takes about 25 seconds cold, and the first `make test` about 95, with
every `make test` after that about 8.

## Rules

Commit each green step. Never run a `Diagnostics/*/run.sh`, `make run`, or
anything that quits baia: you are running inside it, and this item in particular
would be reviewing its own funeral.
