import Foundation
import Testing

@testable import PaneControl

/// The long poll, proved against a recording scheduler rather than a real
/// clock: `schedule` captures the seconds and the action and hands back a
/// label the test can use to fire it by hand, so every deadline-fires case
/// here runs with no `DispatchQueue` and no wall-clock wait.
@Suite struct LongPollTests {
    /// A cancellable that is just a label, so `cancel` is observable without a
    /// real queue underneath it.
    final class Deadline {
        let label: String
        private(set) var cancelled = false
        init(_ label: String) { self.label = label }
        func cancel() { cancelled = true }
    }

    /// Records every `schedule` call and lets the test fire one by hand.
    final class RecordingScheduler {
        struct Recorded {
            let seconds: Int
            let action: @MainActor () -> Void
            let deadline: Deadline
        }

        private(set) var recorded: [Recorded] = []
        private var next = 0

        func schedule(seconds: Int, action: @escaping @MainActor () -> Void) -> Deadline {
            next += 1
            let deadline = Deadline("d\(next)")
            recorded.append(Recorded(seconds: seconds, action: action, deadline: deadline))
            return deadline
        }

        /// Fires the action the test asked for, exactly as a real deadline would:
        /// by calling the closure `schedule` was handed, with nothing else
        /// touched.
        @MainActor
        func fire(_ deadline: Deadline) {
            for entry in recorded where entry.deadline === deadline {
                entry.action()
            }
        }
    }

    /// Builds a `LongPoll` over the recording scheduler, wiring `onDeadline` the
    /// way `ControlServer` does: a fired deadline resolves against the graph the
    /// test hands in through the closure.
    @MainActor
    static func makePoll(
        scheduler: RecordingScheduler,
        graph: @escaping () -> PaneGraph,
        setGraph: @escaping (PaneGraph) -> Void,
        collect: @escaping ([LongPoll<Deadline>.Answer]) -> Void
    ) -> LongPoll<Deadline> {
        let poll = LongPoll<Deadline>(
            schedule: { seconds, action in scheduler.schedule(seconds: seconds, action: action) },
            cancel: { $0.cancel() }
        )
        poll.onDeadline = { id in
            var current = graph()
            let answers = poll.expire(id: id, graph: &current)
            setGraph(current)
            collect(answers)
        }
        return poll
    }

    static func pane() -> ControlPaneID { ControlPaneID(rawValue: UUID()) }

    static func secret(_ label: String) -> PaneSecret {
        PaneSecret("d5b0c6e2-not-a-uuid-\(label)")
    }

    // MARK: A second wait on one connection is refused

    @MainActor
    @Test func aPipelinedSecondWaitIsRefusedWithTheExistingMessage() {
        let scheduler = RecordingScheduler()
        var graph = PaneGraph()
        let mine = Self.pane()
        #expect(graph.open(pane: mine, createdBy: nil, secret: Self.secret("a")) == true)

        let poll = Self.makePoll(
            scheduler: scheduler,
            graph: { graph },
            setGraph: { graph = $0 },
            collect: { _ in }
        )

        #expect(
            poll.park(id: 1, pane: mine, token: Self.secret("a").rawValue, seconds: 60, kind: .recv)
                == .parked
        )

