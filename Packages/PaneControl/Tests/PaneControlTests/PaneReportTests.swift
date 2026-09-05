import Foundation
import Testing

@testable import PaneControl

/// What a pane says about itself, and the two rules that decide whether a given
/// statement is the one in force: sequence ordering, and expiry.
@Suite struct PaneReportTests {
    /// A fixed instant, so nothing here depends on the wall clock. Every test
    /// below builds its deadlines relative to this.
    static let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: The mapping onto the attention model

    /// **`isFinished` is not `!isAsking`, and this arm is the whole reason both
    /// readers exist here instead of at the call site.** The attention model
    /// takes two booleans, so somebody has to turn three cases into them, and the
    /// tempting spelling of the second is "not blocked". `working` is also not
    /// blocked, and a working agent has emphatically not finished: that spelling
    /// would mark every busy pane as done the moment it stopped asking a
    /// question. The app target that would hold the mistake has no test target.
    @Test func askingAndFinishedAreTwoQuestionsAndWorkingAnswersNoToBoth() {
        #expect(ReportedState.blocked.isAsking)
        #expect(ReportedState.blocked.isFinished == false)

        #expect(ReportedState.idle.isFinished)
        #expect(ReportedState.idle.isAsking == false)

        // The case that separates the two readers from one negated reader.
        #expect(ReportedState.working.isAsking == false)
        #expect(ReportedState.working.isFinished == false)
    }

    /// No statement can be both, at any case the enum has now or gains later.
    @Test func noStatementIsBothAskingAndFinished() {
        for state in ReportedState.allCases {
            #expect(!(state.isAsking && state.isFinished), "\(state) claims both")
        }
    }

    private func report(
        _ state: ReportedState,
        seq: UInt64? = nil,
        message: String? = nil,
        livingFor seconds: TimeInterval = 300
    ) -> PaneReport {
        PaneReport(
            state: state,
            message: message,
            seq: seq,
            expires: Self.now.addingTimeInterval(seconds)
        )
    }

    @Test func aFreshStoreHoldsNothing() {
        let store = ReportStore()
        #expect(store.live(at: Self.now) == nil)
    }

    @Test func theFirstReportIsAccepted() {
        var store = ReportStore()
        #expect(store.accept(report(.blocked, seq: 1)) == .accepted)
        #expect(store.live(at: Self.now)?.state == .blocked)
    }

