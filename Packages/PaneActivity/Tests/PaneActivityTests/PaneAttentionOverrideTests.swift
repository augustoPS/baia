import Foundation
import Testing

@testable import PaneActivity

/// What the pane's own statement about itself does to the attention the chrome
/// draws.
///
/// **The rule this suite exists to pin: the report owns whether the pane is
/// asking, and the latch owns how loudly.** A report answers "does the agent
/// still need me". Acknowledgement answers "have I been here since it started",
/// which is a different question that a report has no view on.
@Suite struct PaneAttentionOverrideTests {
    // MARK: No report

    /// Every latch state is left exactly as it is. Nothing about this rule may
    /// change a pane that has made no statement about itself.
    @Test func noReportChangesNothing() {
        #expect(PaneAttention.none.overridden(byReportedBlock: nil, message: nil) == .none)
        #expect(
            PaneAttention.requested(message: "bell").overridden(byReportedBlock: nil, message: nil)
                == .requested(message: "bell")
        )
        #expect(
            PaneAttention.acknowledged(message: "bell").overridden(byReportedBlock: nil, message: nil)
                == .acknowledged(message: "bell")
        )
    }

    /// **A message with no report is not a report.** Nil is the only thing that
    /// means "the pane has said nothing", so a stray message cannot smuggle a
    /// state in beside it.
    @Test func aMessageWithoutAReportIsIgnored() {
        #expect(
            PaneAttention.none.overridden(byReportedBlock: nil, message: "which branch?") == .none
        )
    }

    // MARK: A blocked report

    @Test func aBlockedReportMakesAQuietPaneAsk() {
        let after = PaneAttention.none.overridden(byReportedBlock: true, message: "which branch?")
        #expect(after == .requested(message: "which branch?"))
        #expect(after.isUnacknowledged)
    }

    /// **The heart of the decision.** A pane the owner has already been to stays
    /// quiet, because acknowledgement is about the owner and the report has no
    /// view on it. Staying loud would reproduce the failure the hub records under
    /// the two-level model: a pane that ever rang staying marked for life, with
    /// the owner working in the very pane that is shouting.
    @Test func aBlockedReportDoesNotShoutAtAPaneTheOwnerHasSeen() {
        let after = PaneAttention.acknowledged(message: "bell")
            .overridden(byReportedBlock: true, message: "which branch?")
        #expect(after == .acknowledged(message: "which branch?"))
        #expect(after.isRequesting)
        #expect(after.isUnacknowledged == false)
    }

    /// A report that repeats itself while the pane is already asking loudly does
    /// not change the volume either.
    @Test func aBlockedReportLeavesALoudPaneLoud() {
        #expect(
            PaneAttention.requested(message: "bell")
                .overridden(byReportedBlock: true, message: "which branch?")
                == .requested(message: "which branch?")
        )
    }

    /// The report's message wins, because the report is the thing asking. The
    /// latch's message may be an hour-old bell from a build.
    @Test func theReportsMessageWinsOverTheLatchs() {
        #expect(
            PaneAttention.requested(message: "an old bell")
                .overridden(byReportedBlock: true, message: "which branch?")
                .message == "which branch?"
        )
    }

    /// A blocked report with nothing to say still asks. `PaneActivityTracker`
    /// substitutes its own marker when there is no label to draw, which is a
    /// display decision and stays one.
    @Test func aBlockedReportWithNoMessageStillAsks() {
        #expect(
            PaneAttention.none.overridden(byReportedBlock: true, message: nil)
                == .requested(message: nil)
        )
    }

    // MARK: A report that is not blocked

    /// **This is the case a plain `Bool` could not express**, and the reason the
    /// argument is optional. "The agent says it is working" and "the agent has
    /// said nothing" are different facts: the first outranks a bell the pane
    /// emitted earlier, the second leaves that bell alone.
    @Test func aWorkingReportSilencesABellThePaneEmittedEarlier() {
        #expect(
            PaneAttention.requested(message: "bell").overridden(byReportedBlock: false, message: nil)
                == .none
        )
        #expect(
            PaneAttention.acknowledged(message: "bell")
                .overridden(byReportedBlock: false, message: nil) == .none
        )
    }

    @Test func aWorkingReportLeavesAQuietPaneQuiet() {
        #expect(PaneAttention.none.overridden(byReportedBlock: false, message: nil) == .none)
    }

    // MARK: A report that the pane finished

    /// The level itself: a finish nobody has been present for.
    @Test func aFinishNobodyHasSeenIsDone() {
        #expect(PaneAttention.none.overridden(byReportedFinish: true, seen: false) == .done)
    }

    /// **The asymmetry, in one arm.** A visit quiets a block and *ends* a finish.
    /// A finish carries no request, so there is nothing left to be quietly still
    /// waiting for, and a quieter tier for it would be a badge that outlived its
    /// only job.
    @Test func aVisitEndsAFinishRatherThanQuietingIt() {
        #expect(PaneAttention.none.overridden(byReportedFinish: true, seen: true) == .none)
        // The same visit, through the other function, quiets rather than ends.
        #expect(
            PaneAttention.none.overridden(byReportedBlock: true, message: "which branch?", seen: true)
                == .acknowledged(message: "which branch?")
        )
    }

    /// A pane that has not finished is left exactly as it is, at every latch and
    /// either visit. This function may only ever add the new level.
    @Test func noFinishChangesNothing() {
        for latch in [PaneAttention.none, .requested(message: "b"), .acknowledged(message: "b"), .done] {
            for seen in [true, false] {
                #expect(latch.overridden(byReportedFinish: false, seen: seen) == latch)
            }
        }
    }

    /// A finish outranks a bell the pane rang earlier, the same way a working
    /// report does. The agent rang, kept going and then said it was finished, so
    /// the bell is answered by the statement that followed it.
    @Test func anUnseenFinishOutranksAnEarlierBell() {
        #expect(PaneAttention.requested(message: "bell").overridden(byReportedFinish: true, seen: false) == .done)
        #expect(PaneAttention.acknowledged(message: "bell").overridden(byReportedFinish: true, seen: false) == .done)
    }

    /// `done` carries nothing to say. The wire puts a message on `blocked` alone,
    /// so a message surviving into this level could only be a stale one from a
    /// question the pane has stopped asking.
    @Test func doneHasNoMessage() {
        #expect(PaneAttention.requested(message: "which branch?")
            .overridden(byReportedFinish: true, seen: false).message == nil)
    }

    /// `done` asks nothing. Anything reading `isRequesting` to decide whether to
    /// interrupt the owner has to answer no, and anything reading
    /// `isUnacknowledged` for the loud level has to as well: unseen and loud are
    /// the same word for a block and different facts for a finish.
    @Test func doneIsNeitherRequestingNorLoud() {
        #expect(PaneAttention.done.isRequesting == false)
        #expect(PaneAttention.done.isUnacknowledged == false)
        #expect(PaneAttention.done.isDone)
        #expect(PaneAttention.acknowledged(message: "b").isDone == false)
    }

    /// A block arriving over a finish is a new question and outranks it. The
    /// agent finished, was started again and is now asking, and the notification
    /// it left is answered by the question that replaced it.
    @Test func aBlockedReportOutranksAFinish() {
        let after = PaneAttention.done.overridden(byReportedBlock: true, message: "which branch?")
        #expect(after == .requested(message: "which branch?"))
        #expect(after.isUnacknowledged)
    }

    // MARK: Idempotence

    /// Applying the rule twice is applying it once, so a caller that re-derives
    /// on every poll cannot drift.
    @Test func theRuleIsIdempotent() {
        for latch in [PaneAttention.none, .requested(message: "b"), .acknowledged(message: "b"), .done] {
            for blocked in [nil, true, false] as [Bool?] {
                let once = latch.overridden(byReportedBlock: blocked, message: "m")
                let twice = once.overridden(byReportedBlock: blocked, message: "m")
                #expect(once == twice, "not idempotent for \(latch) and \(String(describing: blocked))")
            }
        }
    }

    /// The same for the finish rule, which a caller re-derives on every poll for
    /// as long as the report stays live.
    @Test func theFinishRuleIsIdempotent() {
        for latch in [PaneAttention.none, .requested(message: "b"), .acknowledged(message: "b"), .done] {
            for seen in [true, false] {
                let once = latch.overridden(byReportedFinish: true, seen: seen)
                let twice = once.overridden(byReportedFinish: true, seen: seen)
                #expect(once == twice, "not idempotent for \(latch) and seen \(seen)")
            }
        }
    }
}