        let second = poll.park(
            id: 1, pane: mine, token: Self.secret("a").rawValue, seconds: 60, kind: .recv
        )
        guard case let .refused(response) = second else {
            Issue.record("a second park on the same connection should be refused")
            return
        }
        #expect(response.ok == false)
        #expect(
            response.error?.message
                == "this connection is already waiting. One long poll per connection: "
                    + "let this one answer, or send the next on its own connection."
        )

        // The incumbent is untouched: it is still parked, under the newcomer's
        // refusal.
        #expect(poll.isParked(1))
        // A refused wait schedules nothing: the table is asked before a
        // deadline exists, so the only deadline the clock ever saw is the
        // incumbent's, and it is untouched.
        #expect(scheduler.recorded.count == 1)
        #expect(scheduler.recorded[0].deadline.cancelled == false)
    }

    // MARK: A fired deadline on a recv

    @MainActor
    @Test func aFiredDeadlineOnARecvReturnsOneDrainAnswerAndRestartsTheIdleClock() {
        let scheduler = RecordingScheduler()
        var graph = PaneGraph()
        let mine = Self.pane()
        #expect(graph.open(pane: mine, createdBy: nil, secret: Self.secret("a")) == true)

        var collected: [LongPoll<Deadline>.Answer] = []
        let poll = Self.makePoll(
            scheduler: scheduler,
            graph: { graph },
            setGraph: { graph = $0 },
            collect: { collected = $0 }
        )

        #expect(
            poll.park(id: 1, pane: mine, token: Self.secret("a").rawValue, seconds: 60, kind: .recv)
                == .parked
        )
        #expect(scheduler.recorded.count == 1)

        scheduler.fire(scheduler.recorded[0].deadline)

        #expect(collected.count == 1)
        #expect(collected[0].connection == 1)
        #expect(collected[0].close == false)
        #expect(collected[0].restartIdleClock == true)
        #expect(collected[0].response.ok == true)
        #expect(collected[0].response.result?.messages == [])
        #expect(poll.isParked(1) == false)
    }

    // MARK: wakeSubscribers leaves a filtered subscriber parked and answers a matching one

    @MainActor
    @Test func wakeSubscribersLeavesParkedWhenFilteredAndAnswersWhenOnePasses() {
        let scheduler = RecordingScheduler()
        var graph = PaneGraph()
        let mine = Self.pane()
        #expect(graph.open(pane: mine, createdBy: nil, secret: Self.secret("a")) == true)

        let poll = Self.makePoll(
            scheduler: scheduler,
            graph: { graph },
            setGraph: { graph = $0 },
            collect: { _ in }
        )

        #expect(
            poll.park(
                id: 1, pane: mine, token: Self.secret("a").rawValue, seconds: 60,
                kind: .subscribe(from: 0, kinds: [.paneClosed])
            ) == .parked
        )

        // An event this subscriber filtered out: still parked, nothing to wake.
        graph.emit(.paneOpened, pane: mine, createdBy: nil, message: nil, activity: nil, source: nil)
        let noAnswers = poll.wakeSubscribers(graph: &graph)
        #expect(noAnswers.isEmpty)
        #expect(poll.isParked(1))

        // An event that passes the filter: answered and unparked.
        graph.emit(.paneClosed, pane: mine, createdBy: nil, message: nil, activity: nil, source: nil)
        let answers = poll.wakeSubscribers(graph: &graph)
        #expect(answers.count == 1)
        #expect(answers[0].connection == 1)
        #expect(answers[0].close == false)
        #expect(answers[0].restartIdleClock == true)
        #expect(answers[0].response.ok == true)
        #expect(answers[0].response.result?.events?.count == 1)
        #expect(poll.isParked(1) == false)
    }

    // MARK: A token revoked while parked is answered denied through expire

    @MainActor
    @Test func aTokenRevokedWhileParkedIsAnsweredDeniedThroughExpire() {
        let scheduler = RecordingScheduler()
        var graph = PaneGraph()
        let mine = Self.pane()
        #expect(graph.open(pane: mine, createdBy: nil, secret: Self.secret("a")) == true)

        let poll = Self.makePoll(
            scheduler: scheduler,
            graph: { graph },
            setGraph: { graph = $0 },
            collect: { _ in }
        )

        #expect(
            poll.park(id: 1, pane: mine, token: Self.secret("a").rawValue, seconds: 60, kind: .recv)
                == .parked
        )

        // The pane closes, which revokes its token: `authorize` now denies it.
        _ = graph.close(pane: mine)

        // `expire` is what a fired deadline calls; drive it directly to check
        // the denial without depending on the scheduler's bookkeeping.
        let answers = poll.expire(id: 1, graph: &graph)
        #expect(answers.count == 1)
        #expect(answers[0].response.ok == false)
        #expect(poll.isParked(1) == false)
    }

    // MARK: evict

    @MainActor
    @Test func evictAnswersEmptyAtTheCurrentHeadAndCloses() {
        let scheduler = RecordingScheduler()
        var graph = PaneGraph()
        let mine = Self.pane()
        #expect(graph.open(pane: mine, createdBy: nil, secret: Self.secret("a")) == true)
        graph.emit(.paneOpened, pane: mine, createdBy: nil, message: nil, activity: nil, source: nil)
        let head = graph.currentSequence

        let poll = Self.makePoll(
            scheduler: scheduler,
            graph: { graph },
            setGraph: { graph = $0 },
            collect: { _ in }
        )

        // A recv waiter.
        #expect(
            poll.park(id: 1, pane: mine, token: Self.secret("a").rawValue, seconds: 60, kind: .recv)
                == .parked
        )
        guard let recvAnswer = poll.evict(id: 1, head: head) else {
            Issue.record("evicting a parked recv should answer")
            return
        }
        #expect(recvAnswer.connection == 1)
        #expect(recvAnswer.close == true)
        #expect(recvAnswer.restartIdleClock == false)
        #expect(recvAnswer.response.ok == true)
        #expect(recvAnswer.response.result?.messages == [])
        #expect(poll.isParked(1) == false)
        #expect(scheduler.recorded[0].deadline.cancelled)

        // A subscribe waiter, answered empty at the given head rather than at
        // its own cursor.
        #expect(
            poll.park(
                id: 2, pane: mine, token: Self.secret("a").rawValue, seconds: 60,
                kind: .subscribe(from: 0, kinds: Set(ControlEventKind.allCases))
            ) == .parked
        )
        guard let subscribeAnswer = poll.evict(id: 2, head: head) else {
            Issue.record("evicting a parked subscribe should answer")
            return
        }
        #expect(subscribeAnswer.connection == 2)
        #expect(subscribeAnswer.close == true)
        #expect(subscribeAnswer.restartIdleClock == false)
        #expect(subscribeAnswer.response.ok == true)
        #expect(subscribeAnswer.response.result?.seq == head)
        #expect(subscribeAnswer.response.result?.events == [])
    }

    // MARK: park on an unknown connection

    /// The plan's sixth case reads "park on an unknown connection is a no-op".
    /// The no-op is `ControlServer`'s: `recv` and `subscribe` guard
    /// `connections[id] != nil` before ever calling `park`, on the pool's side
    /// of the seam, where the table of live connections is. What this layer can
    /// prove is the half it owns: an id it has never seen is an ordinary first
    /// park, nothing about "unknown" is special here, and so the guard has to
    /// stay on the pool's side rather than be repeated behind the interface.
    @MainActor
    @Test func parkKnowsNothingAboutWhichConnectionsExist() {
        let scheduler = RecordingScheduler()
        var graph = PaneGraph()
        let mine = Self.pane()
        #expect(graph.open(pane: mine, createdBy: nil, secret: Self.secret("a")) == true)

        let poll = Self.makePoll(
            scheduler: scheduler,
            graph: { graph },
            setGraph: { graph = $0 },
            collect: { _ in }
        )

        #expect(poll.isParked(999) == false)
        #expect(
            poll.park(
                id: 999, pane: mine, token: Self.secret("a").rawValue, seconds: 60, kind: .recv
            ) == .parked
        )
        #expect(poll.isParked(999))
    }

    // MARK: eviction keys off the waiter's pane

    /// A waiter belongs to the pane it was parked under, whatever the pool later
    /// says about its connection, so a pane closing finds every waiter parked
    /// under it and none parked under another.
    @MainActor
    @Test func parkedIdsAndOldestAreKeyedByTheWaitersPane() {
        let scheduler = RecordingScheduler()
        var graph = PaneGraph()
        let first = Self.pane()
        let second = Self.pane()
        #expect(graph.open(pane: first, createdBy: nil, secret: Self.secret("a")) == true)
        #expect(graph.open(pane: second, createdBy: nil, secret: Self.secret("b")) == true)

        let poll = Self.makePoll(
            scheduler: scheduler,
            graph: { graph },
            setGraph: { graph = $0 },
            collect: { _ in }
        )

        #expect(poll.parkedIds(of: first).isEmpty)
        #expect(poll.oldestParked(of: nil) == nil)
        #expect(poll.park(id: 7, pane: first, token: Self.secret("a").rawValue, seconds: 60, kind: .recv) == .parked)
        #expect(poll.park(id: 3, pane: second, token: Self.secret("b").rawValue, seconds: 60, kind: .recv) == .parked)
        #expect(poll.park(id: 9, pane: first, token: Self.secret("a").rawValue, seconds: 60, kind: .recv) == .parked)

        #expect(poll.parkedIds(of: first) == [7, 9])
        #expect(poll.parkedIds(of: second) == [3])
        #expect(poll.oldestParked(of: first) == 7)
        #expect(poll.oldestParked(of: second) == 3)
        #expect(poll.oldestParked(of: nil) == 3)

        _ = poll.evict(id: 7, head: graph.currentSequence)
        #expect(poll.parkedIds(of: first) == [9])
        #expect(poll.oldestParked(of: first) == 9)
    }
}
