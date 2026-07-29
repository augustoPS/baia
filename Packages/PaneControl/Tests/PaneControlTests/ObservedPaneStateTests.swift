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
        #expect(state.changes(activity: nil, isAsking: false, message: nil).isEmpty)
    }

    /// **The heartbeat test.** The tracker fires on a timer for any change to the
    /// pane's whole state, so this is called constantly with the same values. A
    /// level-triggered implementation would return a change every time.
    @Test func repeatedPollsWithTheSameValuesPublishNothing() {
        var state = ObservedPaneState()
        _ = state.changes(activity: "claude", isAsking: true, message: "needs input")

        for _ in 0..<50 {
            #expect(state.changes(activity: "claude", isAsking: true, message: "needs input").isEmpty)
        }
    }

    /// The message changing while the pane is still asking is not a new raise.
    /// It has already asked; a second raise would double-count one request.
    @Test func aChangedMessageUnderASteadyRaiseIsNotANewRaise() {
        var state = ObservedPaneState()
        _ = state.changes(activity: nil, isAsking: true, message: "first")
        #expect(state.changes(activity: nil, isAsking: true, message: "second").isEmpty)
    }

    @Test func aRaiseCarriesTheMessageAndItsSource() {
        var state = ObservedPaneState()
        let changes = state.changes(activity: nil, isAsking: true, message: "needs input")
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .attentionRaised)
        #expect(changes.first?.message == "needs input")
        #expect(changes.first?.source == .osc)
    }

    /// A clear carries neither. The text was answered by the owner arriving, and
    /// a clear has one possible origin so it names none.
    @Test func aClearCarriesNeitherMessageNorSource() {
        var state = ObservedPaneState()
        _ = state.changes(activity: nil, isAsking: true, message: "needs input")
        let changes = state.changes(activity: nil, isAsking: false, message: "needs input")
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
        let changes = state.changes(activity: "claude", isAsking: true, message: "needs input")
        #expect(changes.map(\.kind) == [.activityChanged, .attentionRaised])
    }

    /// An idle shell has no label, and going back to one is a transition worth
    /// publishing: the command a supervisor was told about has ended.
    @Test func fallingBackToNothingRunningIsAChange() {
        var state = ObservedPaneState()
        _ = state.changes(activity: "swift", isAsking: false, message: nil)
        let changes = state.changes(activity: nil, isAsking: false, message: nil)
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
            all += state.changes(activity: nil, isAsking: asking, message: "m").map(\.kind)
        }
        #expect(all == [.attentionRaised, .attentionCleared])
    }
}
