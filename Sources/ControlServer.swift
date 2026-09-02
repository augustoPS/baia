import Foundation
import PaneControl
import WorkspaceLayout

/// The control channel, from the socket to the answer.
///
/// **The concurrency shape is the design and not an implementation detail.**
/// `PaneGraph` lives here, on the main actor, and the I/O layer never touches it.
/// `ControlTransport` reads bytes and cuts lines on its own serial queue, the
/// line is decoded there, and then there is exactly **one hop to the main actor
/// per request**, in ``hop(_:)``, to authorize and apply. The response is handed
/// back to the transport, which writes it on its queue again. One hop, one owner,
/// no lock, and nothing to make thread-safe: a malformed frame is answered
/// without ever reaching the main actor at all, because the decode already knows
/// what to say.
///
/// What it does not own: the workspace. Every verb that needs a window goes
/// through ``ControlWorkspaceBridge``, and every verb that needs the graph is
/// answered here, so authorization and layout never share a file.
@MainActor
final class ControlServer {
    /// What binding the socket did at launch.
    enum StartOutcome {
        case bound(String)

        /// Another baia answered on the socket. This instance runs without a
        /// channel and, per the spec, injects no `BAIA_SOCK`: handing its panes
        /// the first instance's live socket would answer `badToken` for secrets
        /// that were never registered there, which is a true error with a
        /// completely false story attached.
        case ownedByAnotherInstance(String)

        case failed(String)
    }

    /// `~/Library/Application Support/<support directory>/control.sock`, beside
    /// `session.json`. The directory is `baia` for the installed copy and
    /// `baia-dev` for the build under test, which is what lets both run at once:
    /// one socket each, so neither finds the other's already bound and falls back
    /// to no channel at all.
    ///
    /// Derived from `SessionStore.defaultFileURL()` rather than spelled again, so
    /// the two files cannot drift apart into two directories, and so the 0700
    /// directory `SessionStore` already creates is the one this binds in. Passing
    /// the same ``SupportDirectory/name`` to both is what keeps that true.
    static func defaultSocketPath() -> String {
        SessionStore.defaultFileURL(directoryName: SupportDirectory.name)
            .deletingLastPathComponent()
            .appending(path: "control.sock")
            .path(percentEncoded: false)
    }

    /// Where panes are told to talk, or nil when this instance runs without a
    /// channel.
    ///
    /// Read by the pane environment: nil means inject nothing.
    private(set) var boundSocketPath: String?

    /// The workspace side of the channel. Weak because the app owns it and a
    /// strong reference here would be a retain cycle through the adapter's own
    /// reference to this server.
    weak var bridge: ControlWorkspaceBridge?

    /// `controlChannelEnabled`.
    ///
    /// **False keeps the socket bound and answers every request `disabled`.**
    /// Unbinding was the first draft of the spec and it is wrong: an unbound
    /// socket is indistinguishable from a dead app, so every pane's `baia` would
    /// report a launch failure that never happened and the toggle would be
    /// invisible to the diagnostic.
    var isChannelEnabled = true

    /// `controlAllowRun`. False answers `run` with `disabled`, true answers it
    /// with `refused`, and that difference is the whole reason the verb is
    /// declared in v1.
    var isRunAllowed = false

    /// `controlAllowRead`, which defaults to true unlike `controlAllowRun`.
    var isReadAllowed = true

    private let socketPath: String
    private let transport: ControlTransport

    /// The registry, the parentage edges, the peer edges, the channels, and the
    /// mailboxes. Main actor, one owner, never handed to the I/O layer.
    private var graph = PaneGraph()

    private var connections: [Int: ConnectionState] = [:]

    /// One parked `recv` or `subscribe` per connection, and the rule that a
    /// second one is answered rather than swallowed. Behind `LongPoll` because
    /// the rule is decidable without a real clock, so `make test` decides it;
    /// this side supplies the one thing the package cannot: a scheduler.
    private lazy var longPoll: LongPoll<DispatchWorkItem> = {
        let main = DispatchQueue.main
        let poll = LongPoll<DispatchWorkItem>(
            schedule: { seconds, action in
                // `DispatchWorkItem(block:)` wants a plain, non-isolated block, so
                // the hop back onto the main actor is explicit here rather than
                // implicit in the conversion, matching ``hop(_:)`` above.
                let item = DispatchWorkItem {
                    MainActor.assumeIsolated(action)
                }
                main.asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
                return item
            },
            cancel: { $0.cancel() }
        )
        poll.onDeadline = { [weak self] id in
            guard let self else { return }
            self.apply(self.longPoll.expire(id: id, graph: &self.graph))
        }
        return poll
    }()

