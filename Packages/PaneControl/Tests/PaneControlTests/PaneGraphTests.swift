import Foundation
import Testing

@testable import PaneControl

@Suite struct PaneGraphTests {
    static func pane() -> ControlPaneID { ControlPaneID(rawValue: UUID()) }

    /// A stand-in for what `SecRandomCopyBytes` produces. The shape matters only
    /// in that it is not a UUID.
    static func secret(_ label: String) -> PaneSecret {
        PaneSecret("d5b0c6e2-not-a-uuid-\(label)")
    }

    // MARK: The registry

    @Test func aSecretMapsToExactlyOnePane() {
        var graph = PaneGraph()
        let a = Self.pane()
        let b = Self.pane()

        #expect(graph.open(pane: a, createdBy: nil, secret: Self.secret("a")) == true)
        #expect(graph.open(pane: b, createdBy: nil, secret: Self.secret("b")) == true)

        guard case let .allowed(actor, _) = graph.authorize(
            token: Self.secret("a").rawValue, verb: .whoami, target: nil
        ) else {
            Issue.record("a registered secret did not authenticate")
            return
        }
        #expect(actor == a)
        #expect(actor != b)
    }

    /// The same secret cannot be issued twice, so no token is ambiguous about
    /// whom it speaks for. A second registration is refused whole rather than
    /// overwriting the first, which would silently transfer a live pane's
    /// capability to a new one.
    @Test func aSecretAlreadyIssuedIsRefusedRatherThanReassigned() {
        var graph = PaneGraph()
        let a = Self.pane()
        let b = Self.pane()
        let shared = Self.secret("shared")

        #expect(graph.open(pane: a, createdBy: nil, secret: shared) == true)
        #expect(graph.open(pane: b, createdBy: nil, secret: shared) == false)
        #expect(graph.isOpen(b) == false)

        guard case let .allowed(actor, _) = graph.authorize(
            token: shared.rawValue, verb: .whoami, target: nil
        ) else {
            Issue.record("the first registration stopped working")
            return
        }
        #expect(actor == a)
    }

    /// The registry refuses to create the registration that
    /// ``PaneGraph/authorize(token:verb:target:)`` refuses to honour.
    ///
    /// Two enforcement points and one rule. This is the first: a caller that
    /// tried to mint a pane's own id as its capability, which is precisely the
    /// design the spec supersedes, gets nothing registered at all rather than a
    /// pane whose token happens to be useless.
    @Test func theRegistryRefusesASecretThatIsReallyAPaneID() {
        var graph = PaneGraph()
        let a = Self.pane()

        #expect(graph.open(pane: a, createdBy: nil, secret: PaneSecret(a.description)) == false)
        #expect(graph.isOpen(a) == false)
        #expect(graph.registry.isEmpty)

        // Any pane's id, not only the pane's own.
        let other = Self.pane()
        #expect(graph.open(pane: a, createdBy: nil, secret: PaneSecret(other.description)) == false)

        // Uppercase, lowercase, and braces are all things `UUID(uuidString:)`
        // accepts, so none of them is a way past the check.
        for spelling in [
            a.description.lowercased(),
            a.description.uppercased(),
        ] {
            #expect(graph.open(pane: a, createdBy: nil, secret: PaneSecret(spelling)) == false)
        }
    }

    /// A pane cannot be opened twice, so a second `open` cannot quietly hand a
    /// live pane a second capability.
    @Test func aPaneAlreadyOpenIsRefusedASecondRegistration() {
        var graph = PaneGraph()
        let a = Self.pane()

        #expect(graph.open(pane: a, createdBy: nil, secret: Self.secret("first")) == true)
        #expect(graph.open(pane: a, createdBy: nil, secret: Self.secret("second")) == false)
        #expect(graph.registry.count == 1)
    }

    @Test func aClosedPanesSecretStopsWorking() {
        var graph = PaneGraph()
        let a = Self.pane()
        let token = Self.secret("a").rawValue

        graph.open(pane: a, createdBy: nil, secret: Self.secret("a"))
        guard case .allowed = graph.authorize(token: token, verb: .whoami, target: nil) else {
            Issue.record("a live pane's secret did not authenticate")
            return
        }

        #expect(graph.close(pane: a) == true)
        #expect(graph.isOpen(a) == false)
        #expect(graph.authorize(token: token, verb: .whoami, target: nil)
            == .denied(.badToken))

