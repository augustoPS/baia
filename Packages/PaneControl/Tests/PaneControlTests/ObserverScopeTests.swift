import Foundation
import Testing

@testable import PaneControl

/// `observers` and `authorize` are two readers of one rule, and two readers is
/// what lets one of them be wrong. This suite is why a second reader is
/// acceptable at all.
@Suite struct ObserverScopeTests {
    /// A parent, its child, its grandchild, a peer of the parent, and a stranger.
    struct Fixture {
        static func capability(_ label: String) -> String { "c1-not-a-uuid-\(label)" }

        var graph = PaneGraph()
        let parent = ControlPaneID(rawValue: UUID())
        let child = ControlPaneID(rawValue: UUID())
        let grandchild = ControlPaneID(rawValue: UUID())
        let peer = ControlPaneID(rawValue: UUID())
        let stranger = ControlPaneID(rawValue: UUID())

        var tokens: [ControlPaneID: String] = [:]

        init() {
            let all = [
                ("parent", parent), ("child", child), ("grandchild", grandchild),
                ("peer", peer), ("stranger", stranger),
            ]
            for (label, pane) in all {
                let capability = Fixture.capability(label)
                tokens[pane] = capability
                let creator: ControlPaneID? = switch label {
                case "child": parent
                case "grandchild": child
                default: nil
                }
                graph.open(pane: pane, createdBy: creator, secret: PaneSecret(capability))
            }
            graph.addPeerEdge(between: parent, and: peer)
        }

        var everyPane: [ControlPaneID] { [parent, child, grandchild, peer, stranger] }
    }

    /// The property. For every ordered pair, being in the audience and being
    /// allowed to `list` are the same fact.
    @Test func observersAgreesWithAuthorizeForEveryPair() {
        let fixture = Fixture()
        for subject in fixture.everyPane {
            let audience = fixture.graph.observers(of: subject)
            for actor in fixture.everyPane {
                let allowed: Bool
                switch fixture.graph.authorize(
                    token: fixture.tokens[actor]!, verb: .list, target: subject
                ) {
                case .allowed: allowed = true
                case .denied: allowed = false
                }
                #expect(
                    audience.contains(actor) == allowed,
                    "actor \(actor) and subject \(subject) disagree"
                )
            }
        }
    }

    @Test func theAudienceIsSelfAncestorsAndPeers() {
        let fixture = Fixture()
        #expect(fixture.graph.observers(of: fixture.grandchild) == [
            fixture.grandchild, fixture.child, fixture.parent,
        ])
        #expect(fixture.graph.observers(of: fixture.parent) == [
            fixture.parent, fixture.peer,
        ])
        #expect(fixture.graph.observers(of: fixture.stranger) == [fixture.stranger])
    }

    /// A cycle cannot be built through the public API, and an unbounded walk on a
    /// path the app runs per event would be a hang rather than a wrong answer.
    @Test func theWalkTerminatesOnAPlantedCycle() {
        var graph = PaneGraph()
        let a = ControlPaneID(rawValue: UUID())
        let b = ControlPaneID(rawValue: UUID())
        graph.open(pane: a, createdBy: nil, secret: PaneSecret("c1-not-a-uuid-a"))
        graph.open(pane: b, createdBy: nil, secret: PaneSecret("c1-not-a-uuid-b"))
        graph.parentOf[a] = b
        graph.parentOf[b] = a

        #expect(graph.observers(of: a) == [a, b])
    }
}