    /// Sweeps the idle cap. Alive only while there are connections, because a
    /// timer that ticks for the life of the app to look at an empty dictionary is
    /// a wakeup every five seconds for nothing.
    private var sweep: Timer?

    init(socketPath: String = ControlServer.defaultSocketPath()) {
        self.socketPath = socketPath
        transport = ControlTransport(path: socketPath)
    }

    // MARK: Lifetime

    func start() -> StartOutcome {
        let handlers = ControlTransportHandlers(
            accepted: { [weak self] id in
                Self.hop { self?.accepted(id) }
            },
            line: { [weak self] id, line in
                // **Decoded here, off the main actor.** This is the expensive
                // half of a request and the half that can fail, and both belong
                // on the channel queue: a frame that is not a request never
                // reaches the main thread, it is answered from what the decode
                // already knows.
                let decoded = ControlWire.decodeRequest(line)
                Self.hop { self?.received(decoded, on: id) }
            },
            oversized: { [weak self] id in
                Self.hop { self?.forget(id) }
            },
            closed: { [weak self] id in
                Self.hop { self?.forget(id) }
            }
        )

        switch transport.bind(handlers: handlers) {
        case .bound:
            boundSocketPath = socketPath
            return .bound(socketPath)
        case .ownedByAnotherInstance:
            boundSocketPath = nil
            return .ownedByAnotherInstance(socketPath)
        case let .failed(reason):
            boundSocketPath = nil
            return .failed(reason)
        }
    }

    /// Resolves every parked waiter, then drops the socket.
    ///
    /// The order is the contract: a parked `recv` is answered with an empty drain
    /// at app terminate and never left to see a bare EOF. `shutdown()` runs
    /// through the same serial queue those responses were queued on, so the write
    /// is attempted before the descriptor goes.
    func stop() {
        // `Array(connections.keys)`, not a live view, because evicting a waiter
        // removes its connection. Every loop over `connections` for eviction
        // relies on that.
        for id in Array(connections.keys) where longPoll.isParked(id) {
            if let answer = longPoll.evict(id: id, head: graph.currentSequence) {
                apply([answer])
            }
        }
        sweep?.invalidate()
        sweep = nil
        transport.shutdown()
        connections.removeAll()
        boundSocketPath = nil
    }

    // MARK: What the app tells the channel

    /// Records a live pane, its capability, and the pane that created it.
    ///
    /// The one door into the registry, and it is one-way: nothing here or in
    /// `PaneGraph` turns a secret back into a pane except
    /// `PaneGraph.authorize`.
    @discardableResult
    func registerPane(
        _ pane: ControlPaneID,
        createdBy: ControlPaneID?,
        secret: PaneSecret
    ) -> Bool {
        let registered = graph.open(pane: pane, createdBy: createdBy, secret: secret)
        // After, not before: `observers(of:)` reads the live parentage, and the
        // edge that puts the creator in the audience does not exist until `open`
        // records it. A refused registration emits nothing, because a pane with no
        // capability is a pane no subscriber can act on.
        if registered {
            graph.emit(
                .paneOpened, pane: pane, createdBy: createdBy,
                message: nil, activity: nil, source: nil
            )
            apply(longPoll.wakeSubscribers(graph: &graph))
        }
        return registered
    }

    /// Forgets a closed pane: its capability, its mailbox, its channels, its
    /// edges, and its children's parentage.
    ///
    /// Its parked long poll, if it had one, is resolved with an empty answer
    /// first. A waiter whose pane is gone would otherwise sit until its deadline
    /// and then be answered `badToken`, which tells a script that its own token
    /// went bad rather than that its pane closed.
    func forgetPane(_ pane: ControlPaneID) {
        for id in parkedIds(of: pane) {
            if let answer = longPoll.evict(id: id, head: graph.currentSequence) {
                apply([answer])
            }
        }
        // **Before `graph.close`, and this order is the design.** `close` deletes
        // the parentage and the peer edges, so an emit after it would compute an
        // audience of one and deliver the death notice to the pane that died. The
        // parent learning its child is gone is the case the whole audience design
        // exists for.
        graph.emit(
            .paneClosed, pane: pane, createdBy: nil,
            message: nil, activity: nil, source: nil
        )
        graph.close(pane: pane)
        apply(longPoll.wakeSubscribers(graph: &graph))
    }

