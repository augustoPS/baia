# A filename in a non-UTF-8 encoding reaches the surfaces mangled

You are working in a git worktree of baia on branch `observer/utf8-filenames`.

## The item

`GitCommand` decodes git's bytes with `String(decoding:as: UTF8.self)`, which
replaces invalid sequences rather than rejecting them, so such a name draws with
replacement characters and the path picker would send a path no command can find.
Fixing it means carrying bytes rather than `String` through `GitWorkspace`, the
surfaces and `PromptPath`.

## The first step, and it comes before any fix

Add a Latin-1 filename to the demo repository fixture, **so the bug is visible
before anything is changed**. A fix landed against an invisible bug cannot be
shown to work.

Only once a test demonstrates the mangling should you start carrying bytes
through `GitWorkspace`.

## Scope

**Package code only**, in `Packages/GitWorkspace`. Everything must be verifiable
by `make test`.

## Verify

`make test` from the worktree root. The first run compiles cold and takes about
95 seconds; every run after is about 8.

## Rules

Test first. Commit each green step. Never run a `Diagnostics/*/run.sh`, `make
run`, or anything that quits baia: you are running inside it.
