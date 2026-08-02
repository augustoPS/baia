import Foundation
import Testing

@testable import PaneControl

/// The authorization matrix: every verb crossed with every relationship a caller
/// can stand in to a target, asserted against a table nobody can extend by
/// accident.
///
/// The table is walked from ``ControlVerb/allCases`` and a verb with no row is a
/// recorded failure rather than a skipped iteration. A new verb therefore fails
/// to compile first, in ``ControlVerb/scope``, which has no `default:`, and fails
/// here second once somebody has given it a scope. Both gates exist because the
/// compile failure only asks for *a* scope and this asks whether the scope is the
/// one the author meant.
@Suite struct AuthorizationMatrixTests {
    // MARK: The situations

    /// Where the caller stands relative to what it named.
    ///
    /// The last three are token-level rather than target-level, and they are in
    /// the same enum on purpose: the matrix asserts that `badToken` beats every
    /// scope, for read verbs exactly as for write verbs, which is the claim the
    /// whole design rests on.
    enum Situation: CaseIterable, CustomStringConvertible {
        /// The caller, named by omission. Every v1 layout verb sends this.
        case caller
        /// The caller, named explicitly. A verb that takes no target must not
        /// start accepting one just because it points at the right pane.
        case callerNamedExplicitly
        case child
        case grandchild
        /// A child addressing the other child of its own parent.
        case sibling
        /// A child addressing its parent. Authority runs downwards only.
        case parent
        case unrelated
        case peer
        /// A peer whose edge was revoked. The revocation has to bite here, or
        /// `revoke` is cosmetic.
        case revokedPeer
        /// A target that was open and is not any more.
        case closedPaneAsTarget
        /// The capability of a pane that has since closed.
        case closedPaneAsCredential
        case unknownCredential
        /// **The row this suite exists for.** A well-formed, currently live pane
        /// id, offered where a per-run secret belongs.
        case paneIDAsCredential

        var description: String { "\(self)" }
    }

    /// What `authorize` is expected to answer, flattened so a table can hold it.
    enum Outcome: Equatable, CustomStringConvertible {
        case allowed
        case denied(ControlErrorCode)

        var description: String {
            switch self {
            case .allowed: "allowed"
            case let .denied(code): "denied(\(code.rawValue))"
            }
        }
    }

    // MARK: The fixture

    /// A hand-built graph, with no `Workspace` anywhere near it. `PaneGraph`
    /// answers "may this actor do this" and not "what does the layout look
    /// like", and this suite is what that separation buys.
    struct Fixture {
        let graph: PaneGraph
        let root: ControlPaneID
        let child: ControlPaneID
        let grandchild: ControlPaneID
        let sibling: ControlPaneID
        let unrelated: ControlPaneID
        let peer: ControlPaneID
        let revoked: ControlPaneID
        let closed: ControlPaneID

        /// Stands in for the base64url of 32 random bytes. What matters about it
        /// is only that it is not a UUID.
        static func capability(_ label: String) -> PaneSecret { PaneSecret("capability-of-\(label)") }

        init() {
            var graph = PaneGraph()
            let root = ControlPaneID(rawValue: UUID())
            let child = ControlPaneID(rawValue: UUID())
            let grandchild = ControlPaneID(rawValue: UUID())
            let sibling = ControlPaneID(rawValue: UUID())
            let unrelated = ControlPaneID(rawValue: UUID())
            let peer = ControlPaneID(rawValue: UUID())
            let revoked = ControlPaneID(rawValue: UUID())
            let closed = ControlPaneID(rawValue: UUID())

            graph.open(pane: root, createdBy: nil, secret: Self.capability("root"))
            graph.open(pane: child, createdBy: root, secret: Self.capability("child"))
            graph.open(pane: grandchild, createdBy: child, secret: Self.capability("grandchild"))
            graph.open(pane: sibling, createdBy: root, secret: Self.capability("sibling"))
            graph.open(pane: unrelated, createdBy: nil, secret: Self.capability("unrelated"))
            graph.open(pane: peer, createdBy: nil, secret: Self.capability("peer"))
            graph.open(pane: revoked, createdBy: nil, secret: Self.capability("revoked"))
            graph.open(pane: closed, createdBy: nil, secret: Self.capability("closed"))

            graph.addPeerEdge(between: root, and: peer)
            graph.addPeerEdge(between: root, and: revoked)
            graph.removePeerEdge(between: root, and: revoked)
            graph.close(pane: closed)

            self.graph = graph
            self.root = root
            self.child = child
            self.grandchild = grandchild
            self.sibling = sibling
            self.unrelated = unrelated
            self.peer = peer
            self.revoked = revoked
            self.closed = closed
        }

