import Foundation

/// The long poll, behind a clock seam.
///
/// Owns the parked table and every rule about parking, waking, expiring, and
/// evicting a `recv --wait` or `subscribe --wait`. What it does not own: time.
/// `schedule` and `cancel` are handed in at init, so the rules here are provable
/// against a recording scheduler with no `DispatchQueue` and no real deadline,
/// and the app supplies `DispatchQueue.main.asyncAfter` and `DispatchWorkItem`
/// the same way `LongPoll<DispatchWorkItem>` is instantiated in
/// `ControlServer`.
@MainActor
public final class LongPoll<Cancellable> {
    /// One answer for one connection: what to send, and what the caller does
    /// with the connection afterward.
    public struct Answer: Equatable {
        public let connection: Int
        public let response: ControlResponse
        public let close: Bool
        public let restartIdleClock: Bool

        public init(
            connection: Int,
            response: ControlResponse,
            close: Bool,
            restartIdleClock: Bool
        ) {
            self.connection = connection
            self.response = response
            self.close = close
            self.restartIdleClock = restartIdleClock
        }
    }

    /// What `park(id:pane:token:seconds:kind:)` did with the waiter it was
    /// handed.
    public enum ParkOutcome: Equatable {
        case parked
        case refused(ControlResponse)
    }

    private var waiters = ParkedRecvs<Cancellable>()
    private let schedule: (Int, @escaping @MainActor () -> Void) -> Cancellable
    private let cancel: (Cancellable) -> Void

    /// Set by the owner once construction is complete, since it is the owner
    /// that holds the `PaneGraph` a fired deadline needs to resolve against.
    /// `LongPoll` never touches the graph on its own initiative; every entry
    /// point that reads it is a call the owner makes, including this one.
    public var onDeadline: ((Int) -> Void)?

    public init(
        schedule: @escaping (Int, @escaping @MainActor () -> Void) -> Cancellable,
        cancel: @escaping (Cancellable) -> Void
    ) {
        self.schedule = schedule
        self.cancel = cancel
    }

    public func isParked(_ id: Int) -> Bool {
        waiters[id] != nil
    }

    // MARK: The long poll

    /// Parks a long poll that found nothing, or refuses it because this
    /// connection is already waiting on one.
    ///
    /// **A second `--wait` pipelined on one connection is answered, not
    /// swallowed.** NDJSON is a pipelinable wire and the spec keeps it
    /// `nc`-drivable on purpose, so two `recv --wait` frames can arrive before
    /// either has been answered. Overwriting the first waiter left its request
    /// with no response at all and its deadline still armed, to fire later and
    /// resolve the *second* waiter early. Rule 5 allows one request with no
    /// response, the over-cap line, and it is spent.
    ///
    /// Refusing the newcomer rather than resolving the incumbent, because
    /// resolving an incumbent closes its connection, and its connection is the
    /// newcomer's connection too: the newcomer would then have nowhere to be
    /// answered on, which is the same defect wearing a different hat.
    public func park(
        id: Int,
        pane: ControlPaneID,
        token: String,
        seconds: Int,
        kind: ParkedKind
    ) -> ParkOutcome {
        let deadline = schedule(seconds) { [weak self] in
            self?.onDeadline?(id)
        }

        let waiter = ParkedRecvs<Cancellable>.Waiter(
            pane: pane, token: token, deadline: deadline, kind: kind
        )
        switch waiters.park(id, waiter) {
        case .alreadyParked:
            // Never submitted, so cancelling is bookkeeping rather than a race:
            // it says out loud that this deadline will not be resolving anybody.
            cancel(deadline)
            return .refused(
                .failure(
                    .refused,
                    "this connection is already waiting. One long poll per connection: "
                        + "let this one answer, or send the next on its own connection."
                )
            )

        case .parked:
            // Capped at sixty by `wait(from:)`, which is where the cap belongs:
            // an uncapped long poll is a pool slot held forever by whoever asks
            // for it.
            return .parked
        }
    }

    /// Wakes every parked `recv` on a pane, for a message that just landed.
    ///
    /// Subscribers are woken by ``wakeSubscribers(graph:)`` instead: a mailbox
    /// delivery is addressed at one pane, and an event is not addressed at all.
    public func wake(pane: ControlPaneID, graph: inout PaneGraph) -> [Answer] {
        var answers: [Answer] = []
        for id in waiters.ids(of: pane) where waiters[id]?.kind == .recv {
            if let answer = resolveByDraining(id, graph: &graph) {
                answers.append(answer)
            }
        }
        return answers
    }

    /// Wakes every parked `subscribe` that now has something to read.
    ///
    /// Called after each emit. Walks the parked table, capped at sixteen
    /// connections, and re-reads the ring for each: that read is a filter over at
    /// most 512 entries, so the sweep is bounded by the two caps rather than by
    /// workspace size or by how chatty the panes are.
    ///
    /// A subscriber whose events were all filtered out is left parked, which is
    /// the difference between an edge-triggered subscription and a heartbeat.
    public func wakeSubscribers(graph: inout PaneGraph) -> [Answer] {
        var answers: [Answer] = []
        for id in waiters.ids {
            guard let waiter = waiters[id] else { continue }
            guard case let .subscribe(from, kinds) = waiter.kind else { continue }
            switch graph.subscribe(token: waiter.token, from: from, kinds: kinds) {
            case .denied:
                // Its token went bad while parked. Resolved through the same path
                // a live one takes, so the client is told rather than left to time
                // out against a capability that no longer exists.
                if let answer = resolveByReading(id, graph: &graph) {
                    answers.append(answer)
                }
            case let .ok(batch):
                guard batch.events.isEmpty == false else { continue }
                if let answer = resolveByReading(id, graph: &graph) {
                    answers.append(answer)
                }
            }
        }
        return answers
    }