    /// **The duplicate-hook test.** A hook can fire twice for one transition, so
    /// a repeated sequence must be ignored rather than refused: an error code
    /// would reach a `set -e` script that cannot tell a duplicate from a failure.
    @Test func aRepeatedSequenceIsSupersededAndChangesNothing() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 7, message: "first"))
        #expect(store.accept(report(.working, seq: 7, message: "second")) == .superseded)
        #expect(store.live(at: Self.now)?.state == .blocked)
        #expect(store.live(at: Self.now)?.message == "first")
    }

    @Test func anOlderSequenceIsSuperseded() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 7))
        #expect(store.accept(report(.idle, seq: 6)) == .superseded)
        #expect(store.live(at: Self.now)?.state == .blocked)
    }

    @Test func aNewerSequenceReplaces() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 7))
        #expect(store.accept(report(.idle, seq: 8)) == .accepted)
        #expect(store.live(at: Self.now)?.state == .idle)
    }

    /// A reporter that never numbers its reports is making no ordering claim, and
    /// every one of its statements is the current one.
    @Test func unnumberedReportsAlwaysReplaceEachOther() {
        var store = ReportStore()
        #expect(store.accept(report(.blocked)) == .accepted)
        #expect(store.accept(report(.working)) == .accepted)
        #expect(store.live(at: Self.now)?.state == .working)
    }

    /// **The reset trap.** A nil sequence arriving after a numbered one would
    /// otherwise silently restart the ordering, so a replayed old report could
    /// win. A reporter that numbers once must keep numbering.
    @Test func anUnnumberedReportAfterANumberedOneIsSuperseded() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 7))
        #expect(store.accept(report(.idle)) == .superseded)
        #expect(store.live(at: Self.now)?.state == .blocked)
    }

    @Test func aReportIsGoneOnceItExpires() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 1, livingFor: 60))
        #expect(store.live(at: Self.now.addingTimeInterval(59)) != nil)
        #expect(store.live(at: Self.now.addingTimeInterval(61)) == nil)
    }

    /// Expiry ends the report's authority and not its place in the sequence.
    /// Ordering is monotonic for the whole run, which is why the hook derives
    /// its sequence from a clock rather than a counter it could restart.
    @Test func expirySurrendersAuthorityButNotOrdering() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 7, livingFor: 60))
        #expect(store.live(at: Self.now.addingTimeInterval(61)) == nil)
        #expect(store.accept(report(.idle, seq: 6)) == .superseded)
    }

    @Test func releaseEmptiesTheStore() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 1))
        store.release()
        #expect(store.live(at: Self.now) == nil)
    }

    /// Release clears the held statement and not the ordering, for the same
    /// reason expiry does not.
    @Test func releaseDoesNotRewindTheSequence() {
        var store = ReportStore()
        _ = store.accept(report(.blocked, seq: 7))
        store.release()
        #expect(store.accept(report(.idle, seq: 6)) == .superseded)
    }

    @Test func theLastStatementSurvivesExpiryAndRelease() {
        var store = ReportStore()
        let report = PaneReport(state: .blocked, message: "m", seq: 1, expires: Date(timeIntervalSinceNow: 60))
        _ = store.accept(report)
        store.release()
        #expect(store.live(at: Date()) == nil)
        #expect(store.last?.state == .blocked)
        #expect(store.last?.seq == 1)
    }

    // MARK: One effective revision

    /// Break caught: accepting a renewal updates the live report but leaves a
    /// scheduler waiting on the replaced report's earlier deadline.
    @Test func anAcceptedRenewalReplacesThePublishedDeadline() {
        var store = ReportStore()
        let first = report(.blocked, seq: 7, livingFor: 30)
        let renewed = report(.blocked, seq: 8, livingFor: 90)

        _ = store.accept(first)
        _ = store.accept(renewed)
        let revision = store.revision(at: Self.now)

        #expect(revision.live == renewed)
        #expect(revision.last == renewed)
        #expect(revision.nextExpiry == Self.now.addingTimeInterval(90))
    }

    /// Break caught: a stale report rejected by sequence comparison cancels or
    /// postpones the accepted report's deadline.
    @Test func aRejectedSupersededReportCannotMoveThePublishedDeadline() {
        var store = ReportStore()
        let accepted = report(.blocked, seq: 7, livingFor: 30)

        _ = store.accept(accepted)
        #expect(store.accept(report(.working, seq: 6, livingFor: 90)) == .superseded)
        let revision = store.revision(at: Self.now)

        #expect(revision.live == accepted)
        #expect(revision.nextExpiry == Self.now.addingTimeInterval(30))
    }

    /// Break caught: release clears current authority but leaves an obsolete
    /// timer armed, allowing a second publication from the stale deadline.
    @Test func releaseRemovesThePublishedDeadlineButKeepsHistory() {
        var store = ReportStore()
        let held = report(.blocked, seq: 7, livingFor: 30)

        _ = store.accept(held)
        store.release()
        let revision = store.revision(at: Self.now)

        #expect(revision.live == nil)
        #expect(revision.last?.seq == 7)
        #expect(revision.nextExpiry == nil)
    }

    /// Break caught: a store that computes liveness correctly still advertises
    /// the elapsed deadline, making its owner repeatedly schedule expiry work.
    @Test func anExpiredRevisionHasNoNextDeadline() {
        var store = ReportStore()
        let held = report(.blocked, seq: 7, livingFor: 30)
        _ = store.accept(held)

        let revision = store.revision(at: Self.now.addingTimeInterval(31))

        #expect(revision.live == nil)
        #expect(revision.last == held)
        #expect(revision.nextExpiry == nil)
    }

    /// The deadline is exclusive: when the timer fires exactly at `expires`,
    /// authority has ended and must not be scheduled again for the same instant.
    @Test func aRevisionAtTheExactDeadlineIsExpired() {
        var store = ReportStore()
        let held = report(.blocked, seq: 7, livingFor: 30)
        _ = store.accept(held)

        let revision = store.revision(at: held.expires)

        #expect(revision.live == nil)
        #expect(revision.nextExpiry == nil)
    }
}
