// Grades `RowFeedback`'s answer clock under both motion policies. Headless: no
// window, no view, no compositor. The class is compiled verbatim from
// `Sources/RowFeedback.swift` and driven through the same three calls
// `FilesSurface` makes (`answer`, `hovered`, `reset`), with the Reduce Motion
// policy injected so both policies run in one process without touching the
// system preference.
//
//   motiontest <arm>
//
// Arms: still landed motion hover repeat toggle reset. Every sample is what
// `draw(_:)` would ask for: `fill(_:in:)` and `ink(_:in:)` for the answered
// row, recorded inside the redraw callback so the samples are exactly the
// frames the rows view would have painted. The runner builds this file twice,
// once against the shipped source and once against a copy with the defect
// restored (a Reduce Motion answer routed through the snapping fade). Every arm
// passes the former. Against the latter the five Reduce Motion arms must fail,
// and `motion` and `reset` must still pass: the defect never touched the
// animated path, and `reset` grades that nothing outlives it either way.
import AppKit
import PaneChrome

let theme = PaneTheme.darkPastel
let row = 3
let hold = 0.22          // RowFeedback.answerDuration, restated: the probe grades the number, not the constant
let tolerance = 0.10     // one run-loop hiccup, not a design margin

struct Frame {
    let at: Double
    let fill: (colour: RGB, alpha: Double)?
    let ink: (colour: RGB, alpha: Double)?
}

var frames: [Frame] = []
var started = Date()
var reducesMotion = true
var feedback: RowFeedback!

func record(_ redrawn: Int) {
    guard redrawn == row else { return }
    frames.append(Frame(
        at: Date().timeIntervalSince(started),
        fill: feedback.fill(row, in: theme),
        ink: feedback.ink(row, in: theme)
    ))
}

func make(reducesMotion policy: Bool) {
    frames = []
    started = Date()
    reducesMotion = policy
    feedback = RowFeedback(reducesMotion: { reducesMotion }, redraw: record)
}

func wait(_ seconds: Double) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

func fill() -> (colour: RGB, alpha: Double)? { feedback.fill(row, in: theme) }
func ink() -> (colour: RGB, alpha: Double)? { feedback.ink(row, in: theme) }

let refusedFill = theme.background.blended(with: theme.alert, fraction: 0.24)
let landedFill = theme.background.blended(with: theme.inkFocus, fraction: 0.16)

