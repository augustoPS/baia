import Foundation

/// An admission ticket for a published channel: what `baia publish` prints and
/// `baia connect` reads from stdin.
///
/// **An admission ticket and not a capability.** It admits its bearer to a
/// communication edge with the pane that published it, and confers no authority
/// over that pane at all: a peer may be seen and messaged, and may not split,
/// close, resize, or run in the pane it peered with. That is why it is the one
/// secret-shaped value the wire carries, and the bound is what makes it safe.
///
/// Minted by the app rather than here, the way ``PaneSecret`` is, so this package
/// keeps importing Foundation and nothing else. ``PaneGraph`` is handed a fresh
/// one and decides whether it may be recorded.
///
/// Not `Codable`, so a response field of this type would not compile. The ticket
/// reaches the wire as a plain `String` in ``ControlResult/rendezvous``, which is
/// the single exception rule 2 allows, guarded by name in
/// `SecretContainmentTests`.
public struct RendezvousToken: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whether this ticket is a pane id wearing a ticket's name.
    ///
    /// The cardinal rule applied one layer out. A ticket that was a pane id
    /// would let any pane that read `session.json`, which is every process the
    /// user owns, connect to any published channel in the workspace, and the
    /// admission it bought would look exactly like an invited one. Refused where
    /// a ticket is recorded and refused again where one is presented, so the
    /// answer does not depend on the channel table being clean.
    var parsesAsPaneID: Bool { rawValue.parsesAsPaneID }

    public var description: String { "RendezvousToken(redacted)" }
    public var debugDescription: String { description }
}

/// The identity of one established peer edge, minted by `connect` and deleted by
/// `revoke`.
///
/// **Two secrets, not one, and this is the second.** The rendezvous ticket is
/// handed to several intended peers and `publish` is idempotent per name, so
/// invalidating the ticket one peer used would evict everyone who joined under
/// that name. The edge therefore has an identity of its own, minted when the
/// admission is granted, so that removing one peer is a thing that can be done
/// without touching the ticket or anybody else's edge.
///
/// Never presented by a client and never returned by any verb. It is the
/// server's record of which admission produced which edge, which is what makes a
/// replayed ticket unable to reset an edge that already exists: a second
/// `connect` on the same ticket finds the admission already recorded and mints
/// nothing.
///
/// Not `Codable`, for ``PaneSecret``'s reason.
public struct EdgeSecret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { "EdgeSecret(redacted)" }
    public var debugDescription: String { description }
}

/// What a peering verb answered.
///
/// A value with the denial inside it rather than a `throws`, for
/// ``ControlDecodeResult``'s reason: nothing in this package throws, so a failure
/// is a thing that gets encoded into a response rather than a control flow an
/// over-broad `catch` can swallow.
public enum ControlOutcome<Value: Sendable & Equatable>: Sendable, Equatable {
    case ok(Value)
    case denied(ControlError)
}

/// What `publish` and `publish --rotate` answer.
public struct Publication: Sendable, Equatable {
    /// The name the channel is published under, which is what a peer sees after
    /// `connect`.
    public var name: String

    /// The ticket to hand to intended peers.
    public var rendezvous: RendezvousToken

    /// Whether this call minted the ticket it is returning.
    ///
    /// False for a republish of a name that already exists, which is the
    /// idempotence the spec asks for: a script that publishes on every start
    /// keeps handing out the same ticket instead of orphaning the last one it
    /// gave away.
    public var minted: Bool
}

/// What `connect` answers: whom the caller is now peered with, and under which
/// name.
public struct Connection: Sendable, Equatable {
    public var peer: ControlPaneID
    public var name: String
}

/// One published name, its current ticket, and everything that ticket has
/// admitted or been refused for.
///
/// Keyed by owner and name together, so two panes may publish the same name
/// without colliding and one pane may publish several.
struct PublishedChannel: Sendable, Equatable {
    var owner: ControlPaneID
    var name: String

    /// The ticket that admits. Replaced by `rotate` and by nothing else.
    var ticket: RendezvousToken

    /// Who has been admitted under the current ticket, and the identity minted
    /// for each edge.
    var admitted: [ControlPaneID: EdgeSecret]

