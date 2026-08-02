# You are reviewing one branch, and only one

Branch: `$BRANCH`. Base: `$BASE`. Read the diff with
`git diff $BASE..$BRANCH` and `git log --reverse -p $BASE..$BRANCH`.

Every commit on it moves a function out of baia's app target (`Sources/`) into a
package under `Packages/`, plus a test for the moved function. The branch was
told to **move code and pin what it already does**, not to improve it. A fix
smuggled inside a move is a change nobody can bisect, so a behaviour change is a
finding even when the new behaviour is better.

## Already verified. Do not spend budget re-checking these

- `make build` succeeds. `make test` passes, twelve suites.
- No moved function is still defined in `Sources/`, so nothing was copied rather
  than moved.
- No moved function is orphaned: each has a caller, in the package or in
  `Sources/`.

Reporting any of the above as a finding is a wrong answer, not a cautious one.

## What to look for, most valuable first

1. **A moved body that is not the body that left.** Diff the function as it was
   against the function as it landed, line by line. An early return dropped, a
   condition inverted, a loop bound changed, an `if let` become a force unwrap.
   This is the highest-value defect class here and the hardest to see, because the
   diff shows a deletion in one file and an addition in another and nothing lines
   them up.
2. **A test that pins what arrived rather than what was there.** Each test was
   supposed to be written against the original and still pass after the move. A
   test whose expected values were read off the new implementation proves the code
   equals itself. Ask of each new test: would this have failed if the move had
   changed the behaviour?
3. **Access widened further than the move needs.** Functions were `private` in the
   app target. A move requires `public` or `package` on the package side. Anything
   made `public` that only the package itself calls is a wider API than the move
   asked for.
4. **A doc comment that now says something untrue.** Comments moved with their
   functions and describe where they used to live, what used to call them, or
   state they read something they no longer read. On 2026-08-01 a review of this
   codebase found three doc comments asserting a behaviour the code did not have,
   and that was the whole finding on an otherwise sound branch.
5. **A call site that compiles and means something different.** Especially where a
   function gained parameters that used to be read off `self`: check every call
   passes the value that field actually held, in the right order, rather than a
   plausible one. Two `Bool` parameters in the same signature are the case to
   check twice.

## How to report

Write your findings with the **Write tool**, one file per finding, at
`Diagnostics/observer-pane/review/$BRANCH-<n>.md`. Do not use a Bash heredoc: a
heredoc carrying braces and quotes cannot be statically analysed and every write
would stop for approval.

Each file:

```
file: Packages/.../Foo.swift:123
class: moved-body-changed | test-pins-arrival | access-widened | comment-untrue | call-site-wrong
what: one sentence naming the defect
evidence: the before and the after, quoted, with the commit each came from
why-it-matters: one sentence on what breaks or what claim is false
```

**Every finding must quote code you have actually read in the file**, not
reconstructed from the diff. Open the file and check the line before you write it
down. A finding with a line number that does not hold is worse than no finding,
because it costs the reader the trip.

**Cap: five findings.** If you have more, report the five that would change what
someone does. Do not pad toward the cap.

**Zero findings is a correct and expected answer.** Say so plainly and stop. Every
branch here was written against a brief that named its own discipline, and a clean
one is likely. An invented finding costs more than a missed one, because it
teaches the reader to stop trusting this review.

## What not to do

- Do not fix anything. Do not edit any file outside
  `Diagnostics/observer-pane/review/`.
- Do not run any `Diagnostics/*/run.sh`, `make run`, or anything that quits baia:
  you are running inside it.
- Do not review the other two branches. They have their own reviewer.