        // Closing twice changes nothing, and says so.
        #expect(graph.close(pane: a) == false)
    }

    // MARK: Parentage

    /// Closing a parent makes its children roots. It does not reparent them to
    /// the grandparent, which would hand the grandparent authority over panes it
    /// never created, and it does not leave the edge pointing at a pane that is
    /// gone.
    @Test func closingAParentMakesItsChildrenRootsRatherThanReparentingThem() {
        var graph = PaneGraph()
        let root = Self.pane()
        let middle = Self.pane()
        let leaf = Self.pane()

        graph.open(pane: root, createdBy: nil, secret: Self.secret("root"))
        graph.open(pane: middle, createdBy: root, secret: Self.secret("middle"))
        graph.open(pane: leaf, createdBy: middle, secret: Self.secret("leaf"))

        #expect(graph.isDescendant(leaf, of: root))

        graph.close(pane: middle)

        #expect(graph.parent(of: leaf) == nil)
        #expect(graph.isDescendant(leaf, of: root) == false)
        #expect(graph.children(of: root).isEmpty)
    }

    /// Scope follows the chain however deep it goes, which is what makes the
    /// grandchild row of the authorization matrix mean something.
    @Test func descendanceIsTransitiveAndNeverPointsUpwards() {
        var graph = PaneGraph()
        let root = Self.pane()
        let middle = Self.pane()
        let leaf = Self.pane()

        graph.open(pane: root, createdBy: nil, secret: Self.secret("root"))
        graph.open(pane: middle, createdBy: root, secret: Self.secret("middle"))
        graph.open(pane: leaf, createdBy: middle, secret: Self.secret("leaf"))

        #expect(graph.isDescendant(middle, of: root))
        #expect(graph.isDescendant(leaf, of: root))
        #expect(graph.isDescendant(root, of: leaf) == false)
        #expect(graph.isDescendant(root, of: root) == false)
    }

    /// On restore the app replays panes in whatever order the session file lists
    /// them, so a child can be opened before its parent. The edge is kept and
    /// resolves once the parent arrives; dropping it would make parentage depend
    /// on iteration order, which is the kind of bug that reproduces on one
    /// machine.
    @Test func aChildOpenedBeforeItsParentKeepsTheEdge() {
        var graph = PaneGraph()
        let parent = Self.pane()
        let child = Self.pane()

        graph.open(pane: child, createdBy: parent, secret: Self.secret("child"))
        #expect(graph.parent(of: child) == parent)
        #expect(graph.isDescendant(child, of: parent))

        graph.open(pane: parent, createdBy: nil, secret: Self.secret("parent"))
        #expect(graph.isDescendant(child, of: parent))
    }

    // MARK: Peering

    @Test func aPeerEdgeIsSymmetricInBothDirections() {
        var graph = PaneGraph()
        let a = Self.pane()
        let b = Self.pane()
        graph.open(pane: a, createdBy: nil, secret: Self.secret("a"))
        graph.open(pane: b, createdBy: nil, secret: Self.secret("b"))

        #expect(graph.addPeerEdge(between: a, and: b) == true)
        #expect(graph.peers(of: a) == [b])
        #expect(graph.peers(of: b) == [a])

        // Idempotent, and it says so rather than reporting a change it did not
        // make.
        #expect(graph.addPeerEdge(between: a, and: b) == false)
        #expect(graph.addPeerEdge(between: b, and: a) == false)
    }

    /// Removing an edge removes both halves. A revocation that dropped one
    /// direction would leave the revoked peer still able to see and message the
    /// pane that revoked it, with the owner believing otherwise.
    @Test func removingAPeerEdgeRemovesBothHalves() {
        var graph = PaneGraph()
        let a = Self.pane()
        let b = Self.pane()
        graph.open(pane: a, createdBy: nil, secret: Self.secret("a"))
        graph.open(pane: b, createdBy: nil, secret: Self.secret("b"))
        graph.addPeerEdge(between: a, and: b)

        #expect(graph.removePeerEdge(between: b, and: a) == true)
        #expect(graph.peers(of: a).isEmpty)
        #expect(graph.peers(of: b).isEmpty)
        #expect(graph.removePeerEdge(between: a, and: b) == false)
    }

    @Test func closingAPaneDropsItsPeerEdgesFromTheOtherSideToo() {
        var graph = PaneGraph()
        let a = Self.pane()
        let b = Self.pane()
        graph.open(pane: a, createdBy: nil, secret: Self.secret("a"))
        graph.open(pane: b, createdBy: nil, secret: Self.secret("b"))
        graph.addPeerEdge(between: a, and: b)

        graph.close(pane: a)
        #expect(graph.peers(of: b).isEmpty)
        #expect(graph.peerEdges.isEmpty)
    }

    /// A pane cannot peer with itself, and a pane that is not open cannot be
    /// peered with at all. Both would produce an edge whose other end has no
    /// capability, which is an edge nothing can ever use and one more thing for
    /// `close` to have to clean up correctly.
    @Test func aPeerEdgeNeedsTwoDistinctLivePanes() {
        var graph = PaneGraph()
        let a = Self.pane()
        let ghost = Self.pane()
        graph.open(pane: a, createdBy: nil, secret: Self.secret("a"))

        #expect(graph.addPeerEdge(between: a, and: a) == false)
        #expect(graph.addPeerEdge(between: a, and: ghost) == false)
        #expect(graph.peers(of: a).isEmpty)
    }
}