    /// Records something observable about a live pane, and wakes whoever was
    /// waiting for it.
    ///
    /// No ordering rule here, unlike open and close: the pane is live at both ends
    /// of this call, so its audience is whatever the graph says now.
    ///
    /// **No `isChannelEnabled` gate, matching the two sites above.** The caller
    /// diffs the pane's state and updates that diff before it calls, so an event
    /// dropped here is spent: the controller will not offer it again until the
    /// next transition, and the reader that missed it sees contiguous sequence
    /// numbers and `gap: false`, which is loss the whole design says a subscriber
    /// can detect by arithmetic and here it cannot. Switching the channel off and
    /// on again would leave a supervisor reporting a pane as waiting for input
    /// for the rest of the run.
    ///
    /// Recording while the channel is off costs a ring slot and no disclosure:
    /// `serve` refuses every request with `.disabled` before the token is even
    /// looked at, and `settingsChanged` resolved every parked waiter on the way
    /// down, so there is nobody to read the ring during the window and nobody to
    /// wake.
    func noteEvent(
        _ kind: ControlEventKind,
        pane: ControlPaneID,
        message: String?,
        activity: String?,
        source: ControlEventSource?
    ) {
        graph.emit(
            kind, pane: pane, createdBy: nil,
            message: message, activity: activity, source: source
        )
        apply(longPoll.wakeSubscribers(graph: &graph))
    }

    /// Follows the two settings keys.
    ///
    /// Turning the channel off resolves every parked waiter, because a long poll
    /// against a channel that no longer answers is a shell hanging for up to a
    /// minute on a setting somebody just changed.
    func settingsChanged(channelEnabled: Bool, allowRun: Bool, allowRead: Bool) {
        isRunAllowed = allowRun
        isReadAllowed = allowRead
        guard channelEnabled != isChannelEnabled else { return }
        isChannelEnabled = channelEnabled
        guard channelEnabled == false else { return }
        for id in connections.keys.sorted() where longPoll.isParked(id) {
            if let answer = longPoll.evict(id: id, head: graph.currentSequence) {
                apply([answer])
            }
        }
    }

    // MARK: The hop

    /// The single main-actor hop, and the only one.
    ///
    /// `DispatchQueue.main.async` rather than `Task { @MainActor in }` for one
    /// reason that outweighs the syntax: dispatch is FIFO and unstructured tasks
    /// are not ordered against each other, so two requests arriving back to back
    /// on one connection could otherwise be applied in the order the scheduler
    /// felt like. `MainActor.assumeIsolated` is how the rest of this app crosses
    /// the same line.
    private nonisolated static func hop(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }

    // MARK: The pool

    private struct ConnectionState {
        /// The pane this connection has authenticated as, once it has. Nil until
        /// the first request whose token resolves, which is what makes the
        /// per-pane quota countable at all: a connection that never authenticates
        /// belongs to nobody and is bounded by the total cap and the idle cap
        /// alone.
        var pane: ControlPaneID?
        var lastRequest: Date
    }

    private func accepted(_ id: Int) {
        if connections.count >= ControlWire.maxConnections {
            // A full pool looks for something to give up before it refuses. A
            // parked long poll is the one connection holding a slot while waiting
            // on nothing, so it is the evictable one, and it is resolved with an
            // empty answer rather than dropped: a long-poll client already handles
            // a timeout and a re-poll.
            guard let victim = oldestParked(of: nil) else {
                // One frame, then closed. A connection silently dropped at a full
                // pool is indistinguishable from an app that died, and the two
                // want opposite things from the person reading the error.
                respond(
                    .failure(
                        .refused,
                        "baia is already serving \(ControlWire.maxConnections) control connections "
                            + "and none of them can be given up. Try again."
                    ),
                    to: id,
                    thenClose: true
                )
                return
            }
            if let answer = longPoll.evict(id: victim, head: graph.currentSequence) {
                apply([answer])
            }
        }

        connections[id] = ConnectionState(pane: nil, lastRequest: Date())
        startSweeping()
    }

