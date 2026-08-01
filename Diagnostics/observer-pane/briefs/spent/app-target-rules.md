# Five rules were living in the app target

You are working in a git worktree of baia on branch `observer/app-target-rules`.

## The item

Found one at a time across the v1.1 session: the activity label, `--kinds`
resolution, the wait cap, edge-triggering, and the batch caps that were only ever
exercised by tests supplying their own values. Three of the five were wrong or
unenforced when they moved to a package. The rule is that anything answerable
without a descriptor or an `NSWindow` belongs in a package, and the app target
keeps only what needs AppKit.

## What to produce, and it is a list

Grep `Sources/` for the shape rather than reading it whole. Every `func`
returning a value with no `NSWindow`, `NSView` or surface parameter is a
candidate. **One hour to list, then one move at a time.**

Your deliverable for this session is **the list**: each candidate as file, line,
signature, and one sentence on which package it belongs in. Write it to
`Diagnostics/observer-pane/app-target-candidates.md` and commit that.

**Do not move anything yet.** The survey exists to be read before the moves are
chosen, and a move made during the survey is a move nobody chose.

## Verify

`make test` from the worktree root, to confirm you changed no behaviour. The
first run compiles cold and takes about 95 seconds; every run after is about 8.

## Rules

Commit the list. Never run a `Diagnostics/*/run.sh`, `make run`, or anything that
quits baia: you are running inside it.
