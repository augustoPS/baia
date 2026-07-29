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

    /// `~/Library/Application Support/baia/control.sock`, beside `session.json`.
    ///
    /// Derived from `SessionStore.defaultFileURL()` rather than spelled again, so
    /// the two files cannot drift apart into two directories, and so the 0700
    /// directory `SessionStore` already creates is the one this binds in.
    static func defaultSocketPath() -> String {
        SessionStore.defaultFileURL()
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

    private let socketPath: String
    private let transport: ControlTransport

    /// The registry, the parentage edges, the peer edges, the channels, and the
    /// mailboxes. Main actor, one owner, never handed to the I/O layer.
    private var graph = PaneGraph()

    private var connections: [Int: ConnectionState] = [:]

    /// One parked `recv` per connection, and the rule that a second one is
    /// answered rather than swallowed. The table is in the pure package because
    /// the rule is decidable without a descriptor, so `make test` decides it.
    private var waiters = ParkedRecvs<DispatchWorkItem>()

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
        // `ids` is an array, not a live key view, because resolving a waiter
        // removes it. Every loop over `waiters` here relies on that.
        for id in waiters.ids {
            resolveEmpty(id)
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
            graph.emit(.paneOpened, pane: pane, createdBy: createdBy, message: nil, activity: nil)
            wakeSubscribers()
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
        for id in waiters.ids(of: pane) {
            resolveEmpty(id)
        }
        // **Before `graph.close`, and this order is the design.** `close` deletes
        // the parentage and the peer edges, so an emit after it would compute an
        // audience of one and deliver the death notice to the pane that died. The
        // parent learning its child is gone is the case the whole audience design
        // exists for.
        graph.emit(.paneClosed, pane: pane, createdBy: nil, message: nil, activity: nil)
        graph.close(pane: pane)
        wakeSubscribers()
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
        activity: String?
    ) {
        graph.emit(kind, pane: pane, createdBy: nil, message: message, activity: activity)
        wakeSubscribers()
    }

    /// Follows the two settings keys.
    ///
    /// Turning the channel off resolves every parked waiter, because a long poll
    /// against a channel that no longer answers is a shell hanging for up to a
    /// minute on a setting somebody just changed.
    func settingsChanged(channelEnabled: Bool, allowRun: Bool) {
        isRunAllowed = allowRun
        guard channelEnabled != isChannelEnabled else { return }
        isChannelEnabled = channelEnabled
        guard channelEnabled == false else { return }
        for id in waiters.ids {
            resolveEmpty(id)
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
            guard let victim = waiters.oldest(of: nil) else {
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
            resolveEmpty(victim)
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
            if let victim = waiters.oldest(of: actor) {
                resolveEmpty(victim)
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

    private func forget(_ id: Int) {
        // No response and no resolution: the client is already gone, so the
        // waiter is dropped rather than answered.
        waiters.remove(id)?.deadline.cancel()
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
            .filter { $0.value.lastRequest < cutoff && waiters[$0.key] == nil }
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

        if let gated = gate(request.verb) {
            respond(ControlResponse.failure(gated), to: id)
            return
        }

        // No `default:`, matching `ControlVerb.scope` and the CLI's renderer. A
        // verb added without a route has to fail to compile here rather than fall
        // through to whatever the fallback happened to answer.
        switch request.verb {
        case .split, .close, .focus, .zoom, .resize, .equalize:
            layout(request, on: id)

        case .whoami:
            introspect(request, on: id, subjects: { [$0] })

        case .list:
            introspect(request, on: id, subjects: { self.scope(of: $0) })

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

    /// The settings answer for a verb, or nil when settings have nothing to say.
    ///
    /// No `default:`, for `ControlVerb.settingGate`'s reason: a verb whose gate
    /// was never decided must not inherit the permissive one by falling through.
    private func gate(_ verb: ControlVerb) -> ControlError? {
        switch verb.settingGate {
        case .channel:
            // Already answered above, for every verb, before the token was read.
            nil
        case .allowRun:
            isRunAllowed
                ? ControlError(
                    code: .refused,
                    message: "run lands in v2. The verb and its key ship now so the switch has "
                        + "something to switch; cross-pane execution does not."
                )
                : ControlError(
                    code: .disabled,
                    message: "run is switched off. Set `controlAllowRun` to true in "
                        + "~/.config/baia/config.json, and note that it is a different key from "
                        + "`controlChannelEnabled` on purpose: split hands a pane a shell it "
                        + "could already spawn, run hands it another pane's context."
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
            let permitted = subjects(actor).filter { subject in
                guard case .allowed = graph.authorize(
                    token: request.token,
                    verb: .list,
                    target: subject
                ) else { return false }
                return true
            }
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

    /// The caller, everything below it, and its peers.
    ///
    /// Walked from `children(of:)` rather than read from a children index,
    /// because the graph deliberately keeps only the parent edge: two indices are
    /// two things that can disagree, and this disagreement would widen a scope
    /// invisibly.
    private func scope(of actor: ControlPaneID) -> [ControlPaneID] {
        var seen: Set<ControlPaneID> = [actor]
        var frontier = [actor]
        var ordered = [actor]

        while let pane = frontier.popLast() {
            for child in graph.children(of: pane).sorted(by: { $0.description < $1.description }) {
                guard seen.insert(child).inserted else { continue }
                ordered.append(child)
                frontier.append(child)
            }
        }

        for peer in graph.peers(of: actor).sorted(by: { $0.description < $1.description }) {
            guard seen.insert(peer).inserted else { continue }
            ordered.append(peer)
        }

        return ordered
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
            wake(recipient)
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

    /// A long poll that found nothing, carrying the cancellable that answers it
    /// at its deadline.
    private typealias ParkedRecv = ParkedRecvs<DispatchWorkItem>.Waiter

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
                respond(answer(for: drain), to: id)
                return
            }
            park(id, pane: actor, token: request.token, seconds: seconds, kind: .recv)
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
                respond(answer(for: batch), to: id)
                return
            }
            park(
                id,
                pane: actor,
                token: request.token,
                seconds: seconds,
                kind: .subscribe(from: cursor, kinds: kinds)
            )
        }
    }

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
    private func park(
        _ id: Int,
        pane: ControlPaneID,
        token: String,
        seconds: Int,
        kind: ParkedKind
    ) {
        guard connections[id] != nil else { return }

        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.resolveByDraining(id)
            }
        }

        let waiter = ParkedRecv(pane: pane, token: token, deadline: deadline, kind: kind)
        switch waiters.park(id, waiter) {
        case .alreadyParked:
            // Never submitted, so cancelling is bookkeeping rather than a race:
            // it says out loud that this deadline will not be resolving anybody.
            deadline.cancel()
            respond(
                .failure(
                    .refused,
                    "this connection is already waiting. One long poll per connection: "
                        + "let this one answer, or send the next on its own connection."
                ),
                to: id
            )
            return

        case .parked:
            // Capped at sixty by `wait(from:)`, which is where the cap belongs:
            // an uncapped long poll is a pool slot held forever by whoever asks
            // for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: deadline)
        }
    }

    /// Wakes every parked `recv` on a pane, for a message that just landed.
    ///
    /// Subscribers are woken by ``wakeSubscribers()`` instead: a mailbox delivery
    /// is addressed at one pane, and an event is not addressed at all.
    private func wake(_ pane: ControlPaneID) {
        for id in waiters.ids(of: pane) where waiters[id]?.kind == .recv {
            resolveByDraining(id)
        }
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
    private func wakeSubscribers() {
        for id in waiters.ids {
            guard let waiter = waiters[id] else { continue }
            guard case let .subscribe(from, kinds) = waiter.kind else { continue }
            switch graph.subscribe(token: waiter.token, from: from, kinds: kinds) {
            case .denied:
                // Its token went bad while parked. Resolved through the same path
                // a live one takes, so the client is told rather than left to time
                // out against a capability that no longer exists.
                resolveByReading(id)
            case let .ok(batch):
                guard batch.events.isEmpty == false else { continue }
                resolveByReading(id)
            }
        }
    }

    /// Answers a parked `recv` with whatever is in the mailbox now.
    ///
    /// Goes back through `recv(token:)`, so the wait is authorised on the way out
    /// exactly as it was on the way in. A pane that lost its capability while
    /// parked gets the honest answer rather than a drain nobody checked.
    private func resolveByDraining(_ id: Int) {
        // The deadline installed by `park` calls this for either sort, so a
        // subscriber's timeout is handed to the reader rather than draining a
        // mailbox it never asked about.
        guard waiters[id]?.kind == .recv else {
            resolveByReading(id)
            return
        }
        guard let waiter = waiters.remove(id) else { return }
        waiter.deadline.cancel()

        // **The idle clock restarts when the long poll is answered, not when it
        // was parked.** `received` stamped it when the `recv` frame arrived, and
        // the waiter was exempt from the sweep only while it was in `waiters`, so
        // a `recv --wait 60` answered at t=60 would look sixty seconds stale to
        // the very next five second tick and be sent an unsolicited `refused` and
        // closed within five seconds of a successful answer. This connection did
        // not sit thirty seconds without completing a request; it completed one.
        connections[id]?.lastRequest = Date()

        switch graph.recv(token: waiter.token) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .ok(drain):
            respond(answer(for: drain), to: id)
        }
    }

    /// Answers a parked `subscribe` with whatever the ring holds now.
    ///
    /// Goes back through `graph.subscribe`, so the wait is authorised on the way
    /// out exactly as it was on the way in, matching ``resolveByDraining(_:)``.
    private func resolveByReading(_ id: Int) {
        guard let waiter = waiters.remove(id) else { return }
        waiter.deadline.cancel()
        guard case let .subscribe(from, kinds) = waiter.kind else { return }

        // The idle clock restarts when the long poll is answered, for
        // ``resolveByDraining(_:)``'s reason: this connection did not sit thirty
        // seconds without completing a request, it completed one.
        connections[id]?.lastRequest = Date()

        switch graph.subscribe(token: waiter.token, from: from, kinds: kinds) {
        case let .denied(error):
            respond(ControlResponse.failure(error), to: id)
        case let .ok(batch):
            respond(answer(for: batch), to: id)
        }
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
    private func resolveEmpty(_ id: Int) {
        guard let waiter = waiters.remove(id) else { return }
        waiter.deadline.cancel()
        // No idle stamp on the way out, unlike ``resolveByDraining(_:)``: the
        // connection leaves the pool on the next line, so there is no clock left
        // for the sweep to read and writing one would be a value deleted by the
        // statement under it.
        connections[id] = nil

        switch waiter.kind {
        case .recv:
            respond(answer(for: Drain.empty), to: id, thenClose: true)
        case .subscribe:
            // At the current head, not at the waiter's cursor: the caller is being
            // told "nothing more from me", and handing back a stale cursor would
            // make its next call re-read whatever landed while it waited.
            respond(
                answer(for: EventBatch.empty(at: graph.currentSequence)),
                to: id,
                thenClose: true
            )
        }
    }

    private func answer(for drain: Drain) -> ControlResponse {
        .success(ControlResult(messages: drain.messages, more: drain.more, dropped: drain.dropped))
    }

    private func answer(for batch: EventBatch) -> ControlResponse {
        .success(ControlResult(
            more: batch.more, events: batch.events, gap: batch.gap, seq: batch.seq
        ))
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
