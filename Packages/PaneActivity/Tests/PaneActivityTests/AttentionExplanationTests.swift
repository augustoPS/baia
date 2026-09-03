import Foundation
import Testing

@testable import PaneActivity

/// Which authority decided the attention word, and why, for each rule
/// `PaneAttentionState.attention` composes.
@Suite struct AttentionExplanationTests {
    @Test func aPaneNobodyAskedAboutHasNoAuthority() {
        let state = PaneAttentionState()
        let e = state.explanation
        #expect(e.authority == .none)
        #expect(e.resolved == .none)
        #expect(e.latch == .none)
        #expect(e.reportedBlock == nil)
        #expect(e.reportedFinish == nil)
        #expect(e.seen == false)
        #expect(e.reason.contains("nothing has asked"))
    }

    @Test func aBellIsTheLatchAndTheVisitDecidesTheVolume() {
        var state = PaneAttentionState()
        _ = state.noteBell()
        #expect(state.explanation.authority == .latch)
        #expect(state.explanation.resolved == .requested(message: nil))
        #expect(state.explanation.reason.contains("bell or a notification"))
        #expect(state.explanation.reason.contains("has not been in the pane since"))

        _ = state.noteFocused()
        #expect(state.explanation.authority == .latch)
        #expect(state.explanation.resolved == .acknowledged(message: nil))
        #expect(state.explanation.seen)
        #expect(state.explanation.reason.contains("has been in the pane since"))
    }

    @Test func aReportedBlockIsTheReportAndOutranksTheLatch() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: true, message: "which branch?")
        let e = state.explanation
        #expect(e.authority == .report)
        #expect(e.reportedBlock == true)
        #expect(e.resolved == .requested(message: "which branch?"))
        #expect(e.reason.contains("reported blocked"))
        #expect(e.reason.contains("which branch?"))
    }

    @Test func aReportedWorkingSilencesABellAndTheReasonNamesWhatItSilenced() {
        var state = PaneAttentionState()
        _ = state.noteBell()
        _ = state.noteReported(blocked: false, message: nil)
        let e = state.explanation
        #expect(e.authority == .report)
        #expect(e.latch == .requested(message: nil))
        #expect(e.resolved == .none)
        #expect(e.reason.contains("reported working"))
        #expect(e.reason.contains("silences"))
        #expect(e.reason.contains("requested"))
    }

    @Test func aReportedFinishUnseenIsDoneAndSeenIsOver() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: false, finished: true, message: nil)
        #expect(state.explanation.authority == .report)
        #expect(state.explanation.resolved == .done)
        #expect(state.explanation.reason.contains("reported idle"))
        #expect(state.explanation.reason.contains("done"))

        _ = state.noteFocused()
        #expect(state.explanation.authority == .report)
        #expect(state.explanation.resolved == .none)
        #expect(state.explanation.reason.contains("seen since"))
    }

    /// The explanation's `resolved` is `attention`, always. Pinned across every
    /// path this suite walks, so a later edit to one cannot leave the other
    /// describing a different pane.
    @Test func resolvedIsAlwaysTheAttentionTheChromeDraws() {
        var state = PaneAttentionState()
        let steps: [(inout PaneAttentionState) -> Void] = [
            { _ = $0.noteBell() },
            { _ = $0.noteFocused() },
            { _ = $0.noteReported(blocked: true, message: "m") },
            { _ = $0.noteReported(blocked: false, message: nil) },
            { _ = $0.noteReported(blocked: false, finished: true, message: nil) },
            { _ = $0.noteResumed() },
            { _ = $0.noteReported(blocked: nil, finished: nil, message: nil) },
        ]
        for step in steps {
            step(&state)
            #expect(state.explanation.resolved == state.attention)
        }
    }

    @Test func everyAttentionCaseHasAName() {
        #expect(PaneAttention.none.name == "none")
        #expect(PaneAttention.requested(message: "x").name == "requested")
        #expect(PaneAttention.acknowledged(message: nil).name == "acknowledged")
        #expect(PaneAttention.done.name == "done")
    }
}
