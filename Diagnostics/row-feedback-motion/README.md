# row-feedback-motion

Checks that a row answer under Reduce Motion requests a redraw, holds its
fill and ink for the answer duration, and clears afterward.

`make test` cannot answer it: `RowFeedback` lives in `Sources/`, which has no
test target, and the property is about a clock. The probe compiles the shipped
file verbatim against `PaneChrome`, drives it through the three calls the rows
view makes that carry motion (`answer`, `hovered`, `reset`) with the Reduce
Motion policy injected, and records `fill(_:in:)` and `ink(_:in:)` inside the
redraw callback. `pressed` is the fourth call the view makes and is deliberately
not driven here: it has no transition either way, so there is no motion in it to
grade.

Headless: no window, no view, no compositor, no process launched or quit. It is
not in `guard-baia-alive.sh`'s `SAFE_PROBES` list; run it from a shell outside a
baia pane. Scratch goes to a `mktemp` directory removed on exit.

## The defect it exists to catch

Systematic review 2026-09-05, R13. `answer(_:at:)` set the level to 1 and called
`fade(_:to:over:)` to 0. That method's Reduce Motion arm jumps to the target
inside the call and clears the answer with it, so the outcome was set and erased
before any `draw(_:)` ran. A refusal under Reduce Motion was a beep and nothing
else.

The repair separates hold time from motion. With motion the level fades 1 to 0
over `answerDuration`. Without it the level sits at 1 for the same
`answerDuration`, redrawn at once, and drops in one step when a one-shot hold
timer fires. The hold yields to a newer answer, to `reset()`, and to a pointer
sitting on the row when it ends.

## Controls

The runner builds the grader twice: against the shipped source, and against a
copy with the repair undone (`guard reducesMotion() else {` rewritten to
`if true {`, which routes every answer back through the snapping fade). Every
arm must pass the first binary and fail the second.

The `motion` and `reset` arms each include a still-policy case that detects
the defect, alongside checks for animation and cancellation.

A source change that defeats the substitution fails the run before any arm runs.

## The arms

| arm | what it asserts |
|---|---|
| `still` | Reduce Motion, refusal: first redraw carries the refusal fill and alert ink at alpha 1; unchanged at half the hold; gone after it; exactly two redraws, none between 0 and 1; release lands within the hold plus one tolerance |
| `landed` | Reduce Motion, landing: same hold with the pressed fill and no ink |
| `motion` | Motion allowed: mid-fade fraction at half the hold, monotonic, gone after it. Then the still policy on the same clock shows alpha 1 at the same instant, which is what makes this arm's control fail: the motion half alone behaves identically in both builds |
| `hover` | A pointer leaving the held row does not cut the hold short; a pointer on the row when the hold ends keeps its hover fill; the next hover draws as a hover, not in alert |
| `repeat` | A second answer mid-hold replaces the first at once, and the first hold's release does not clear it. Also an answer made after `reset()` cancelled a hold, which the generation guard must not clear |
| `toggle` | Reduce Motion flipped under a pending hold in both directions: the hold keeps its policy, pointer movement follows the new one, and nothing is left behind |
| `reset` | An uncancelled hold releases with one observable redraw, established inside this arm rather than deferred to `still` so the control can fail; then after `reset()` no redraw arrives and the row is clear |

## Limits

Timing is measured on the main run loop with a 100 ms tolerance, so the probe
grades order and presence rather than the exact 220 ms.

Samples are redraw *requests* plus the model state at the moment of the request,
not window-server frames: the callback stands where `FilesSurface.redraw(_:)`
calls `setNeedsDisplay(_:)`, and AppKit coalesces requests into display cycles.
No pixel is read, so redraw counts do not prove paint counts. It does not reach the
real `FilesSurface` view, the tracking areas, or a real pointer, and it says
nothing about accessibility announcement: no AX post exists for a row's answer
(R10), so visible rendering and assistive announcement remain live acceptance checks.