    /// Attributes a connection to the pane it authenticated as, enforcing the
    /// per-pane quota.
    ///
    /// **The load-bearing half of the connection budget.** Without it one pane
    /// fills the pool and every other pane's `baia` stops working, which is a
    /// cross-pane effect out of a single compromised pane and the only kind of
    /// privilege this channel can grant.
    ///
    /// A pane at its quota gives up its own oldest parked long poll first. It never
    /// exceeds four either way, and evicting its own long poll to serve its own
    /// new request is the choice that keeps a script from deadlocking against
    /// itself.
    ///
    /// Returns false when the request has already been answered and closed.
    private func admit(_ id: Int, as actor: ControlPaneID) -> Bool {
        guard connections[id] != nil else { return false }
        if connections[id]?.pane == actor { return true }

        let held = connections.filter { $0.key != id && $0.value.pane == actor }.count
        if held >= ControlWire.maxConnectionsPerPane {
            if let victim = oldestParked(of: actor) {
                if let answer = longPoll.evict(id: victim, head: graph.currentSequence) {
                    apply([answer])
                }
            } else {
                respond(
                    .failure(
                        .refused,
                        "this pane already holds \(ControlWire.maxConnectionsPerPane) control "
                            + "connections, which is the per-pane cap. Let one finish first."
                    ),
                    to: id,
                    thenClose: true
                )
                return false
            }
        }

        connections[id]?.pane = actor
        return true
    }

    /// Every parked connection attributed to one pane.
    ///
    /// A pool bookkeeping helper, not a long-poll rule: which connections belong
    /// to a pane is `ControlServer`'s own state, so this reads `connections` and
    /// asks `longPoll.isParked` per id rather than reaching into the table.
    private func parkedIds(of pane: ControlPaneID) -> [Int] {
        connections.filter { $0.value.pane == pane && longPoll.isParked($0.key) }.keys.sorted()
    }

    /// The oldest parked connection, optionally restricted to one pane.
    ///
    /// A pool-eviction helper, not a long-poll rule: which connection to give up
    /// under pressure is the pool's question, so it is answered here from state
    /// `ControlServer` already owns, through `longPoll.isParked` alone.
    private func oldestParked(of pane: ControlPaneID?) -> Int? {
        connections
            .filter { longPoll.isParked($0.key) && (pane == nil || $0.value.pane == pane) }
            .keys
            .min()
    }

    private func forget(_ id: Int) {
        // No response and no resolution: the client is already gone, so the
        // waiter is dropped rather than answered. `evict` still cancels its
        // deadline and removes it from the table; the response it builds is
        // never written, because `transport.send` no-ops once `connections[id]`
        // is already gone below.
        _ = longPoll.evict(id: id, head: graph.currentSequence)
        connections[id] = nil
        if connections.isEmpty {
            sweep?.invalidate()
            sweep = nil
        }
    }