        /// What one situation sends over the wire.
        ///
        /// The caller is `root` throughout except for ``Situation/sibling`` and
        /// ``Situation/parent``, which are asked from `child` because they only
        /// exist one level down.
        func probe(for situation: Situation) -> (sent: String, target: ControlPaneID?) {
            switch situation {
            case .caller: (Self.capability("root").rawValue, nil)
            case .callerNamedExplicitly: (Self.capability("root").rawValue, root)
            case .child: (Self.capability("root").rawValue, child)
            case .grandchild: (Self.capability("root").rawValue, grandchild)
            case .sibling: (Self.capability("child").rawValue, sibling)
            case .parent: (Self.capability("child").rawValue, root)
            case .unrelated: (Self.capability("root").rawValue, unrelated)
            case .peer: (Self.capability("root").rawValue, peer)
            case .revokedPeer: (Self.capability("root").rawValue, revoked)
            case .closedPaneAsTarget: (Self.capability("root").rawValue, closed)
            case .closedPaneAsCredential: (Self.capability("closed").rawValue, nil)
            case .unknownCredential: (PaneSecret("issued-to-nobody").rawValue, nil)
            // The live id of the pane whose capability this stands in for, which
            // is the strongest form of the attack: everything about it is
            // correct except that it is public.
            case .paneIDAsCredential: (root.description, nil)
            }
        }
    }

    // MARK: The rows

    /// What a credential buys before scope is consulted at all. Shared by every
    /// row because it is true of every verb: authentication is answered first and
    /// no scope can widen it.
    static let credentialDenials: [Situation: Outcome] = [
        .closedPaneAsCredential: .denied(.badToken),
        .unknownCredential: .denied(.badToken),
        .paneIDAsCredential: .denied(.badToken),
    ]

    /// Verbs that act on the calling pane and take no target. A named target
    /// that is not the caller is refused rather than ignored.
    static let selfOnlyRow: [Situation: Outcome] = credentialDenials.merging([
        .caller: .allowed,
        .callerNamedExplicitly: .allowed,
        .child: .denied(.unauthorized),
        .grandchild: .denied(.unauthorized),
        .sibling: .denied(.unauthorized),
        .parent: .denied(.unauthorized),
        .unrelated: .denied(.unauthorized),
        .peer: .denied(.unauthorized),
        .revokedPeer: .denied(.unauthorized),
        .closedPaneAsTarget: .denied(.unauthorized),
    ]) { current, _ in current }

    /// `list`. Reads are scoped exactly like writes: the caller, its
    /// descendants, and its peers, and nothing else. This row is the one that
    /// fails by over-succeeding, which is why every negative entry in it is
    /// spelled out rather than left to a default.
    static let scopedReadRow: [Situation: Outcome] = credentialDenials.merging([
        .caller: .allowed,
        .callerNamedExplicitly: .allowed,
        .child: .allowed,
        .grandchild: .allowed,
        .sibling: .denied(.unauthorized),
        .parent: .denied(.unauthorized),
        .unrelated: .denied(.unauthorized),
        .peer: .allowed,
        .revokedPeer: .denied(.unauthorized),
        .closedPaneAsTarget: .denied(.unauthorized),
    ]) { current, _ in current }

