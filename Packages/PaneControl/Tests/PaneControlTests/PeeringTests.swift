import Foundation
import Testing

@testable import PaneControl

/// Publishing, connecting, rotating, and the one invariant the whole two-secret
/// design exists to hold: after `revoke B`, B cannot re-establish with the ticket
/// it still holds.
@Suite struct PeeringTests {
    /// Three live panes and their capabilities, since every peering verb starts
    /// from a token and not from a pane.
    struct Fixture {
        /// A stand-in for what `SecRandomCopyBytes` produces. Deliberately not
        /// UUID-shaped: the registry refuses a secret that parses as a pane id,
        /// which is `PaneGraphTests`' subject and this suite's assumption.
        static func capability(_ label: String) -> String { "b7-not-a-uuid-\(label)" }

        var graph = PaneGraph()
        let publisher = ControlPaneID(rawValue: UUID())
        let peer = ControlPaneID(rawValue: UUID())
        let other = ControlPaneID(rawValue: UUID())

        let publisherToken = Fixture.capability("publisher")
        let peerToken = Fixture.capability("peer")
        let otherToken = Fixture.capability("other")

        init() {
            graph.open(pane: publisher, createdBy: nil, secret: PaneSecret(publisherToken))
            graph.open(pane: peer, createdBy: nil, secret: PaneSecret(peerToken))
            graph.open(pane: other, createdBy: nil, secret: PaneSecret(otherToken))
        }

        /// Publishes and hands back the ticket, recording an issue rather than
        /// returning an optional every caller would then have to unwrap.
        mutating func publish(name: String? = nil, minting ticket: String) -> String {
            switch graph.publish(
                token: publisherToken,
                name: name,
                ticket: RendezvousToken(ticket)
            ) {
            case let .ok(publication):
                return publication.rendezvous.rawValue
            case let .denied(error):
                Issue.record("publish was denied: \(error.message)")
                return ""
            }
        }

        mutating func rotate(name: String? = nil, minting ticket: String) -> String {
            switch graph.rotate(
                token: publisherToken,
                name: name,
                ticket: RendezvousToken(ticket)
            ) {
            case let .ok(publication):
                return publication.rendezvous.rawValue
            case let .denied(error):
                Issue.record("rotate was denied: \(error.message)")
                return ""
            }
        }

        /// The identity minted for one admission, which is what `revoke` deletes
        /// and what a replayed ticket must not be able to mint a second one of.
        func edgeSecret(name: String, admitting pane: ControlPaneID) -> EdgeSecret? {
            graph.channels[ChannelKey(owner: publisher, name: name)]?.admitted[pane]
        }
    }

    // MARK: Publishing

    /// A pane that publishes on every start keeps handing out the ticket it
    /// already gave away, rather than orphaning it and silently breaking every
    /// peer that holds it.
    @Test func publishIsIdempotentPerNameAndKeepsHandingBackTheSameTicket() {
        var fixture = Fixture()
        let first = fixture.publish(minting: "ticket-one")

        switch fixture.graph.publish(
            token: fixture.publisherToken,
            name: nil,
            ticket: RendezvousToken("ticket-two")
        ) {
        case let .ok(publication):
            #expect(publication.rendezvous.rawValue == first)
            #expect(publication.minted == false)
            #expect(publication.name == ControlWire.defaultChannelName)
        case let .denied(error):
            Issue.record("a republish was denied: \(error.message)")
        }

        // The ticket offered and not used is recorded nowhere, so it admits
        // nobody.
        #expect(fixture.graph.ticketIsInUse(RendezvousToken("ticket-two")) == false)
        #expect(fixture.graph.publishedNames(of: fixture.publisher) == ["default"])
    }

    @Test func eachPublishedNameCarriesItsOwnTicket() {
        var fixture = Fixture()
        let work = fixture.publish(name: "work", minting: "ticket-work")
        let logs = fixture.publish(name: "logs", minting: "ticket-logs")

        #expect(work != logs)
        #expect(fixture.graph.publishedNames(of: fixture.publisher) == ["logs", "work"])
    }

