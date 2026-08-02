# spent

Briefs that have run, kept where they were written rather than deleted, and out
of `briefs/` because that directory is the *next* wave and the gate reads it.

Four generations so far. The three from the 2026-08-01 morning wave, two of which
could not reach their own goals. The three from the afternoon, which could: every one
required `make build`, permitted the app target, and produced a branch that
compiles. And `pane-move`, the first written under the rule rather than corrected
by it, whose goal stopped at the wiring and left the live pass owed in writing.

The fourth ran 2026-08-02 and is the first the orchestrator set up itself:
`transport-directory`, `palette-mapping`, `colour-resolvers`. All three merged
green. Two things they are worth keeping for. `colour-resolvers` is the first
brief to correct its own source, since the survey called four resolvers
near-identical and two of them shared a name and nothing else, so the brief made
proving agreement the first step rather than consolidating on the survey's word.
And `palette-mapping` is the case for reading a test rather than its comment: it
asked for an exhaustiveness the test claimed and did not have, which review caught
by mutation and a later commit made real.

Two of the three could not reach their own goals. `Diagnostics/brief-check/`
carries its own verbatim copies as fixtures and asserts that two fail and one
passes, so these are the historical record and those are the test data. Editing
either does not change the other, which is the point: the fixtures must keep
failing after these are understood.