    /// Who this ticket will not admit again.
    ///
    /// **This is what makes `revoke` durable.** The revoked pane still holds the
    /// ticket it was let in with, and a `revoke` that only dropped the edge would
    /// be undone by that pane reconnecting a second later, with the owner
    /// believing the peer was gone. `--rotate` is no remedy on its own, since it
    /// preserves established edges by design.
    ///
    /// Scoped to the ticket generation and cleared by `rotate`, because a
    /// rotation is a fresh grant: the revoked pane does not hold the new ticket,
    /// so it is already excluded, and carrying the denial forward would mean a
    /// publisher could never re-admit a pane it once removed. That is an
    /// eviction this design does not claim to offer.
    var revoked: Set<ControlPaneID>
}

/// Owner and name together, since a name is only unique within the pane that
/// published it.
struct ChannelKey: Hashable, Sendable {
    let owner: ControlPaneID
    let name: String
}

extension PaneGraph {
    // MARK: Reading

    /// The names a pane has published, sorted, for the record `whoami` and `list`
    /// return.
    ///
    /// Names, never the tickets behind them. A ticket in a `list` would be a
    /// capability in a response body, which rule 2 forbids everywhere except the
    /// publisher's own `publish`.
    public func publishedNames(of pane: ControlPaneID) -> [String] {
        channels.values.filter { $0.owner == pane }.map(\.name).sorted()
    }

    // MARK: Publishing

    /// Mints a channel for the calling pane, or hands back the one it already
    /// has.
    ///
    /// `name` is nil when the caller ran `baia publish` with no `--as`, and the
    /// default lives here rather than in the CLI so that client and server cannot
    /// disagree about which channel a bare `publish` and a bare `connect` are
    /// talking about.
    ///
    /// `ticket` is minted by the app and offered rather than requested: this
    /// package holds no randomness, and a fresh ticket that turns out not to be
    /// needed is discarded by the idempotent path below.
    public mutating func publish(
        token: String,
        name: String?,
        ticket: RendezvousToken
    ) -> ControlOutcome<Publication> {
        switch authorize(token: token, verb: .publish, target: nil) {
        case let .denied(error):
            return .denied(error)
        case let .allowed(actor, _):
            return publish(pane: actor, name: name ?? ControlWire.defaultChannelName, ticket: ticket)
        }
    }

    /// Replaces a channel's ticket, keeping every edge it has already admitted.
    ///
    /// The old ticket then admits nobody: it matches no channel, so a pane
    /// holding it is refused exactly as a pane holding an invented one is.
    ///
    /// Rotating a name that was never published publishes it, because that is
    /// what `baia publish --as NAME --rotate` reads as to the person typing it. A
    /// `notFound` here would be a distinction with nothing behind it: the caller
    /// wanted a current ticket for that name and now has one.
    public mutating func rotate(
        token: String,
        name: String?,
        ticket: RendezvousToken
    ) -> ControlOutcome<Publication> {
        switch authorize(token: token, verb: .publish, target: nil) {
        case let .denied(error):
            return .denied(error)
        case let .allowed(actor, _):
            return rotate(pane: actor, name: name ?? ControlWire.defaultChannelName, ticket: ticket)
        }
    }

    // MARK: Connecting

    /// Redeems a ticket for a peer edge.
    ///
    /// The ticket arrives as the raw string the frame carried, deliberately, for
    /// ``authorize(token:verb:target:)``'s reason: this is the boundary where an
    /// untrusted string either becomes an admission or does not, and building the
    /// ticket somewhere else would move the first half of that decision out of
    /// the one place with a test on it.
    ///
    /// Every refusal answers `unauthorized` with one message. Telling an unknown
    /// ticket apart from a rotated one, or either from a revoked bearer, would
    /// hand a caller an oracle over channels it was never admitted to.
    public mutating func connect(
        token: String,
        rendezvous: String,
        edgeSecret: EdgeSecret
    ) -> ControlOutcome<Connection> {
        switch authorize(token: token, verb: .connect, target: nil) {
        case let .denied(error):
            return .denied(error)
        case let .allowed(actor, _):
            return connect(actor: actor, ticket: RendezvousToken(rendezvous), edgeSecret: edgeSecret)
        }
    }

    // MARK: Revoking