    /// Resolves a parked waiter of either sort without touching what it was
    /// waiting on, and closes it.
    ///
    /// For the resolutions that are not about new data: the pane closed, the
    /// channel was switched off, the app is going away, or the slot was needed.
    /// An empty answer of the right shape rather than a bare EOF, because a
    /// client that already handles a timeout and a re-poll handles this, and a
    /// client that saw EOF would report the app as broken.
    ///
    /// The close is what makes an eviction an eviction. Resolving the wait alone
    /// would answer the request and leave the slot exactly as occupied as it was,
    /// so the connection is dropped from the pool here rather than when the
    /// client notices, which is a hop later and one connection over the cap.
    public func evict(id: Int, head: UInt64) -> Answer? {
        guard let waiter = waiters.remove(id) else { return nil }
        cancel(waiter.deadline)
        // No idle stamp on the way out, unlike ``resolveByDraining(_:)``: the
        // connection leaves the pool on the next line, so there is no clock left
        // for the sweep to read and writing one would be a value deleted by the
        // statement under it.

        switch waiter.kind {
        case .recv:
            return Answer(
                connection: id, response: .answer(for: Drain.empty),
                close: true, restartIdleClock: false
            )
        case .subscribe:
            // At the current head, not at the waiter's cursor: the caller is being
            // told "nothing more from me", and handing back a stale cursor would
            // make its next call re-read whatever landed while it waited.
            return Answer(
                connection: id, response: .answer(for: EventBatch.empty(at: head)),
                close: true, restartIdleClock: false
            )
        }
    }

    /// A token revoked, a pane closed, or the channel switched off while parked:
    /// resolved through the verb's own path so the client is told the truth
    /// rather than left to time out.
    public func expire(id: Int, graph: inout PaneGraph) -> [Answer] {
        guard let waiter = waiters[id] else { return [] }
        switch waiter.kind {
        case .recv:
            if let answer = resolveByDraining(id, graph: &graph) {
                return [answer]
            }
            return []
        case .subscribe:
            if let answer = resolveByReading(id, graph: &graph) {
                return [answer]
            }
            return []
        }
    }

    /// Answers a parked `recv` with whatever is in the mailbox now.
    ///
    /// Goes back through `recv(token:)`, so the wait is authorised on the way out
    /// exactly as it was on the way in. A pane that lost its capability while
    /// parked gets the honest answer rather than a drain nobody checked.
    private func resolveByDraining(_ id: Int, graph: inout PaneGraph) -> Answer? {
        // The deadline installed by `park` calls this for either sort, so a
        // subscriber's timeout is handed to the reader rather than draining a
        // mailbox it never asked about.
        guard waiters[id]?.kind == .recv else {
            return resolveByReading(id, graph: &graph)
        }
        guard let waiter = waiters.remove(id) else { return nil }
        cancel(waiter.deadline)

        // **The idle clock restarts when the long poll is answered, not when it
        // was parked.** `received` stamped it when the `recv` frame arrived, and
        // the waiter was exempt from the sweep only while it was in `waiters`, so
        // a `recv --wait 60` answered at t=60 would look sixty seconds stale to
        // the very next five second tick and be sent an unsolicited `refused` and
        // closed within five seconds of a successful answer. This connection did
        // not sit thirty seconds without completing a request; it completed one.
        switch graph.recv(token: waiter.token) {
        case let .denied(error):
            return Answer(
                connection: id, response: ControlResponse.failure(error),
                close: false, restartIdleClock: true
            )
        case let .ok(drain):
            return Answer(
                connection: id, response: .answer(for: drain),
                close: false, restartIdleClock: true
            )
        }
    }

    /// Answers a parked `subscribe` with whatever the ring holds now.
    ///
    /// Goes back through `graph.subscribe`, so the wait is authorised on the way
    /// out exactly as it was on the way in, matching ``resolveByDraining(_:)``.
    private func resolveByReading(_ id: Int, graph: inout PaneGraph) -> Answer? {
        // **The kind is checked before the waiter is taken out**, so a `recv`
        // arriving here by some future routing mistake is left where the drain
        // path can still find it. The order used to be the other way round: the
        // waiter was removed and its deadline cancelled, and then the kind check
        // returned, leaving a request with no response, no deadline to fire, and
        // a connection held until the idle sweep noticed. Unreachable today,
        // because `resolveByDraining` sends only what is not a `recv` here, and
        // one line of ordering is cheaper than depending on that staying true.
        guard case let .subscribe(from, kinds) = waiters[id]?.kind else { return nil }
        guard let waiter = waiters.remove(id) else { return nil }
        cancel(waiter.deadline)

        // The idle clock restarts when the long poll is answered, for
        // ``resolveByDraining(_:)``'s reason: this connection did not sit thirty
        // seconds without completing a request, it completed one.
        switch graph.subscribe(token: waiter.token, from: from, kinds: kinds) {
        case let .denied(error):
            return Answer(
                connection: id, response: ControlResponse.failure(error),
                close: false, restartIdleClock: true
            )
        case let .ok(batch):
            return Answer(
                connection: id, response: .answer(for: batch),
                close: false, restartIdleClock: true
            )
        }
    }
}
