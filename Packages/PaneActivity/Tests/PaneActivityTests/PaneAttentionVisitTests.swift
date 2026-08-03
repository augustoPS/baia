import Foundation
import Testing

@testable import PaneActivity

/// What a visit is, separately from what any one level does with it.
///
/// **Why this suite is not folded into the other three.** `PaneAttentionStateTests`
/// and `PaneAttentionReportedTests` both watch `noteFocused()` through a pane that
/// is asking something, so both of them read the visit only where a request exists
/// to be quieted by it. Neither can see the visit itself, and the visit is a fact
/// on its own: it is recorded for a pane asking nothing, and it is what every
/// level that consumes a visit reads.
///
/// The failure behind that is recorded twice already, in `PaneAttention` and in
/// the spec. A pane raised by a report with no bell behind it has nothing in the
/// latch to acknowledge, so if the visit were recorded only where there was
/// something to quiet, that pane's volume could only ever be loud. Found live on
/// 2026-07-31, and every arm here exists so that a later level cannot put the
/// condition back by adding a branch to `noteFocused()`.
@Suite struct PaneAttentionVisitTests {
    /// The contract in one arm: a pane asking nothing records the visit, and
    /// nothing drawn moves.
    ///
    /// Both halves matter and they are read differently. "Nothing moved" is the
    /// return value and the resolved attention, which the caller uses to decide
    /// whether to repaint. "The visit was recorded" is invisible from outside
    /// until something asks, so it is proved by asking afterwards: a `blocked`
    /// arriving next must be loud, which is only true if the visit is one that a
    /// beginning request resets rather than one that was never taken.
    @Test func focusingAPaneThatWantsNothingRecordsTheVisitAndMovesNothing() {
        var state = PaneAttentionState()
        let changed = state.noteFocused()
        #expect(changed == false)
        #expect(state.attention == PaneAttention.none)
        #expect(state.hasBeenSeen)
    }

    /// The visit survives a report that says the pane is working, because nothing
    /// about a working report begins a request. Only a raise resets it.
    @Test func aWorkingReportLeavesTheVisitAlone() {
        var state = PaneAttentionState()
        _ = state.noteFocused()
        _ = state.noteReported(blocked: false, message: nil)
        #expect(state.hasBeenSeen)
    }

    /// A request beginning discards the visit that predates it, which is the rule
    /// stated as "reset where a request begins, not where one ends". Read here on
    /// the visit directly rather than through the volume, so that a level that
    /// consumes the visit some other way still has this pinned.
    @Test func aBlockedRaiseDiscardsAnEarlierVisit() {
        var state = PaneAttentionState()
        _ = state.noteFocused()
        #expect(state.hasBeenSeen)
        _ = state.noteReported(blocked: true, message: "which branch?")
        #expect(state.hasBeenSeen == false)
    }

    /// The same for the bell path, which begins a request without any report.
    @Test func aBellDiscardsAnEarlierVisit() {
        var state = PaneAttentionState()
        _ = state.noteFocused()
        _ = state.noteBell()
        #expect(state.hasBeenSeen == false)
    }

    /// A pane going back to work keeps the visit. `noteResumed` ends a request and
    /// a request ending is not where the visit resets, so clearing it here would
    /// silence nothing and would cost the next request its loud level for an owner
    /// who never left the pane.
    @Test func resumingLeavesTheVisitAlone() {
        var state = PaneAttentionState()
        _ = state.noteBell()
        _ = state.noteFocused()
        _ = state.noteResumed()
        #expect(state.hasBeenSeen)
    }
}
