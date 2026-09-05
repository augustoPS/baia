import Foundation
import Testing

@testable import PaneControl

/// The production report owner driven by Foundation's main run loop. These are
/// timing tests rather than a scheduler double because Timer retention and
/// invalidation are part of the lifecycle contract under test.
@Suite(.serialized) @MainActor struct ReportTimelineTests {
    private func report(_ state: ReportedState = .blocked, seq: UInt64, after seconds: Double) -> PaneReport {
        PaneReport(state: state, seq: seq, expires: Date().addingTimeInterval(seconds))
    }

    /// Break caught: liveness changes in the store but nobody publishes it when
    /// process activity, focus and view visibility remain unchanged.
    @Test func expiryPublishesTheExpiredRevisionWithoutAnotherInput() async throws {
        let timeline = ReportTimeline()
        var revisions: [ReportRevision] = []
        timeline.onExpiry = { revisions.append($0) }

        timeline.accept(report(seq: 1, after: 0.05))
        try await Task.sleep(for: .milliseconds(150))

        #expect(revisions.count == 1)
        #expect(revisions.first?.live == nil)
        #expect(revisions.first?.last?.seq == 1)
        #expect(revisions.first?.nextExpiry == nil)
        #expect(timeline.revision == revisions.first)
    }

    /// Break caught: renewing authority leaves the replaced timer armed, so the
    /// old deadline clears the renewal before its own expiry.
    @Test func renewalCancelsTheEarlierDeadline() async throws {
        let timeline = ReportTimeline()
        var expiredSequences: [UInt64?] = []
        timeline.onExpiry = { expiredSequences.append($0.last?.seq) }

        timeline.accept(report(seq: 1, after: 0.12))
        timeline.accept(report(seq: 2, after: 0.45))
        try await Task.sleep(for: .milliseconds(220))
        #expect(timeline.revision.live?.seq == 2)
        #expect(expiredSequences.isEmpty)

        try await Task.sleep(for: .milliseconds(320))
        #expect(expiredSequences == [2])
    }

    /// A superseded statement cannot install its deadline, while re-arming the
    /// accepted deadline cancels any obsolete queued timer.
    @Test func supersessionKeepsTheAcceptedDeadline() async throws {
        let timeline = ReportTimeline()
        var expiredSequences: [UInt64?] = []
        timeline.onExpiry = { expiredSequences.append($0.last?.seq) }

        let accepted = report(seq: 7, after: 0.40)
        let stale = report(.working, seq: 6, after: 0.08)
        timeline.accept(accepted)
        #expect(timeline.accept(stale) == .superseded)
        try await Task.sleep(for: .milliseconds(180))

        #expect(timeline.revision.live?.seq == 7)
        #expect(expiredSequences.isEmpty)
        try await Task.sleep(for: .milliseconds(320))
        #expect(expiredSequences == [7])
    }

    /// Break caught: release clears authority but leaves a timer that publishes
    /// a duplicate transition later.
    @Test func releaseCancelsThePendingDeadline() async throws {
        let timeline = ReportTimeline()
        var expiries = 0
        timeline.onExpiry = { _ in expiries += 1 }

        timeline.accept(report(seq: 1, after: 0.05))
        timeline.release()
        try await Task.sleep(for: .milliseconds(150))

        #expect(timeline.revision.live == nil)
        #expect(timeline.revision.last?.seq == 1)
        #expect(expiries == 0)
    }

    /// Break caught: the run loop retains a deadline after its pane owner is
    /// gone, allowing expiry work to publish into torn-down state.
    @Test func teardownInvalidatesThePendingDeadline() async throws {
        weak var releasedTimeline: ReportTimeline?
        var expired = false

        do {
            let timeline = ReportTimeline()
            releasedTimeline = timeline
            timeline.onExpiry = { _ in expired = true }
            timeline.accept(report(seq: 1, after: 0.05))
        }

        #expect(releasedTimeline == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(expired == false)
    }
}