    /// `send` and `revoke`. An established peer edge and nothing else, which
    /// means a pane's own descendants are not reachable this way either: a child
    /// is something to control, not something to message, until it peers.
    static let peerEdgeRow: [Situation: Outcome] = credentialDenials.merging([
        .caller: .denied(.unauthorized),
        .callerNamedExplicitly: .denied(.unauthorized),
        .child: .denied(.unauthorized),
        .grandchild: .denied(.unauthorized),
        .sibling: .denied(.unauthorized),
        .parent: .denied(.unauthorized),
        .unrelated: .denied(.unauthorized),
        .peer: .allowed,
        .revokedPeer: .denied(.unauthorized),
        .closedPaneAsTarget: .denied(.unauthorized),
    ]) { current, _ in current }

    /// `run`. Control authority follows parentage and nothing else. The peer
    /// entry is the load-bearing one: peering is a communication edge, and a
    /// design that let it carry control would turn consent to talk into consent
    /// to be driven.
    ///
    /// An allowance here is not permission to execute anything. `run` is gated on
    /// `controlAllowRun` and answers `refused` in v1 either way; this row says
    /// only where the scope would reach once v2 exists.
    static let descendantRow: [Situation: Outcome] = credentialDenials.merging([
        .caller: .allowed,
        .callerNamedExplicitly: .allowed,
        .child: .allowed,
        .grandchild: .allowed,
        .sibling: .denied(.unauthorized),
        .parent: .denied(.unauthorized),
        .unrelated: .denied(.unauthorized),
        .peer: .denied(.unauthorized),
        .revokedPeer: .denied(.unauthorized),
        .closedPaneAsTarget: .denied(.unauthorized),
    ]) { current, _ in current }

    /// One row per verb, assigned by hand. Sharing a row between verbs is a
    /// claim that they really do reach the same panes, and it is written out
    /// verb by verb so that claim is made rather than inherited.
    static let rows: [ControlVerb: [Situation: Outcome]] = [
        .split: selfOnlyRow,
        .close: selfOnlyRow,
        .focus: selfOnlyRow,
        .zoom: selfOnlyRow,
        .resize: selfOnlyRow,
        .equalize: selfOnlyRow,
        .cwd: selfOnlyRow,
        .report: selfOnlyRow,
        .whoami: selfOnlyRow,
        .publish: selfOnlyRow,
        .connect: selfOnlyRow,
        .peers: selfOnlyRow,
        .recv: selfOnlyRow,
        .subscribe: selfOnlyRow,
        .layoutApply: selfOnlyRow,
        .list: scopedReadRow,
        .layoutExport: scopedReadRow,
        .send: peerEdgeRow,
        .revoke: peerEdgeRow,
        .run: descendantRow,
        .read: descendantRow,
        // The same row, and the claim is made rather than inherited: a caller may
        // rearrange the panes it made, its parent's other children are out of
        // reach, and a peer is out of reach for control however much it is
        // reachable for talking.
        .move: descendantRow,
    ]

    // MARK: The matrix