    private func startSweeping() {
        guard sweep == nil else { return }
        // Five seconds against a thirty second cap. A timer that fired on the cap
        // itself would let a squatter hold a slot for very nearly sixty.
        sweep = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sweepIdle()
            }
        }
    }

    /// Closes connections that have gone quiet.
    ///
    /// A parked long poll is exempt, and that is the reading of "a parked `recv`
    /// counts against both caps": both *connection* caps, the total and the
    /// per-pane one, which is where the sentence sits in the spec's pool
    /// paragraph. Counting it against the idle cap as well would make
    /// `--wait 60` unreachable, since the idle cap is thirty.
    private func sweepIdle() {
        let cutoff = Date().addingTimeInterval(-Double(ControlWire.idleTimeoutSeconds))
        // Collected before anything is written, because closing a connection
        // takes it out of the dictionary this is walking.
        let stale = connections
            .filter { $0.value.lastRequest < cutoff && longPoll.isParked($0.key) == false }
            .keys

        for id in stale {
            connections[id] = nil
            respond(
                .failure(
                    .refused,
                    "this connection sat \(ControlWire.idleTimeoutSeconds) seconds without a "
                        + "complete request. baia closes idle connections so one pane cannot "
                        + "squat the pool."
                ),
                to: id,
                thenClose: true
            )
        }
    }

    // MARK: One request

    private func received(_ decoded: ControlDecodeResult, on id: Int) {
        connections[id]?.lastRequest = Date()

        switch decoded {
        case let .failure(error):
            respond(ControlResponse.failure(error), to: id)
        case let .request(request):
            serve(request, on: id)
        }
    }

    private func serve(_ request: ControlRequest, on id: Int) {
        // The channel gate runs before the token check, so a disabled channel
        // answers one thing to everybody. The alternative leaks nothing and
        // costs a reader time: `badToken` from an instance that is not listening
        // to anybody sends them looking at their environment.
        guard isChannelEnabled else {
            respond(
                .failure(
                    .disabled,
                    "baia's control channel is switched off. Set `controlChannelEnabled` to true "
                        + "in ~/.config/baia/config.json to turn it back on."
                ),
                to: id
            )
            return
        }

        // **Identity comes out of the one resolver.** `PaneGraph` exposes no way
        // to turn a secret into a pane except `authorize`, deliberately, so the
        // caller is identified by asking the weakest question in the table:
        // whether this token may act on its own pane. A token that fails that
        // fails every verb, and the verb's own scope is still resolved below by
        // the same function. Two calls, one resolver, no second door.
        let actor: ControlPaneID
        switch graph.authorize(token: request.token, verb: .whoami, target: nil) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
            return
        case let .allowed(resolved, _):
            actor = resolved
        }

        guard admit(id, as: actor) else { return }

        if let gated = request.verb.gate(
            isReadAllowed: isReadAllowed,
            isRunAllowed: isRunAllowed
        ) {
            respond(ControlResponse.failure(gated), to: id)
            return
        }

        // No `default:`, matching `ControlVerb.scope` and the CLI's renderer. A
        // verb added without a route has to fail to compile here rather than fall
        // through to whatever the fallback happened to answer.
        switch request.verb {
        // `report` routes with the layout verbs because it reaches the pane
        // controller, not the graph: what it changes is one pane's own view of
        // itself, and the graph learns about it the same way it learns about a
        // poll, through the observable change the controller publishes.
        case .split, .close, .focus, .zoom, .resize, .equalize, .cwd, .report:
            layout(request, on: id)

        case .whoami:
            introspect(request, on: id, subjects: { [$0] })

        case .list:
            introspect(request, on: id, subjects: { self.graph.scope(of: $0) })

        case .peers:
            introspect(request, on: id, subjects: { actor in
                self.graph.peers(of: actor).sorted { $0.description < $1.description }
            })

        case .publish:
            publish(request, on: id)

        case .connect:
            connect(request, on: id)

        case .send:
            send(request, on: id)

        case .recv:
            recv(request, actor: actor, on: id)

        case .subscribe:
            subscribe(request, actor: actor, on: id)

        case .revoke:
            revoke(request, on: id)

        case .read:
            read(request, on: id)

        case .move:
            move(request, on: id)

        case .layoutExport:
            exportLayout(request, on: id)

        case .layoutApply:
            applyLayout(request, on: id)

        case .run:
            // Unreachable: `gate` answers `run` for both values of
            // `controlAllowRun`, which is the point of declaring the verb in v1.
            // The arm exists because the switch has no `default:` and never will.
            respond(
                .failure(.internal, "run is answered by its settings gate before it is routed"),
                to: id
            )
        }
    }

    // MARK: Verbs the workspace answers

    private func layout(_ request: ControlRequest, on id: Int) {
        switch graph.authorize(token: request.token, verb: request.verb, target: nil) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .allowed(_, target):
            guard let bridge else {
                respond(.failure(.internal, "baia has no workspace to apply that to"), to: id)
                return
            }
            respond(bridge.applyLayout(request.verb, to: target, args: request.args), to: id)
        }
    }

    /// Answers with a descendant pane's lines.
    ///
    /// **The target is authorised before it is read**, like everything else, and
    /// the scope is `.descendant`, so a peer is refused. `list` is peer-scoped and
    /// this is not: peering is a communication edge and a peer agreed to exchange
    /// messages rather than to be read.
    private func read(_ request: ControlRequest, on id: Int) {
        guard let named = request.args.peer else {
            respond(.failure(.badFrame, "read needs a pane id"), to: id)
            return
        }
        // An id that is not a UUID is `unauthorized` rather than `badFrame`, the
        // same answer a live pane out of scope gets. A caller able to tell a
        // malformed id from an out-of-scope one could probe the shape of the
        // namespace, which is the leak `authorize` refuses in every other verb.
        guard let target = ControlPaneID(uuidString: named) else {
            respond(.failure(.unauthorized, "no pane you may read"), to: id)
            return
        }
        switch graph.authorize(token: request.token, verb: .read, target: target) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .allowed(_, subject):
            guard let bridge else {
                respond(.failure(.internal, "baia has no workspace to read from"), to: id)
                return
            }
            guard let lines = bridge.readLines(from: subject) else {
                // A pane whose surface is not yet in a window reads as empty
                // rather than as an error, the same rule every tracker's first
                // poll follows.
                respond(.success(ControlResult(lines: [], truncated: false)), to: id)
                return
            }
            let answer = ScreenRead.tail(lines, limit: request.args.lines)
            respond(
                .success(ControlResult(lines: answer.lines, truncated: answer.truncated)),
                to: id
            )
        }
    }

    /// Puts one pane beside another.
    ///
    /// **Both ends go through the resolver, separately, and neither is optional.**
    /// The pane being moved is the obvious one; the pane it lands beside is the
    /// one it would be easy to skip, and skipping it would let a caller reshape a
    /// grid it does not own by naming one pane of its own and one of somebody
    /// else's. Two calls rather than one because `authorize` answers about one
    /// target, and a scope rule that took a pair would be a second resolver.
    ///
    /// A malformed id is `unauthorized` and not `badFrame`, for `read`'s reason: a
    /// caller able to tell a malformed id from an out-of-scope one could probe the
    /// shape of the namespace one id at a time.
    private func move(_ request: ControlRequest, on id: Int) {
        guard let named = request.args.peer, let beside = request.args.beside else {
            respond(
                .failure(.badFrame, "move needs a pane to move and a pane to move it beside"),
                to: id
            )
            return
        }
        guard let subject = ControlPaneID(uuidString: named),
              let target = ControlPaneID(uuidString: beside)
        else {
            respond(.failure(.unauthorized, "no pane you may move"), to: id)
            return
        }
        for pane in [subject, target] {
            if case let .denied(error) = graph.authorize(
                token: request.token, verb: .move, target: pane
            ) {
                respond(ControlResponse.failure(error), to: id)
                return
            }
        }
        guard let bridge else {
            respond(.failure(.internal, "baia has no workspace to move that in"), to: id)
            return
        }
        respond(
            bridge.move(subject, beside: target, axis: request.args.axis ?? .horizontal),
            to: id
        )
    }

    /// Describes the caller's window as a document.
    ///
    /// **The disclosure rule is `list`'s, run through `list`'s own resolver.** The
    /// shape of the window goes out whole and a working directory goes out only
    /// for a pane in ``permitted(_:token:)``, which is the identical call
    /// ``introspect(_:on:subjects:)`` makes. One set builder, so the two answers
    /// cannot drift into disagreeing about who is visible. The argument for why
    /// the shape is not filtered the same way is on `ControlVerb.layoutExport`.
    private func exportLayout(_ request: ControlRequest, on id: Int) {
        switch graph.authorize(token: request.token, verb: .layoutExport, target: nil) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .allowed(actor, _):
            guard let bridge else {
                respond(.failure(.internal, "baia has no workspace to describe"), to: id)
                return
            }
            let visible = Set(permitted(graph.scope(of: actor), token: request.token))
            guard let layout = bridge.layout(of: actor, disclosingDirectoriesFor: visible) else {
                // The caller's own pane, since this verb names no target, so
                // there is nothing to withhold: its window closed under it.
                respond(
                    .failure(
                        .notFound,
                        "baia no longer has that pane. Its window may have closed while this "
                            + "request was in flight."
                    ),
                    to: id
                )
                return
            }
            respond(.success(ControlResult(layout: layout)), to: id)
        }
    }

    /// Opens a new window from a document.
    ///
    /// `.selfOnly`, and it names no target, because it reaches no existing pane.
    /// The panes it creates are the caller's, the way a `split`'s is.
    private func applyLayout(_ request: ControlRequest, on id: Int) {
        guard let layout = request.args.layout else {
            respond(
                .failure(
                    .badFrame,
                    "layout apply needs a layout document, which the CLI reads from stdin"
                ),
                to: id
            )
            return
        }
        switch graph.authorize(token: request.token, verb: .layoutApply, target: nil) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .allowed(actor, _):
            guard let bridge else {
                respond(.failure(.internal, "baia has no workspace to open a window in"), to: id)
                return
            }
            respond(bridge.applyLayout(layout, createdBy: actor), to: id)
        }
    }

    /// The panes out of `subjects` this caller may see.
    ///
    /// Every one is run past the resolver rather than trusted from the set
    /// builder that produced it. The builders are ordinary code that could be
    /// wrong; `authorize` is the function whose job is to be right, so it gets the
    /// last word. Order is preserved, because `list` renders in it.
    private func permitted(_ subjects: [ControlPaneID], token: String) -> [ControlPaneID] {
        subjects.filter { subject in
            guard case .allowed = graph.authorize(token: token, verb: .list, target: subject)
            else { return false }
            return true
        }
    }

    /// `whoami`, `list`, and `peers`, which differ only in which panes they name.
    ///
    /// One implementation for all three, because a second renderer is a second
    /// place for a scope leak to look ordinary, and because a read leak fails by
    /// over-succeeding rather than by refusing.
    ///
    /// Every subject is run past the resolver again before its record is built.
    /// The set builders above are ordinary code that could be wrong; `authorize`
    /// is the function whose job is to be right, so it gets the last word.
    ///
    /// `seq` rides along on every introspection answer, which is what makes
    /// `list` the bootstrap: a subscriber reads the records and the sequence they
    /// were read at in one frame, so there is no window in which an event lands
    /// between the snapshot and the cursor and is seen by neither.
    private func introspect(
        _ request: ControlRequest,
        on id: Int,
        subjects: (ControlPaneID) -> [ControlPaneID]
    ) {
        switch graph.authorize(token: request.token, verb: request.verb, target: nil) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)

        case let .allowed(actor, _):
            guard let bridge else {
                respond(.failure(.internal, "baia has no workspace to describe"), to: id)
                return
            }

            // Two passes, and the first one is the scope rule. A record carries
            // ids that reach outside the pane it describes, so which panes the
            // caller may see has to be settled before any record is built:
            // filtering as we went would leave the first record redacted against
            // a set that had not finished growing.
            let permitted = permitted(subjects(actor), token: request.token)
            let visible = Set(permitted.map(\.description))

            var records: [PaneRecord] = []
            for subject in permitted {
                guard var record = bridge.record(for: subject) else { continue }
                // The graph owns the channel names and the peer edges; the
                // workspace owns everything else about a pane. Folded in here
                // rather than asked of the bridge, so the adapter has no reason
                // to hold a reference to the graph at all.
                record.channels = graph.publishedNames(of: subject)
                record.peers = graph.peers(of: subject)
                    .map(\.description)
                    .sorted()
                records.append(record.redacted(toVisible: visible))
            }
            respond(.success(ControlResult(panes: records, seq: graph.currentSequence)), to: id)
        }
    }

    // MARK: Verbs the graph answers

    private func publish(_ request: ControlRequest, on id: Int) {
        guard let minted = ControlSecrets.mint() else {
            respond(.failure(.internal, "baia could not mint a rendezvous ticket"), to: id)
            return
        }
        let ticket = RendezvousToken(minted)

        let outcome = request.args.rotate == true
            ? graph.rotate(token: request.token, name: request.args.name, ticket: ticket)
            : graph.publish(token: request.token, name: request.args.name, ticket: ticket)

        switch outcome {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .ok(publication):
            // The one secret-shaped value the wire carries, and it goes to the
            // pane that minted it, in the response to that pane's own `publish`,
            // and nowhere else.
            respond(
                .success(ControlResult(
                    name: publication.name,
                    rendezvous: publication.rendezvous.rawValue
                )),
                to: id
            )
        }
    }

    private func connect(_ request: ControlRequest, on id: Int) {
        guard let ticket = request.args.rendezvous, ticket.isEmpty == false else {
            respond(
                .failure(.badFrame, "connect needs a rendezvous ticket, which the CLI reads from stdin"),
                to: id
            )
            return
        }
        guard let minted = ControlSecrets.mint() else {
            respond(.failure(.internal, "baia could not mint an edge secret"), to: id)
            return
        }

        switch graph.connect(
            token: request.token,
            rendezvous: ticket,
            edgeSecret: EdgeSecret(minted)
        ) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .ok(connection):
            respond(
                .success(ControlResult(pane: connection.peer.description, name: connection.name)),
                to: id
            )
        }
    }

    private func send(_ request: ControlRequest, on id: Int) {
        guard let peer = request.args.peer, let text = request.args.text else {
            respond(.failure(.badFrame, "send needs a peer and a message body"), to: id)
            return
        }

        switch graph.send(token: request.token, peer: peer, text: text) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .ok(recipient):
            // A parked `recv` on the receiving pane is woken here rather than by
            // its own deadline, which is the whole point of the long poll: a
            // message that arrived a second in should not wait out the other
            // fifty-nine.
            apply(longPoll.wake(pane: recipient, graph: &graph))
            respond(.success(), to: id)
        }
    }

    private func revoke(_ request: ControlRequest, on id: Int) {
        guard let peer = request.args.peer else {
            respond(.failure(.badFrame, "revoke needs the peer's display pane id"), to: id)
            return
        }

        switch graph.revoke(token: request.token, peer: peer) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case .ok:
            respond(.success(), to: id)
        }
    }

    // MARK: The long poll

    /// How long this request asked to wait, capped, or nil when it asked for no
    /// wait at all.
    ///
    /// One reader for both sorts of long poll. The cap is applied here rather
    /// than trusted from the client: an uncapped long poll is a pool slot held
    /// forever by whoever asks for it.
    private func wait(from request: ControlRequest) -> Int? {
        ControlWire.cappedWait(request.args.wait)
    }

    private func recv(_ request: ControlRequest, actor: ControlPaneID, on id: Int) {
        switch graph.recv(token: request.token) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)

        case let .ok(drain):
            guard drain.messages.isEmpty, drain.dropped == 0, let seconds = wait(from: request)
            else {
                respond(.answer(for: drain), to: id)
                return
            }
            guard connections[id] != nil else { return }
            switch longPoll.park(
                id: id, pane: actor, token: request.token, seconds: seconds, kind: .recv
            ) {
            case .parked:
                break
            case let .refused(response):
                respond(response, to: id)
            }
        }
    }

    /// Reads the caller's view of the ring, and parks when there is nothing yet.
    ///
    /// The kind filter is resolved here rather than at decode, so a misspelled
    /// kind is answered `refused` with its own name in the message instead of
    /// `badFrame` from a decoder that got no further. The CLI checks it too; this
    /// check is the rule, because a frame can arrive without the CLI.
    private func subscribe(_ request: ControlRequest, actor: ControlPaneID, on id: Int) {
        // `ControlEventKind.resolve` and not a copy of it here. The rule is
        // decidable without a descriptor, so it lives where `make test` reaches
        // it, and this is the only caller that a frame arriving without the CLI
        // can meet.
        let kinds: Set<ControlEventKind>
        switch ControlEventKind.resolve(request.args.kinds) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
            return
        case let .ok(resolved):
            kinds = resolved
        }

        let cursor = request.args.from ?? 0

        switch graph.subscribe(token: request.token, from: cursor, kinds: kinds) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)

        case let .ok(batch):
            // A gap is answered now rather than parked on: the caller has to
            // re-bootstrap, and making it wait sixty seconds first would delay the
            // one thing it needs to do.
            guard batch.events.isEmpty, batch.gap == false, let seconds = wait(from: request)
            else {
                respond(.answer(for: batch), to: id)
                return
            }
            guard connections[id] != nil else { return }
            switch longPoll.park(
                id: id,
                pane: actor,
                token: request.token,
                seconds: seconds,
                kind: .subscribe(from: cursor, kinds: kinds)
            ) {
            case .parked:
                break
            case let .refused(response):
                respond(response, to: id)
            }
        }
    }

    /// Applies every answer a long-poll resolution produced: writes the
    /// response, restarts the idle clock when the answer says to, and drops the
    /// connection when the answer says to close it.
    ///
    /// One place for the bookkeeping every resolution path shares, so `LongPoll`
    /// itself never touches `connections` or the transport.
    private func apply(_ answers: [LongPoll<DispatchWorkItem>.Answer]) {
        for answer in answers {
            if answer.restartIdleClock {
                connections[answer.connection]?.lastRequest = Date()
            }
            respond(answer.response, to: answer.connection, thenClose: answer.close)
            if answer.close {
                connections[answer.connection] = nil
            }
        }
    }

    // MARK: Writing back

    /// Frames one response and hands it to the transport.
    ///
    /// The frame cap applies in this direction too, and a response that does not
    /// fit is replaced rather than truncated: a client reading a half line would
    /// answer for baia, and what it would say is that the app is broken.
    private func respond(_ response: ControlResponse, to id: Int, thenClose: Bool = false) {
        if let line = ControlWire.encodeResponse(response), ControlWire.fitsFrame(line) {
            transport.send(line, to: id, thenClose: thenClose)
            return
        }

        let fallback = ControlResponse.failure(
            .internal,
            "baia's answer did not fit a \(ControlWire.maxFrameBytes) byte frame"
        )
        if let line = ControlWire.encodeResponse(fallback), ControlWire.fitsFrame(line) {
            transport.send(line, to: id, thenClose: true)
            return
        }

        transport.close(id)
    }
}