    /// Removes a peer, durably.
    ///
    /// The peer is named by its display pane id, off the wire. A string that is
    /// not a pane id at all is `unauthorized` like every other target the caller
    /// has no edge to: a caller that could tell a malformed id from a live
    /// non-peer could walk id space.
    public mutating func revoke(token: String, peer: String) -> ControlOutcome<ControlPaneID> {
        guard let target = ControlPaneID(uuidString: peer) else { return .denied(.unauthorized) }

        switch authorize(token: token, verb: .revoke, target: target) {
        case let .denied(error):
            return .denied(error)
        case let .allowed(actor, subject):
            revoke(pane: actor, peer: subject)
            return .ok(subject)
        }
    }

    // MARK: The state machine underneath
    //
    // Internal, and not by accident. These take resolved panes and perform no
    // authorization whatsoever, so a request must come through one of the
    // token-taking entry points above to reach them. Rule 3 is that
    // `authorize` is the only function answering whether an actor may touch a
    // target, and the way to keep that true is to leave no public door that
    // skips it.

    mutating func publish(
        pane: ControlPaneID,
        name: String,
        ticket: RendezvousToken
    ) -> ControlOutcome<Publication> {
        let key = ChannelKey(owner: pane, name: name)

        // Idempotent per name. Minting a second ticket for a name already
        // published would orphan the one the pane has already handed out, and a
        // publisher that has to remember whether it published is a publisher
        // that will re-publish on restart and silently break its peers.
        if let existing = channels[key] {
            return .ok(Publication(name: name, rendezvous: existing.ticket, minted: false))
        }

        if let refusal = refusalForNewChannel(pane: pane, name: name, ticket: ticket) {
            return .denied(refusal)
        }

        channels[key] = PublishedChannel(
            owner: pane,
            name: name,
            ticket: ticket,
            admitted: [:],
            revoked: []
        )
        return .ok(Publication(name: name, rendezvous: ticket, minted: true))
    }

    mutating func rotate(
        pane: ControlPaneID,
        name: String,
        ticket: RendezvousToken
    ) -> ControlOutcome<Publication> {
        let key = ChannelKey(owner: pane, name: name)

        guard var channel = channels[key] else {
            return publish(pane: pane, name: name, ticket: ticket)
        }

        guard ticket.parsesAsPaneID == false, ticketIsInUse(ticket) == false else {
            return .denied(.mintCollision)
        }

        channel.ticket = ticket
        // Established edges survive a rotation, which is the whole difference
        // between rotating and revoking. The denial list does not, because it
        // exists to make a ticket its holder already has useless, and this is a
        // ticket nobody holds yet.
        channel.revoked = []
        channels[key] = channel
        return .ok(Publication(name: name, rendezvous: ticket, minted: true))
    }

    mutating func connect(
        actor: ControlPaneID,
        ticket: RendezvousToken,
        edgeSecret: EdgeSecret
    ) -> ControlOutcome<Connection> {
        // Refused before the channel table is consulted at all, so the answer
        // never depends on the table being clean, exactly as
        // `authorize` refuses a pane-id-shaped token before the registry.
        guard ticket.parsesAsPaneID == false else { return .denied(.unknownTicket) }

        guard let key = channels.first(where: { $0.value.ticket == ticket })?.key,
              var channel = channels[key]
        else { return .denied(.unknownTicket) }

        // A pane peering with itself would be an edge whose two ends are one
        // pane, which `addPeerEdge` refuses anyway. Answering `refused` rather
        // than letting that silently return false tells the caller its own
        // ticket came back to it, which is a script bug and not a denial.
        guard channel.owner != actor else { return .denied(.selfPeering) }

        // The revoked bearer's answer is byte-identical to an unknown ticket's.
        // A message saying "you were revoked" would tell a pane the publisher
        // chose not to tell it anything at all.
        guard channel.revoked.contains(actor) == false else { return .denied(.unknownTicket) }

        // Unreachable while `close` retires a pane's channels with it, and
        // checked anyway: an edge to a pane with no capability is an edge
        // nothing can ever use, and admitting one would be a peer count that
        // lies.
        guard isOpen(channel.owner) else { return .denied(.unknownTicket) }

        // A replay while the edge stands buys the admission it already has and
        // nothing else: no second secret, no reset, no change. This is what
        // "the ticket is not replayable into an established edge" comes to in
        // state, and it is why the edge has an identity separate from the
        // ticket that produced it.
        if channel.admitted[actor] != nil {
            return .ok(Connection(peer: channel.owner, name: channel.name))
        }

        channel.admitted[actor] = edgeSecret
        channels[key] = channel
        addPeerEdge(between: channel.owner, and: actor)
        return .ok(Connection(peer: channel.owner, name: channel.name))
    }

