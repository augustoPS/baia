# done-level

Give the attention model its fourth level: `done`, meaning a pane that finished
and has not been looked at since.

## Why this is not a fourth `ReportedState`

**Do not add a case to `ReportedState`.** Its own doc comment says design v4's
four-state model "is a separate decision and is not this enum", and the reason
holds: `done` is *idle, and not yet seen*, and the seen half is a fact about the
owner rather than about the pane. A reporting agent can say it is idle; it cannot
say whether anybody looked. The channel already carries everything it can carry.

`done` is a derived level, exactly the way `acknowledged` is derived. `PaneAttention`
resolves `requested` against a recorded visit to get `acknowledged`; this resolves
a reported `idle` against the same visit to get `done`.

Spec: `vault/projects/baia/specs/2026-08-03-what-seen-means.md`. Read it first;
everything below is downstream of the decision it records.

## Seen means focus, and the rule already exists

`PaneAttentionState.noteFocused()` records `seen = true` on the focus transition.
That is the definition, decided 2026-08-03, and it does not change here.

The keyness check (`NSApp.isActive`) was considered and **declined**. Do not add
it. A backgrounded baia can still mark a pane seen and that cost was taken
knowingly, against a rule that depends on one input rather than two.

## The asymmetry, which is the whole of this brief

`blocked` and `done` consume the visit differently:

| | quiets on a visit | ends on |
|---|---|---|
| `blocked` / `requested` | yes, to `acknowledged` | `noteResumed`, driven by the activity classifier |
| `done` | no | the visit itself |

A finished agent does not resume, which is why `noteResumed` cannot end a `done`
and why `idle` is reported over the channel at all: a resident agent's process
never exits, so no poller can tell a finished agent from a working one.

**Write these as two things, not one function with a flag.** They are two
different consumptions of one signal, and a shared function with a boolean is how
they come to disagree later.

## Not negotiable

Each has a failure behind it, and the first two are already recorded in the code
you are changing.

- **`noteFocused` records a visit and nothing else.** It is unconditional today,
  including for a pane asking nothing, and that is load-bearing: a pane raised by
  a report with no bell behind it has no latched request to acknowledge, so
  without a separately recorded visit its volume could only ever be loud. That
  was a live defect found 2026-07-31. Do not add a `done` branch inside it.
  Whatever decays a `done` *reads* the recorded visit.
- **Seeing a `blocked` still quiets rather than clears.** An earlier design
  dropped straight to `none` on focus, which "answered 'have you seen it' and
  threw away 'is it still waiting'", making a glanced-at pane indistinguishable
  from one that had gone back to work. Do not regress that while adding the new
  level.
- **`seen` is reset where a request begins, not where one ends.** `noteReported`
  clears it on the `blocked` raise and `noteBell` on the bell, so a visit that
  predates a question does not answer it. A `done` needs the same treatment: an
  idle arriving after the owner left has not been seen, even though the pane was
  visited earlier in the session.

## Scope

- `Packages/PaneActivity/Sources/PaneActivity/PaneAttention.swift`
- `Packages/PaneActivity/Sources/PaneActivity/PaneAttentionState.swift`
- `Packages/PaneActivity/Tests/PaneActivityTests/` (whatever arms you need)

The app target is **permitted but not expected**. `PaneAttentionTracker` maps the
level onto `PaneStatus.Agent`, and if the new level needs to reach the chrome you
may touch `Sources/`. If you do, say so and say why; drawing v4's chrome is not
this brief and belongs to a design pass that has not happened.

`ReportedState` and the wire are **out of scope**: the channel already carries
everything it can carry, and the reason is the first section of this brief.

## First step, before any behaviour changes

Write an arm that pins the current `noteFocused` contract for a pane that is
asking nothing: the visit is recorded, and the resolved attention does not move.
It should pass on the code as it stands. That arm is what catches you if the new
level makes `noteFocused` conditional, which is the failure the first
non-negotiable names.

## Verify

`make test` from the worktree root, which is the one that matters here. The first
run compiles cold and takes about 95 seconds; every run after is about 8.

`make build` as well, because the app target imports this package and a function
that changes shape leaves a call site behind. About 25 seconds cold.

## Done means

- `done` is reachable, resolves from a reported `idle` plus an unconsumed visit,
  and decays fully once seen.
- `blocked` still quiets to `acknowledged` on a visit and still ends only on
  `noteResumed`.
- The two consumptions are separate code, not one parameterised function.
- `noteFocused` still records unconditionally.
- `make test` green, `make build` clean, and every new arm proved by mutation:
  break the thing it protects, watch it fail, restore it.