    @Test func everyVerbAnswersEverySituationTheWayTheTableSays() {
        let fixture = Fixture()

        for verb in ControlVerb.allCases {
            guard let row = Self.rows[verb] else {
                let reason = "no authorization row for \(verb.rawValue). A verb without a decided "
                    + "scope must fail this suite rather than inherit one."
                Issue.record("\(reason)")
                continue
            }

            for situation in Situation.allCases {
                guard let expected = row[situation] else {
                    Issue.record("the row for \(verb.rawValue) says nothing about \(situation)")
                    continue
                }

                let probe = fixture.probe(for: situation)
                let decision = fixture.graph.authorize(
                    token: probe.sent, verb: verb, target: probe.target
                )
                #expect(
                    Self.outcome(of: decision) == expected,
                    "\(verb.rawValue) x \(situation): expected \(expected)"
                )
            }
        }
    }

    static func outcome(of decision: PaneGraph.Decision) -> Outcome {
        switch decision {
        case .allowed: .allowed
        case let .denied(error): .denied(error.code)
        }
    }

    // MARK: The negative invariant, stated on its own

    /// A well-formed pane id is `badToken` for every verb, including the read
    /// verbs whose own answers are made of pane ids.
    ///
    /// Stated separately from the matrix as well as inside it, because this is
    /// the finding the design exists to prevent and the way it comes back is a
    /// plausible-looking accommodation for `whoami` and `list`, which traffic in
    /// display ids and would then "keep working with the ids they return".
    @Test func aWellFormedPaneIDIsBadTokenForEveryVerbIncludingTheReadOnes() {
        let fixture = Fixture()
        let ids = [
            fixture.root,
            fixture.child,
            fixture.peer,
            fixture.closed,
            ControlPaneID(rawValue: UUID()),
        ]

        for verb in ControlVerb.allCases {
            for id in ids {
                for spelling in [id.description, id.description.lowercased()] {
                    let decision = fixture.graph.authorize(
                        token: spelling, verb: verb, target: nil
                    )
                    #expect(
                        decision == .denied(.badToken),
                        "\(verb.rawValue) accepted a pane id as a credential"
                    )
                }
            }
        }
    }

    /// The check is a rejection and not a lookup miss, and this is the test that
    /// tells the two apart.
    ///
    /// The registration below is one the public API refuses to create, planted
    /// straight into the store. If `authorize` merely failed to *find* pane-id
    /// credentials, this graph would hand the whole workspace to anybody who can
    /// read `session.json`, and every other test in this file would still pass.
    @Test func aPlantedPaneIDRegistrationIsStillRejectedBeforeTheLookup() {
        var graph = PaneGraph()
        let a = ControlPaneID(rawValue: UUID())
        let live = PaneSecret("capability-of-a")
        graph.open(pane: a, createdBy: nil, secret: live)

        graph.registry[PaneSecret(a.description)] = a
        #expect(graph.registry[PaneSecret(a.description)] == a, "the plant did not take")

        for verb in ControlVerb.allCases {
            #expect(
                graph.authorize(token: a.description, verb: verb, target: nil)
                    == .denied(.badToken),
                "\(verb.rawValue) honoured a planted pane-id registration"
            )
        }

        // The pane's real capability is untouched by any of this, so the test is
        // measuring the rejection and not a graph that stopped working.
        guard case let .allowed(actor, _) = graph.authorize(
            token: live.rawValue, verb: .whoami, target: nil
        ) else {
            Issue.record("the real capability stopped working")
            return
        }
        #expect(actor == a)
    }

    /// A pane that does not exist and a live pane out of scope get the same
    /// answer, down to the message. A difference here would be an oracle: a
    /// caller could walk id space and learn which panes are live without being
    /// able to see any of them.
    @Test func anAbsentTargetAndAnOutOfScopeTargetAreIndistinguishable() {
        let fixture = Fixture()
        let nonexistent = ControlPaneID(rawValue: UUID())
        let sent = Fixture.capability("root").rawValue

        for verb in [ControlVerb.list, .send, .revoke, .run] {
            let absent = fixture.graph.authorize(token: sent, verb: verb, target: nonexistent)
            let outOfScope = fixture.graph.authorize(
                token: sent, verb: verb, target: fixture.unrelated
            )
            #expect(absent == outOfScope, "\(verb.rawValue) distinguished absent from out of scope")
            // Keyed on the verb's own scope. The message differs between verbs
            // by design, and may never differ between targets of one verb, which
            // is the line above.
            #expect(absent == .denied(.unauthorized(verb.scope)))
        }
    }

    /// An allowance names the actor, which is how a handler learns the calling
    /// pane. There is no other way to get it, deliberately: no response path can
    /// reach the token registry, because nothing public leads there.
    @Test func anAllowanceNamesTheResolvedActorAndTarget() {
        let fixture = Fixture()
        let sent = Fixture.capability("root").rawValue

        #expect(
            fixture.graph.authorize(token: sent, verb: .whoami, target: nil)
                == .allowed(actor: fixture.root, target: fixture.root)
        )
        #expect(
            fixture.graph.authorize(token: sent, verb: .list, target: fixture.grandchild)
                == .allowed(actor: fixture.root, target: fixture.grandchild)
        )
        #expect(
            fixture.graph.authorize(token: sent, verb: .send, target: fixture.peer)
                == .allowed(actor: fixture.root, target: fixture.peer)
        )
    }
}
