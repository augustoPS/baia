import Foundation
import Testing

@testable import PaneControl

/// The spec's third decision, edge-triggered and never level-triggered, which
/// until now was a comment inside a closure in a target with no tests.
@Suite struct ObservedPaneStateTests {
    /// The first look at a pane running nothing is not a change. A fresh state
    /// and an idle pane already agree, so publishing here would announce a
    /// transition that did not happen to every subscriber at startup.
    @Test func nothingIsPublishedForAPaneThatMatchesTheDefaults() {
        var state = ObservedPaneState()
        #expect(state.changes(activity: .idle, isAsking: false, message: nil, report: nil).isEmpty)
    }

    /// **The heartbeat test.** The tracker fires on a timer for any change to the
    /// pane's whole state, so this is called constantly with the same values. A
    /// level-triggered implementation would return a change every time.
    @Test func repeatedPollsWithTheSameValuesPublishNothing() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .running("claude"), isAsking: true, message: "needs input", report: nil)

        for _ in 0..<50 {
            #expect(state.changes(activity: .running("claude"), isAsking: true, message: "needs input", report: nil).isEmpty)
        }
    }

    /// The message changing while the pane is still asking is not a new raise.
    /// It has already asked; a second raise would double-count one request.
    @Test func aChangedMessageUnderASteadyRaiseIsNotANewRaise() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .idle, isAsking: true, message: "first", report: nil)
        #expect(state.changes(activity: .idle, isAsking: true, message: "second", report: nil).isEmpty)
    }

    @Test func aRaiseCarriesTheMessageAndItsSource() {
        var state = ObservedPaneState()
        let changes = state.changes(activity: .idle, isAsking: true, message: "needs input", report: nil)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .attentionRaised)
        #expect(changes.first?.message == "needs input")
        #expect(changes.first?.source == .osc)
    }

    /// A clear carries neither. The text was answered by the owner arriving, and
    /// a clear has one possible origin so it names none.
    @Test func aClearCarriesNeitherMessageNorSource() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .idle, isAsking: true, message: "needs input", report: nil)
        let changes = state.changes(activity: .idle, isAsking: false, message: "needs input", report: nil)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .attentionCleared)
        #expect(changes.first?.message == nil)
        #expect(changes.first?.source == nil)
    }

    /// **Activity first when both moved**, so a subscriber reading one batch sees
    /// what the pane is doing before it sees it ask, and can say "claude is
    /// asking" rather than reporting two unrelated facts.
    @Test func activityIsPublishedBeforeAttention() {
        var state = ObservedPaneState()
        let changes = state.changes(activity: .running("claude"), isAsking: true, message: "needs input", report: nil)
        #expect(changes.map(\.kind) == [.activityChanged, .attentionRaised])
    }

    /// An idle shell has no label, and going back to one is a transition worth
    /// publishing: the command a supervisor was told about has ended.
    @Test func fallingBackToNothingRunningIsAChange() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .running("swift"), isAsking: false, message: nil, report: nil)
        let changes = state.changes(activity: .idle, isAsking: false, message: nil, report: nil)
        #expect(changes.map(\.kind) == [.activityChanged])
        #expect(changes.first?.activity == nil)
    }

    /// Each transition is published once and the state moves with it, so a raise
    /// and a clear in sequence produce exactly two events rather than two per
    /// poll thereafter.
    @Test func aRaiseAndAClearProduceOneEventEach() {
        var state = ObservedPaneState()
        var all: [ControlEventKind] = []
        for asking in [true, true, true, false, false] {
            all += state.changes(activity: .idle, isAsking: asking, message: "m", report: nil).map(\.kind)
        }
        #expect(all == [.attentionRaised, .attentionCleared])
    }

    // MARK: The authority merge

    static let now = Date(timeIntervalSince1970: 2_000_000)

    private func live(_ state: ReportedState, message: String? = nil) -> PaneReport {
        PaneReport(state: state, message: message, seq: nil, expires: Self.now.addingTimeInterval(60))
    }

    /// **The resident-agent case, which is why `idle` exists.** The process tree
    /// says claude is running because it is; the agent says it has finished. The
    /// report wins and the activity clears, which nothing could do before.
    @Test func anIdleReportClearsAnActivityTheProcessTreeStillSees() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .running("claude"), isAsking: false, message: nil, report: nil)

        let changes = state.changes(
            activity: .running("claude"), isAsking: false, message: nil, report: live(.idle)
        )
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .activityChanged)
        #expect(changes.first?.activity == nil)
    }

    /// A report overrides the blocker authority in both directions. Here the OSC
    /// latch never fired and the report raises anyway.
    @Test func aBlockedReportRaisesWithoutAnyOSC() {
        var state = ObservedPaneState()
        let changes = state.changes(
            activity: .running("claude"), isAsking: false, message: nil,
            report: live(.blocked, message: "which branch?")
        )
        let raise = changes.first { $0.kind == .attentionRaised }
        #expect(raise != nil)
        #expect(raise?.message == "which branch?")
        #expect(raise?.source == .report)
    }

    /// And here the OSC latch is on and the report overrules it. A build that
    /// rang the bell does not keep a pane marked once its agent says otherwise.
    @Test func aWorkingReportOverrulesAStandingOSCRaise() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .idle, isAsking: true, message: "bell", report: nil)

        let changes = state.changes(
            activity: .idle, isAsking: true, message: "bell", report: live(.working)
        )
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .attentionCleared)
    }

    /// **Expiry needs no special case.** The report simply stops being passed in,
    /// and the comparator sees the poller's value differ from what was published.
    /// The OSC latch kept its own state throughout, so what applies now is its
    /// current value and not a stale one.
    @Test func authorityReturnsToTheLatchWhenAReportStopsArriving() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .idle, isAsking: true, message: "bell", report: live(.working))

        let changes = state.changes(activity: .idle, isAsking: true, message: "bell", report: nil)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .attentionRaised)
        #expect(changes.first?.source == .osc)
    }

    /// A report restating the current state is not a transition. This is the
    /// whole reason `report` needs no new event kinds.
    @Test func aRepeatedReportPublishesNothing() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .idle, isAsking: false, message: nil,
                          report: live(.blocked, message: "same"))

        for _ in 0..<20 {
            #expect(state.changes(activity: .idle, isAsking: false, message: nil,
                                  report: live(.blocked, message: "same")).isEmpty)
        }
    }

    // MARK: Abstaining

    /// **The recorded failure this fixes.** A pane running something the
    /// classifier cannot name used to publish nil, which reads as idle. Refusing
    /// to answer holds the last known label instead of asserting a wrong one.
    @Test func cannotTellHoldsTheLastLabelRatherThanClearingIt() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .running("claude"), isAsking: false, message: nil, report: nil)

        #expect(state.changes(activity: .cannotTell, isAsking: false, message: nil, report: nil).isEmpty)

        // Genuinely held, not merely unpublished: coming back to the same label
        // is still not a transition.
        #expect(state.changes(activity: .running("claude"), isAsking: false, message: nil, report: nil).isEmpty)
    }

    /// Abstaining says nothing about attention, which has its own authority.
    @Test func cannotTellStillPublishesAnAttentionChange() {
        var state = ObservedPaneState()
        let changes = state.changes(activity: .cannotTell, isAsking: true, message: "ring", report: nil)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .attentionRaised)
    }

    /// An `idle` report beats an abstaining poller. The agent knows it finished;
    /// the classifier only knows it cannot tell.
    @Test func anIdleReportBeatsAnAbstainingPoller() {
        var state = ObservedPaneState()
        _ = state.changes(activity: .running("claude"), isAsking: false, message: nil, report: nil)

        let changes = state.changes(
            activity: .cannotTell, isAsking: false, message: nil, report: live(.idle)
        )
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .activityChanged)
        #expect(changes.first?.activity == nil)
    }
}
