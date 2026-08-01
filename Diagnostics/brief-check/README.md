# brief-check

**The question:** can a brief's verification observe the change the brief asks
for, and can the executor run it?

Both are decidable from the brief and the executors' settings file, before
anything is spawned. On 2026-08-01 the answer was no for two of three briefs and
nobody asked.

Not a probe of baia. No app, no window, no shell: it reads markdown and JSON.

## Why it exists

The observer watched three executors and judged all seven of its verdicts
correctly. A five-agent review then found two of three branches defective anyway,
because the executors had followed their briefs exactly and the briefs were the
defect. `tree-expansions` deferred the wiring its title depended on;
`utf8-filenames` named "`GitWorkspace`, the surfaces and `PromptPath`" as the fix
and then permitted `Packages/GitWorkspace` alone, five lines apart.

Both were static properties of a 40-line document, available before the wave for
the price of one read.

## The two rules

**1. Verification reach.** A brief that permits changes to a package the app
target imports must verify with a command that compiles the app target.

`Sources/` imports eleven of the local packages, so a change to any of them can
break the app target at compile time. A brief is written before the change
exists, so it cannot know whether the edit will be source breaking, and
`make test` never compiles `Sources/`. That pairing is how a non-defaulted
parameter added to a public initializer broke four call sites with every test
green and nothing the executor was allowed to run able to say so.

**2. Allowlist agreement.** Every command under `## Verify` must be permitted by
`observer-pane/executor-settings.json`, in both its bare and its rtk-prefixed
spelling.

Neither spelling covers the other. `rtk hook claude` runs first in the PreToolUse
chain, so every hook after it reads `rtk make build`, while permission rules are
matched before the rewrite and still want the bare form. A brief naming a command
the executor cannot run halts its pane on a prompt, which is how the first run
spent four hours doing nothing.

## The negative control is the acceptance criterion

The three 2026-08-01 briefs are kept verbatim under `fixtures/`. The self-test
requires `tree-expansions` and `utf8-filenames` to fail and `app-target-rules` to
pass, and then greps `check.py` for their names: a check that recognises its own
fixtures is matching rather than deriving, and says nothing about the next brief.

`app-target-rules` passing is the load-bearing half, and it must pass **for the
right reason**. It names `Sources/` and greps it, so any rule about naming a path
would fail it. It changes no package, its deliverable is a markdown file, and
`make test` confirming no behaviour changed is the correct verification for that.

The fixtures are copies rather than the live files because the live briefs are
meant to be rewritten until they pass. Without the copies this check would soon
have nothing left to fail against and would report a clean sweep forever.

## What it cannot do

It reads what a brief writes down. Both observed cases wrote it down, one of them
in adjacent sections, and a brief that silently omits the package it will change
gets through.

The third 2026-08-01 defect is invisible here and would be invisible to any static
check: `SessionStore.reconciled` pruned against each pane's raw working directory
where the live feature keys on the resolved anchor, which needs the semantics of
another package to see. `Diagnostics/tree-expansions/` is what catches that one,
and it catches it by running the app.

A model pass would cover the omission case. It is deliberately not here, because
it would have no negative control and a pass would prove nothing.

## Running it

```
./Diagnostics/brief-check/run.sh              # the live briefs
./Diagnostics/brief-check/run.sh --self-test  # the fixtures, with asserts
./Diagnostics/brief-check/run.sh <brief.md>   # a named brief
```

`observer-pane/run.sh` runs the first form before it spawns anything and refuses
on a failure. It refuses today, because the wave it describes is the one that
already ran with two defective briefs. Planning the next wave means replacing
those files.