@main
enum MotionTest {
    @MainActor static func main() {
        let arm = CommandLine.arguments.dropFirst().first ?? ""
        print("arm: \(arm)")

        switch arm {
        case "still":
            // Reduce Motion. The refusal is on screen at full strength from the first
            // frame, stays there unchanged for the hold, then goes in one step.
            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            let first = frames.first
            check(first != nil, "the answer produced a frame at all")
            check(first?.fill?.alpha == 1 && first?.fill?.colour == refusedFill, "first frame is the refusal fill at alpha 1")
            check(first?.ink?.alpha == 1 && first?.ink?.colour == theme.alert, "first frame carries alert ink on the path")
            wait(hold / 2)
            check(fill()?.alpha == 1 && fill()?.colour == refusedFill, "half-way through the hold the refusal is still there, still at alpha 1")
            check(ink()?.alpha == 1, "and so is its ink")
            wait(hold / 2 + tolerance)
            check(fill() == nil, "after the hold the fill is gone")
            check(ink() == nil, "after the hold the ink is gone")
            let alphas = frames.compactMap { $0.fill?.alpha }
            check(alphas.allSatisfy { $0 == 1 }, "no frame was ever drawn between 0 and 1: no movement (\(alphas))")
            check(frames.count == 2, "exactly two frames: the outcome and its release (\(frames.count))")
            if let last = frames.last {
                check(last.fill == nil && last.at >= hold - 0.01, "the release frame came no earlier than the hold (\(String(format: "%.3f", last.at))s)")
                check(last.at <= hold + tolerance, "and no later than the hold plus one tolerance")
            }

        case "landed":
            // Reduce Motion, the other outcome: same hold, pressed fill, no ink.
            make(reducesMotion: true)
            feedback.answer(.landed, at: row)
            let first = frames.first
            check(first?.fill?.alpha == 1 && first?.fill?.colour == landedFill, "first frame is the landed fill at alpha 1")
            check(first?.ink == nil, "landing never touches the path's ink")
            wait(hold + tolerance)
            check(fill() == nil, "after the hold the fill is gone")

        case "motion":
            // Motion allowed: a fade from 1 to 0 over the hold. Graded so the repair is
            // shown not to have touched the animated path.
            make(reducesMotion: false)
            feedback.answer(.refused, at: row)
            wait(hold / 2)
            let mid = fill()
            check(mid != nil && mid!.alpha > 0 && mid!.alpha < 1, "half-way through, the fill is mid-fade (\(mid?.alpha ?? -1))")
            check(mid?.colour == refusedFill, "and it is the refusal fill")
            wait(hold / 2 + tolerance)
            check(fill() == nil, "after the fade the fill is gone")
            check(ink() == nil, "after the fade the ink is gone")
            let alphas = frames.compactMap { $0.fill?.alpha }
            check(alphas.count >= 3, "the fade was drawn in more than two frames (\(alphas.count))")
            check(zip(alphas, alphas.dropFirst()).allSatisfy { $0 >= $1 }, "the fade never rises")

            // The same grader distinguishes a hold from a fade, and this half is
            // what makes the arm's control fail: everything above runs with the
            // policy false, where the defect build takes the same fade path as
            // this one and so passes with it. Only a still-policy answer on the
            // same clock separates them.
            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            wait(hold / 2)
            check(fill()?.alpha == 1, "the still policy shows alpha 1 where the fade showed a fraction (\(fill()?.alpha ?? -1))")

        case "hover":
            // Reduce Motion. A pointer leaving the held row does not cut the hold
            // short; a pointer sitting on the row when the hold ends keeps its hover
            // fill; and the hover after release is a hover, not a refusal.
            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            feedback.hovered = row
            feedback.hovered = nil
            check(fill()?.colour == refusedFill && fill()?.alpha == 1, "a pointer leaving the row leaves the refusal in place")
            check(ink() != nil, "and its ink")
            wait(hold + tolerance)
            check(fill() == nil, "the hold still ends on time")
            feedback.hovered = row
            check(fill()?.colour == theme.selectedRowBackground && fill()?.alpha == 1, "the next hover is a hover, not a refusal")
            check(ink() == nil, "with no alert ink left behind")
            feedback.hovered = nil

            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            wait(hold / 2)
            feedback.hovered = row
            check(fill()?.colour == refusedFill, "a pointer arriving mid-hold sees the refusal")
            wait(hold / 2 + tolerance)
            check(fill()?.colour == theme.selectedRowBackground && fill()?.alpha == 1, "when the hold ends under the pointer the row is hovered, not dark")
            check(ink() == nil, "and the refusal's ink is gone")

        case "repeat":
            // Reduce Motion. A second answer on the same row restarts the hold, and
            // the first hold's release must not clear the newer answer.
            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            wait(hold / 2)
            feedback.answer(.landed, at: row)
            check(fill()?.colour == landedFill && fill()?.alpha == 1, "the newer answer replaces the older at once")
            check(ink() == nil, "and takes the refusal's ink with it")
            wait(hold / 2 + 0.03)
            check(fill()?.colour == landedFill && fill()?.alpha == 1, "past the first hold's end the newer answer is still shown")
            wait(hold / 2 + tolerance)
            check(fill() == nil, "the second hold ends on its own time")
            let alphas = frames.compactMap { $0.fill?.alpha }
            check(alphas.allSatisfy { $0 == 1 }, "no movement across both answers (\(alphas))")

            // A hold cancelled by `reset()` and then re-answered on the same row.
            // The cancelled timer is invalidated, so this asks what happens if one
            // ever did fire late: the generation guard refuses it, because the row's
            // current hold carries a newer stamp. Identity by timer object answered
            // this too; the guard is a `UInt64` only because a `Timer` cannot cross
            // into the main-actor closure without a data race.
            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            feedback.reset()
            feedback.answer(.landed, at: row)
            wait(hold / 2)
            check(fill()?.colour == landedFill && fill()?.alpha == 1, "an answer after a reset is not cleared by the reset's own hold")
            wait(hold / 2 + tolerance)
            check(fill() == nil, "and it ends on its own time")

        case "toggle":
            // Reduce Motion flipped while a hold is pending, in both directions. The
            // hold keeps its policy from the moment of the answer; whatever the pointer
            // does afterwards follows the new policy; nothing is left behind.
            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            reducesMotion = false
            wait(hold / 2)
            check(fill()?.alpha == 1 && fill()?.colour == refusedFill, "turning motion on mid-hold does not start a fade")
            wait(hold / 2 + tolerance)
            check(fill() == nil && ink() == nil, "the hold still ends in one step")

            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            reducesMotion = false
            feedback.hovered = row
            feedback.hovered = nil
            wait(hold / 2)
            let mid = fill()
            check(mid == nil || (mid!.alpha < 1), "a pointer leaving under the new policy fades out rather than holding (\(mid?.alpha ?? 0))")
            wait(hold / 2 + tolerance)
            check(fill() == nil && ink() == nil, "the fade and the stale hold leave nothing behind")

            make(reducesMotion: false)
            feedback.answer(.refused, at: row)
            reducesMotion = true
            wait(hold / 2)
            check(fill() != nil && fill()!.alpha < 1, "turning motion off mid-fade does not freeze the fade")
            wait(hold / 2 + tolerance)
            check(fill() == nil && ink() == nil, "and the fade still completes")

        case "reset":
            // Reduce Motion. A list replaced under a held outcome cancels the hold, so
            // no release ever redraws whatever row arrived at that index.
            //
            // The first half establishes that a release is observable *in this arm*
            // when nothing cancels it, which is what makes the second half's silence
            // mean something. Deferring that to `still` reads fine but does not
            // survive the control: `run.sh` grades every arm against its own defect
            // binary, and under the defect there is no hold to cancel, so an arm
            // holding only the silence passes both builds and proves nothing.
            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            var before = frames.count
            wait(hold + tolerance)
            check(frames.count == before + 1, "an uncancelled hold releases with one frame (\(frames.count - before))")

            make(reducesMotion: true)
            feedback.answer(.refused, at: row)
            feedback.reset()
            before = frames.count
            wait(hold + tolerance)
            check(frames.count == before, "no frame arrived after reset (\(frames.count - before) did)")
            check(fill() == nil, "and the row is clear")

        default:
            print("unknown arm \(arm); one of still landed motion hover repeat toggle reset")
            exit(2)
        }

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("all checks pass")
    }
}