    /// Deletes the edge and refuses the ticket that made it.
    ///
    /// Both halves are the operation. Dropping the edge alone is the defect this
    /// design exists to prevent: the revoked pane replays the ticket it still
    /// holds and is back before the owner has finished reading the confirmation.
    ///
    /// The denial covers every channel the revoker owns rather than only the one
    /// the peer came in through. A publisher that says "this pane is out" and
    /// finds it back in through a second name it also handed over has not
    /// revoked anything.
    ///
    /// The admission records held by the *peer's* channels go too, since the edge
    /// they recorded no longer exists. That is bookkeeping and not a denial: the
    /// revoker may still connect back with a ticket of the peer's it happens to
    /// hold, which is the revoker's own choice to make.
    @discardableResult
    mutating func revoke(pane: ControlPaneID, peer: ControlPaneID) -> Bool {
        var changed = removePeerEdge(between: pane, and: peer)

        for (key, channel) in channels where channel.owner == pane {
            var updated = channel
            if updated.admitted.removeValue(forKey: peer) != nil { changed = true }
            if updated.revoked.insert(peer).inserted { changed = true }
            channels[key] = updated
        }

        for (key, channel) in channels where channel.owner == peer {
            var updated = channel
            if updated.admitted.removeValue(forKey: pane) != nil {
                changed = true
                channels[key] = updated
            }
        }

        return changed
    }

    /// Everything a closing pane leaves behind in the peering tables.
    ///
    /// Called by ``close(pane:)`` rather than being one more thing the app has to
    /// remember: a pane whose channels outlived it would leave a ticket admitting
    /// callers to an edge with nobody on the other end.
    mutating func retirePeering(of pane: ControlPaneID) -> Bool {
        var changed = false

        for (key, channel) in channels where channel.owner == pane {
            channels[key] = nil
            changed = true
        }

        // The closed pane's id is worth nothing to anyone now, and a denial list
        // that only grows is a leak with a slow fuse.
        for (key, channel) in channels {
            var updated = channel
            var touched = false
            if updated.admitted.removeValue(forKey: pane) != nil { touched = true }
            if updated.revoked.remove(pane) != nil { touched = true }
            if touched {
                channels[key] = updated
                changed = true
            }
        }

        return changed
    }

    // MARK: Guards

    /// Whether a ticket is already recorded anywhere.
    ///
    /// Scanned rather than indexed, for the reason ``parentOf`` has no children
    /// index: a second table is a second thing that can disagree with the first,
    /// and a stale entry here would either refuse a good ticket or, worse, let
    /// two channels share one.
    func ticketIsInUse(_ ticket: RendezvousToken) -> Bool {
        channels.values.contains { $0.ticket == ticket }
    }

    /// Why a new channel may not be recorded, or nil when it may.
    private func refusalForNewChannel(
        pane: ControlPaneID,
        name: String,
        ticket: RendezvousToken
    ) -> ControlError? {
        if ticket.parsesAsPaneID || ticketIsInUse(ticket) {
            // Unreachable for any ticket the app mints, and answered rather than
            // ignored because the alternative is recording a channel whose
            // ticket admits the wrong pane.
            return .mintCollision
        }

        if name.isEmpty {
            return .channelNameRefused("a channel name cannot be empty")
        }

        // A name is echoed into the record `list` returns for this pane, and a
        // peer's `list` carries this pane's record. So an unbounded name is not
        // self-harm: it is a pane making its peers' responses unframeable, which
        // is the cross-pane effect every budget in the table exists to stop.
        if name.utf8.count > ControlWire.maxChannelNameBytes {
            return .channelNameRefused(
                "a channel name is capped at \(ControlWire.maxChannelNameBytes) bytes and that "
                    + "one is \(name.utf8.count)"
            )
        }

        if publishedNames(of: pane).count >= ControlWire.maxPublishedChannelsPerPane {
            return .channelNameRefused(
                "a pane may publish \(ControlWire.maxPublishedChannelsPerPane) channels at once. "
                    + "Rotate or reuse a name instead of minting another."
            )
        }

        return nil
    }
}
