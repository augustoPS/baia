import Foundation
import Testing

@testable import PaneActivity

/// The fourth level, end to end through the state machine.
///
/// `PaneAttentionOverrideTests` pins the two resolution rules on values, where
/// the visit is an argument. This suite drives them through the real thing, where
/// the visit is recorded by `noteFocused()` and reset by whatever begins a
/// request, because that is where the two rules can disagree with each other and
/// where an ordering mistake between them would show.
@Suite struct PaneAttentionDoneTests {
    /// The level is reachable: a reported finish with nobody having been here.
    @Test func aFinishNobodyHasSeenIsDone() {
        var state = PaneAttentionState()
        let changed = state.noteReported(blocked: false, finished: true, message: nil)
        #expect(changed)
        #expect(state.attention == .done)
        #expect(state.attention.isDone)
    }

    /// The visit ends it, fully, which is the half `acknowledged` deliberately
    /// does not have. There is no quieter tier below this one.
    @Test func lookingAtAFinishedPaneEndsIt() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: false, finished: true, message: nil)
        let changed = state.noteFocused()
        #expect(changed)
        #expect(state.attention == PaneAttention.none)
    }

    /// It stays ended while the report goes on repeating itself. The hook fires
    /// again every few minutes with the same state, and a finish that came back
    /// on every repeat would be a badge that never went away.
    @Test func aRepeatedFinishAfterAVisitStaysEnded() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: false, finished: true, message: nil)
        _ = state.noteFocused()
        let changed = state.noteReported(blocked: false, finished: true, message: nil)
        #expect(changed == false)
        #expect(state.attention == PaneAttention.none)
    }

    /// **The silent-loss case, which is the one the whole level exists for.** The
    /// owner was in the pane, left, and the agent finished after they had gone. A
    /// finish inheriting that older visit would decay before anybody knew it had
    /// happened, and the owner would learn the agent was done by wandering back
    /// in. This is the third instance of "reset where a request begins".
    @Test func aVisitBeforeTheFinishDoesNotConsumeIt() {
        var state = PaneAttentionState()
        _ = state.noteFocused()
        let changed = state.noteReported(blocked: false, finished: true, message: nil)
        #expect(changed)
        #expect(state.attention == .done)
    }

    /// An agent that finishes twice in one session is `done` twice. The visit
    /// that ended the first finish was for the first finish.
    @Test func finishingAgainAfterWorkingIsDoneAgain() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: false, finished: true, message: nil)
        _ = state.noteFocused()
        _ = state.noteReported(blocked: false, finished: false, message: nil)
        #expect(state.attention == PaneAttention.none)
        let changed = state.noteReported(blocked: false, finished: true, message: nil)
        #expect(changed)
        #expect(state.attention == .done)
    }

    // MARK: The asymmetry, driven rather than argued

    /// The two levels take the same visit and do opposite things with it. Written
    /// as one arm because the pair is the claim, and either half alone would pass
    /// under a rule that treated both the same way.
    @Test func aVisitQuietsABlockAndEndsAFinish() {
        var blocked = PaneAttentionState()
        _ = blocked.noteReported(blocked: true, finished: false, message: "which branch?")
        _ = blocked.noteFocused()
        #expect(blocked.attention == .acknowledged(message: "which branch?"))
        #expect(blocked.attention.isRequesting)

        var finished = PaneAttentionState()
        _ = finished.noteReported(blocked: false, finished: true, message: nil)
        _ = finished.noteFocused()
        #expect(finished.attention == PaneAttention.none)
        #expect(finished.attention.isRequesting == false)
    }

    /// A block still ends only on `noteResumed`, and seeing it is still not
    /// enough. Pinned beside the new level because the new level's whole shape is
    /// "ends on the visit", and the regression to guard against is that spreading
    /// to the level that must not have it.
    @Test func aBlockStillEndsOnlyOnResuming() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: true, finished: false, message: "which branch?")
        _ = state.noteFocused()
        #expect(state.attention.isRequesting)
        _ = state.noteResumed()
        // The latch is clear, and the report is what is still holding the
        // request up. This is the pre-existing division of labour and the new
        // level does not touch it.
        #expect(state.attention == .acknowledged(message: "which branch?"))
        _ = state.noteReported(blocked: false, finished: false, message: nil)
        #expect(state.attention == PaneAttention.none)
    }

    /// `noteResumed` cannot end a finish, which is not an omission. A finished
    /// agent does not go back to work, and that is the entire reason `idle`
    /// crosses the channel instead of being read off the process tree. Reported
    /// as no change, so the poll that calls this on every idle-to-running
    /// transition does not repaint a finished pane's chrome for nothing.
    @Test func resumingDoesNotEndAFinish() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: false, finished: true, message: nil)
        let resumed = state.noteResumed()
        #expect(resumed == false)
        #expect(state.attention == .done)
    }

    // MARK: Ranking against the other levels

    /// A live block outranks a finish. In practice one report carries one state,
    /// so this is the rule holding rather than a case the channel produces.
    @Test func aBlockOutranksAFinishHeldAtTheSameTime() {
        var state = PaneAttentionState()
        let changed = state.noteReported(blocked: true, finished: true, message: "which branch?")
        #expect(changed)
        #expect(state.attention == .requested(message: "which branch?"))
    }

    /// A bell under a live finish is swallowed, and that is the shipped rule
    /// rather than a hole this level opened.
    ///
    /// **The report outranks the latch whenever it says the pane is not asking**,
    /// which `aWorkingReportSilencesABellThePaneEmittedEarlier` already pins on
    /// values, and this state machine has no ordering between a report and a bell
    /// to tell an earlier bell from a later one. A finish is a report saying the
    /// pane is not asking, so it silences a bell exactly as `working` does, and
    /// the pane reads `done` rather than `requested`.
    ///
    /// Worth an arm because the obvious guess is the other way round. The claim
    /// to notice is the narrow one: this level changed nothing here. Whether the
    /// report should outrank a bell that arrived after it is a live question
    /// about the shipped rule, and it is the same question with or without
    /// `done`.
    @Test func aBellUnderAFinishIsSilencedTheSameWayAWorkingReportSilencesOne() {
        var state = PaneAttentionState()
        _ = state.noteReported(blocked: false, finished: true, message: nil)
        #expect(state.attention == .done)
        let changed = state.noteBell()
        #expect(changed == false)
        #expect(state.attention == .done)

        // The same bell under a plain working report, which is the arm that says
        // the finish is not what swallowed it.
        var working = PaneAttentionState()
        _ = working.noteReported(blocked: false, finished: false, message: nil)
        let rangUnderWorking = working.noteBell()
        #expect(rangUnderWorking == false)
        #expect(working.attention == PaneAttention.none)
    }

    /// A pane that has said nothing at all is untouched, at either visit. Nil is
    /// "no statement" for the finish exactly as it is for the block.
    @Test func noReportIsNotAFinish() {
        var state = PaneAttentionState()
        _ = state.noteBell()
        _ = state.noteFocused()
        #expect(state.attention == .acknowledged(message: nil))
    }
}