    /// The cardinal rule one layer out. A ticket that was a pane id would let any
    /// process that read `session.json` into any channel in the workspace, so the
    /// value is refused where a ticket is recorded and refused again where one is
    /// presented.
    @Test func aTicketThatIsAPaneIDIsRefusedOnTheWayInAndOnTheWayBack() {
        var fixture = Fixture()
        let idShaped = fixture.peer.description

        switch fixture.graph.publish(
            token: fixture.publisherToken,
            name: "work",
            ticket: RendezvousToken(idShaped)
        ) {
        case .ok:
            Issue.record("a pane id was accepted as a rendezvous ticket")
        case let .denied(error):
            #expect(error.code == .internal)
        }
        #expect(fixture.graph.publishedNames(of: fixture.publisher).isEmpty)

        // And presented, against a channel table with one real channel in it.
        _ = fixture.publish(name: "work", minting: "ticket-work")
        #expect(fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: idShaped,
            edgeSecret: EdgeSecret("edge-one")
        ) == .denied(.unknownTicket))
        #expect(fixture.graph.peers(of: fixture.publisher).isEmpty)
    }

    @Test func aChannelNameThatIsEmptyOrOverTheCapIsRefused() {
        var fixture = Fixture()

        for name in ["", String(repeating: "n", count: ControlWire.maxChannelNameBytes + 1)] {
            switch fixture.graph.publish(
                token: fixture.publisherToken,
                name: name,
                ticket: RendezvousToken("ticket-\(name.count)")
            ) {
            case .ok:
                Issue.record("a channel name of \(name.count) bytes was accepted")
            case let .denied(error):
                #expect(error.code == .refused)
            }
        }
        #expect(fixture.graph.publishedNames(of: fixture.publisher).isEmpty)
    }

    /// A pane that keeps inventing names keeps adding entries in the app process,
    /// and the entries hold tickets. Rotating or reusing a name is what a
    /// publisher actually wants.
    @Test func aPaneCannotHoldMoreChannelsThanTheCap() {
        var fixture = Fixture()
        for index in 0 ..< ControlWire.maxPublishedChannelsPerPane {
            _ = fixture.publish(name: "channel-\(index)", minting: "ticket-\(index)")
        }
        #expect(
            fixture.graph.publishedNames(of: fixture.publisher).count
                == ControlWire.maxPublishedChannelsPerPane
        )

        switch fixture.graph.publish(
            token: fixture.publisherToken,
            name: "one-too-many",
            ticket: RendezvousToken("ticket-one-too-many")
        ) {
        case .ok:
            Issue.record("the channel cap did not hold")
        case let .denied(error):
            #expect(error.code == .refused)
        }
    }

    /// Publishing is a verb like any other and it needs the capability. The pane
    /// id every read verb traffics in is not one.
    @Test func publishNeedsACapabilityAndAPaneIDIsNotOne() {
        var fixture = Fixture()
        #expect(fixture.graph.publish(
            token: fixture.publisher.description,
            name: "work",
            ticket: RendezvousToken("ticket-work")
        ) == .denied(.badToken))
        #expect(fixture.graph.publishedNames(of: fixture.publisher).isEmpty)
    }

    // MARK: Connecting

    @Test func connectEstablishesAnEdgeVisibleFromBothEnds() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")

        switch fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        ) {
        case let .ok(connection):
            #expect(connection.peer == fixture.publisher)
            #expect(connection.name == "work")
        case let .denied(error):
            Issue.record("connect was denied: \(error.message)")
        }

        #expect(fixture.graph.peers(of: fixture.publisher) == [fixture.peer])
        #expect(fixture.graph.peers(of: fixture.peer) == [fixture.publisher])
        #expect(fixture.edgeSecret(name: "work", admitting: fixture.peer) == EdgeSecret("edge-one"))
    }

    /// One ticket admits several panes, which is why revoking one of them cannot
    /// be done by invalidating the ticket.
    @Test func oneTicketAdmitsEveryPaneItIsHandedTo() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")

        for (capability, edge) in [
            (fixture.peerToken, "edge-one"),
            (fixture.otherToken, "edge-two"),
        ] {
            switch fixture.graph.connect(
                token: capability,
                rendezvous: ticket,
                edgeSecret: EdgeSecret(edge)
            ) {
            case .ok: break
            case let .denied(error): Issue.record("connect was denied: \(error.message)")
            }
        }

        #expect(fixture.graph.peers(of: fixture.publisher) == [fixture.peer, fixture.other])
    }

    /// The ticket buys admission, and buys nothing about an edge that already
    /// exists. A second redemption mints no second identity and resets nothing,
    /// which is what "not replayable into an established edge" comes to in state.
    @Test func aTicketRedeemedTwiceMintsNoSecondEdgeIdentity() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        )

        let replay = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-two")
        )
        #expect(replay == .ok(Connection(peer: fixture.publisher, name: "work")))
        #expect(fixture.edgeSecret(name: "work", admitting: fixture.peer) == EdgeSecret("edge-one"))
        #expect(fixture.graph.peers(of: fixture.publisher) == [fixture.peer])
    }

    @Test func aPaneCannotRedeemItsOwnTicket() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")

        #expect(fixture.graph.connect(
            token: fixture.publisherToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        ) == .denied(.selfPeering))
        #expect(fixture.graph.peers(of: fixture.publisher).isEmpty)
    }

    @Test func connectNeedsACapabilityAndAPaneIDIsNotOne() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")

        #expect(fixture.graph.connect(
            token: fixture.peer.description,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        ) == .denied(.badToken))
        #expect(fixture.graph.peers(of: fixture.publisher).isEmpty)
    }

    // MARK: Rotating

    @Test func rotateMintsAFreshTicketAndTheOldOneAdmitsNobodyNew() {
        var fixture = Fixture()
        let old = fixture.publish(name: "work", minting: "ticket-old")
        let new = fixture.rotate(name: "work", minting: "ticket-new")
        #expect(old != new)

        #expect(fixture.graph.connect(
            token: fixture.otherToken,
            rendezvous: old,
            edgeSecret: EdgeSecret("edge-old")
        ) == .denied(.unknownTicket))

        switch fixture.graph.connect(
            token: fixture.otherToken,
            rendezvous: new,
            edgeSecret: EdgeSecret("edge-new")
        ) {
        case .ok: break
        case let .denied(error): Issue.record("the fresh ticket was refused: \(error.message)")
        }
        #expect(fixture.graph.peers(of: fixture.publisher) == [fixture.other])
    }

    /// Rotation preserves the edges the old ticket admitted, which is exactly why
    /// it is no remedy for a peer that has to go: rotating to remove one pane
    /// would evict everybody who joined under that name and leave that pane's edge
    /// standing.
    @Test func rotatePreservesEveryEdgeThePreviousTicketAdmitted() {
        var fixture = Fixture()
        let old = fixture.publish(name: "work", minting: "ticket-old")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: old,
            edgeSecret: EdgeSecret("edge-one")
        )

        _ = fixture.rotate(name: "work", minting: "ticket-new")

        #expect(fixture.graph.peers(of: fixture.publisher) == [fixture.peer])
        #expect(fixture.edgeSecret(name: "work", admitting: fixture.peer) == EdgeSecret("edge-one"))
    }

    /// `baia publish --as NAME --rotate` on a name that was never published is a
    /// publish. A `notFound` would be a distinction with nothing behind it: the
    /// caller wanted a current ticket for that name and now has one.
    @Test func rotatingANameThatWasNeverPublishedPublishesIt() {
        var fixture = Fixture()
        let ticket = fixture.rotate(name: "work", minting: "ticket-work")
        #expect(ticket == "ticket-work")
        #expect(fixture.graph.publishedNames(of: fixture.publisher) == ["work"])
    }

    // MARK: Revoking, and the invariant

    /// **The invariant.** After `revoke B`, B cannot re-establish without a fresh
    /// grant.
    ///
    /// B still holds the ticket it was admitted with: tickets are handed out, not
    /// taken back, and `publish` is idempotent per name so the publisher cannot
    /// invalidate one without evicting everybody who joined under it. A `revoke`
    /// that only dropped the edge would therefore be cosmetic, undone by B
    /// reconnecting a second later while the owner read the confirmation.
    ///
    /// This test is written to fail against exactly that implementation: delete
    /// the denial and keep the edge removal, and the replay below succeeds.
    @Test func aRevokedPeerCannotReEstablishWithTheTicketItStillHolds() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        )
        #expect(fixture.graph.peers(of: fixture.publisher) == [fixture.peer])

        #expect(fixture.graph.revoke(token: fixture.publisherToken, peer: fixture.peer.description)
            == .ok(fixture.peer))
        #expect(fixture.graph.peers(of: fixture.publisher).isEmpty)
        #expect(fixture.graph.peers(of: fixture.peer).isEmpty)
        #expect(fixture.edgeSecret(name: "work", admitting: fixture.peer) == nil)

        // The replay, with the ticket B never gave back.
        #expect(fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-two")
        ) == .denied(.unknownTicket))
        #expect(fixture.graph.peers(of: fixture.publisher).isEmpty)
        #expect(fixture.graph.peers(of: fixture.peer).isEmpty)
    }

    /// A publisher that says "this pane is out" and finds it back in through a
    /// second name it also handed over has not revoked anything, so the denial
    /// covers every channel the revoker owns rather than the one the peer came in
    /// through.
    @Test func revokeCoversEveryChannelThePublisherOwnsAndNotOnlyTheOneUsed() {
        var fixture = Fixture()
        let work = fixture.publish(name: "work", minting: "ticket-work")
        let logs = fixture.publish(name: "logs", minting: "ticket-logs")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: work,
            edgeSecret: EdgeSecret("edge-one")
        )

        _ = fixture.graph.revoke(token: fixture.publisherToken, peer: fixture.peer.description)

        #expect(fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: logs,
            edgeSecret: EdgeSecret("edge-two")
        ) == .denied(.unknownTicket))
        #expect(fixture.graph.peers(of: fixture.publisher).isEmpty)
    }

    /// The denial is scoped to the ticket generation, so a publisher that changes
    /// its mind has a way back: rotate, and hand over the new ticket. Without
    /// this, `revoke` would be a permanent ban nobody asked for.
    @Test func aRotationIsTheFreshGrantThatLetsARevokedPeerBack() {
        var fixture = Fixture()
        let old = fixture.publish(name: "work", minting: "ticket-old")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: old,
            edgeSecret: EdgeSecret("edge-one")
        )
        _ = fixture.graph.revoke(token: fixture.publisherToken, peer: fixture.peer.description)

        let new = fixture.rotate(name: "work", minting: "ticket-new")
        switch fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: new,
            edgeSecret: EdgeSecret("edge-two")
        ) {
        case .ok: break
        case let .denied(error): Issue.record("a fresh grant was refused: \(error.message)")
        }

        #expect(fixture.graph.peers(of: fixture.publisher) == [fixture.peer])
        // A new admission, not the resurrected one.
        #expect(fixture.edgeSecret(name: "work", admitting: fixture.peer) == EdgeSecret("edge-two"))
    }

    /// Revoking a stranger, a pane that does not exist, and a string that is not
    /// an id at all are one answer: all three are targets the caller has no edge
    /// to, and a caller able to tell them apart could walk id space.
    @Test func revokingAPaneThatIsNotAPeerIsUnauthorized() {
        var fixture = Fixture()

        let refusal = ControlError.unauthorized(ControlVerb.revoke.scope)

        #expect(fixture.graph.revoke(token: fixture.publisherToken, peer: fixture.other.description)
            == .denied(refusal))
        #expect(fixture.graph.revoke(
            token: fixture.publisherToken,
            peer: UUID().uuidString
        ) == .denied(refusal))
        #expect(fixture.graph.revoke(token: fixture.publisherToken, peer: "not-an-id")
            == .denied(refusal))
    }

    /// A revoked pane learns nothing a pane holding an invented ticket does not,
    /// because the publisher never agreed to tell it which of the two happened.
    @Test func aRevokedBearerAndAnInventedTicketGetTheSameAnswer() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        )
        _ = fixture.graph.revoke(token: fixture.publisherToken, peer: fixture.peer.description)

        let revoked = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-two")
        )
        let invented = fixture.graph.connect(
            token: fixture.otherToken,
            rendezvous: "a-ticket-nobody-minted",
            edgeSecret: EdgeSecret("edge-three")
        )
        #expect(revoked == invented)
    }

    // MARK: Lifetime

    /// A channel that outlived its pane would be a ticket admitting callers to an
    /// edge with nobody on the other end.
    @Test func closingThePublisherRetiresItsChannelsAndItsTicketsWithThem() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        )

        fixture.graph.close(pane: fixture.publisher)

        #expect(fixture.graph.publishedNames(of: fixture.publisher).isEmpty)
        #expect(fixture.graph.channels.isEmpty)
        #expect(fixture.graph.peers(of: fixture.peer).isEmpty)
        #expect(fixture.graph.connect(
            token: fixture.otherToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-two")
        ) == .denied(.unknownTicket))
    }

    /// A closed pane's id is worth nothing to anybody, and a denial list that only
    /// grows is a leak with a slow fuse.
    @Test func closingAPeerLeavesNothingOfItInThePublishersChannel() {
        var fixture = Fixture()
        let ticket = fixture.publish(name: "work", minting: "ticket-work")
        _ = fixture.graph.connect(
            token: fixture.peerToken,
            rendezvous: ticket,
            edgeSecret: EdgeSecret("edge-one")
        )
        _ = fixture.graph.revoke(token: fixture.publisherToken, peer: fixture.peer.description)

        fixture.graph.close(pane: fixture.peer)

        let channel = fixture.graph.channels[ChannelKey(owner: fixture.publisher, name: "work")]
        #expect(channel?.admitted.isEmpty == true)
        #expect(channel?.revoked.isEmpty == true)
    }
}
