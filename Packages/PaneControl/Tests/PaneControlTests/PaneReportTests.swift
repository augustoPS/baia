import Foundation
import Testing

@testable import PaneControl

/// What a pane says about itself, and the two rules that decide whether a given
/// statement is the one in force: sequence ordering, and expiry.
@Suite struct PaneReportTests {
    /// A fixed instant, so nothing here depends on the wall clock. Every test
    /// below builds its deadlines relative to this.
    static let now = Date(timeIntervalSince1970: 1_000_000)

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
}
