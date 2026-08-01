import Foundation
import Testing

@testable import PaneActivity

/// Acknowledging a pane that only a report ever raised.
///
/// **The failure this suite pins.** `PaneAttentionOverrideTests` proves the rule
/// on values: a latch reading `.acknowledged` under a blocked report stays quiet.
/// What it cannot see is that nothing could put the latch into `.acknowledged` in
/// the first place when the raise came from a report. `noteFocused()` only moved a
/// latch that already held a request, a report-only raise left it at `.none`, and
/// the override then re-derived the loud level from `.none` on every pass. Focus
/// did nothing, typing did nothing, and the pane stayed loud for the report's full
/// TTL.
///
/// Found live on 2026-07-31 at two panes, by typing into one that had been raised
/// with `baia report --state blocked` and watching it stay loud. It matters
/// because the Claude Code hook is the main producer of raises, so every agent
/// question arrived on the one path that could not be acknowledged, while the bell
/// path every earlier test exercises worked correctly.
@Suite struct PaneAttentionReportedTests {
    @Test func aReportedBlockAsksEvenWithNoBellBehindIt() {
        var state = PaneAttentionState()
        let changed = state.noteReported(blocked: true, message: "which branch?")
        #expect(changed)
        #expect(state.attention == .requested(message: "which branch?"))
    }

    /// The defect itself. Focus is the acknowledgement, and it has to work on a
    /// pane whose request never touched the latch.
    @Test func focusingAPaneRaisedOnlyByAReportAcknowledgesIt() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: true, message: "which branch?")
        let changed = state.noteFocused()
        #expect(changed)
        #expect(state.attention == .acknowledged(message: "which branch?"))
        #expect(state.attention.isRequesting)
        #expect(state.attention.isUnacknowledged == false)
    }

    /// Acknowledgement survives the reports that follow it. The hook fires again
    /// every few minutes with the same state, and a pane that went quiet must not
    /// be shouted at by the repeat.
    @Test func aRepeatedBlockedReportDoesNotUndoAnAcknowledgement() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: true, message: "which branch?")
        _ = state.noteFocused()
        let changed = state.noteReported(blocked: true, message: "which branch?")
        #expect(changed == false)
        #expect(state.attention == .acknowledged(message: "which branch?"))
    }

    /// A genuinely new question is loud again. The agent answered, went back to
    /// work, and asked something else, and the acknowledgement earned by the first
    /// question was for the first question.
    @Test func askingAgainAfterWorkingIsLoudAgain() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: true, message: "which branch?")
        _ = state.noteFocused()
        _ = state.noteReported(blocked: false, message: nil)
        #expect(state.attention == .none)
        let changed = state.noteReported(blocked: true, message: "and the tag?")
        #expect(changed)
        #expect(state.attention == .requested(message: "and the tag?"))
        #expect(state.attention.isUnacknowledged)
    }

    /// Focus on a pane that has said nothing and rung nothing is still not a
    /// change. The acknowledgement is recorded, because the next request has to
    /// know whether the owner arrived before or after it, but nothing drawn moves
    /// and the caller must not repaint.
    @Test func focusingAPaneWithNoRequestAtAllIsStillNotAChange() {
        var state = PaneAttentionState()
        let changed = state.noteFocused()
        #expect(changed == false)
        #expect(state.attention == .none)
    }

    /// A pane focused before the question arrives is still loud when it does.
    /// "Have I been here since it started" is false for a visit that predates the
    /// request, and answering it any other way would silence the first question
    /// every foreground pane is ever asked.
    @Test func aVisitBeforeTheQuestionDoesNotAcknowledgeIt() {
        var state = PaneAttentionState()
        _ = state.noteFocused()
        let changed = state.noteReported(blocked: true, message: "which branch?")
        #expect(changed)
        #expect(state.attention == .requested(message: "which branch?"))
        #expect(state.attention.isUnacknowledged)
    }

    /// The bell path keeps its own behaviour, which is what says this change adds
    /// a way in rather than moving the existing one.
    @Test func aBellStillAcknowledgesThroughTheLatch() {
        var state = PaneAttentionState()
        _ = state.noteBell()
        let changed = state.noteFocused()
        #expect(changed)
        #expect(state.attention == .acknowledged(message: nil))
    }

    /// A bell arriving under an acknowledged report is a new request and goes back
    /// to loud, the same way a bell does under an acknowledged latch.
    @Test func aBellUnderAnAcknowledgedReportIsANewRequest() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: true, message: "which branch?")
        _ = state.noteFocused()
        let changed = state.noteBell()
        #expect(changed)
        #expect(state.attention.isUnacknowledged)
    }
}
