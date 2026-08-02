import Foundation
import Testing

@testable import PaneControl

/// `scope(of:)` decides which panes an actor may be told about, so a pane
/// missing from it is a pane the actor cannot see and a pane wrongly in it is a
/// disclosure. Both failures are silent at the call site: `list` answers, and
/// the answer is the wrong size.
///
/// The bug this suite exists to catch is the quiet one. An observer opened as a
/// fourth split sees one pane when the scope forgets peers, and nothing refuses,
/// logs, or crashes.
@Suite struct PaneScopeTests {
    /// A parent, its child, its grandchild, a peer of the parent, and a stranger.
    ///
    /// The same shape `ObserverScopeTests` uses, deliberately: the two suites
    /// walk one graph from opposite ends, and a fixture they share would let a
    /// mistake in the shape agree with itself.
    struct Fixture {
        var graph = PaneGraph()
        let parent = ControlPaneID(rawValue: UUID())
        let child = ControlPaneID(rawValue: UUID())
        let grandchild = ControlPaneID(rawValue: UUID())
        let peer = ControlPaneID(rawValue: UUID())
        let stranger = ControlPaneID(rawValue: UUID())

        init() {
            let all = [
                ("parent", parent), ("child", child), ("grandchild", grandchild),
                ("peer", peer), ("stranger", stranger),
            ]
            for (label, pane) in all {
                let creator: ControlPaneID? = switch label {
                case "child": parent
                case "grandchild": child
                default: nil
                }
                graph.open(pane: pane, createdBy: creator, secret: PaneSecret("c1-not-a-uuid-\(label)"))
            }
            graph.addPeerEdge(between: parent, and: peer)
        }

        var everyPane: [ControlPaneID] { [parent, child, grandchild, peer, stranger] }
    }

    /// A pane with no children and no peers reaches itself and stops. Stated
    /// because the empty answer is `[actor]` and never `[]`: a caller dropped
    /// from its own scope could not `list` the pane it is sitting in.
    @Test func aLonePaneIsItsOwnWholeScope() {
        let fixture = Fixture()
        #expect(fixture.graph.scope(of: fixture.stranger) == [fixture.stranger])
    }

    /// Transitive, not one generation. The grandchild is reached through the
    /// child, which is the walk `children(of:)` alone does not do.
    @Test func theWalkReachesTheGrandchildAndNotOnlyTheChild() {
        let fixture = Fixture()
        #expect(
            fixture.graph.scope(of: fixture.parent).prefix(3)
                == [fixture.parent, fixture.child, fixture.grandchild]
        )
    }

    /// The failure the observer pane was opened into. A scope that walks
    /// parentage and forgets peer edges answers a plausible, smaller list, and
    /// the pane that asked sees one entry where it expected four.
    @Test func aPeerIsInScopeAndSitsAfterTheDescendants() {
        let fixture = Fixture()
        let scope = fixture.graph.scope(of: fixture.parent)

        #expect(scope == [fixture.parent, fixture.child, fixture.grandchild, fixture.peer])
        #expect(scope.contains(fixture.stranger) == false)
    }

    /// Downward only. The child can see below itself and the parent above it can
    /// see the child, but the parent's peer is not the child's, so a peer edge
    /// does not widen every scope under the pane that holds it.
    @Test func aParentsPeerIsNotInheritedByItsChildren() {
        let fixture = Fixture()
        #expect(fixture.graph.scope(of: fixture.child) == [fixture.child, fixture.grandchild])
        #expect(fixture.graph.scope(of: fixture.grandchild) == [fixture.grandchild])
    }

    /// One entry per pane, at its first position. A pane reachable both ways
    /// listed twice would be a duplicate on the wire and, in `list`, a second
    /// record for one pane.
    @Test func aPaneReachableAsBothDescendantAndPeerAppearsOnce() {
        var fixture = Fixture()
        fixture.graph.addPeerEdge(between: fixture.parent, and: fixture.grandchild)

        let scope = fixture.graph.scope(of: fixture.parent)

        #expect(scope == [fixture.parent, fixture.child, fixture.grandchild, fixture.peer])
        #expect(Set(scope).count == scope.count)
    }

    /// The property, and the reason `scope` may sit beside `observers` rather
    /// than being folded into it. They walk one rule from opposite ends: an actor
    /// has a subject in scope exactly when that subject has the actor in its
    /// audience. A change to either side that breaks the pairing fails here.
    @Test func scopeAndObserversAreTheSameEdgeReadFromBothEnds() {
        let fixture = Fixture()
        for actor in fixture.everyPane {
            let scope = Set(fixture.graph.scope(of: actor))
            for subject in fixture.everyPane {
                #expect(
                    scope.contains(subject)
                        == fixture.graph.observers(of: subject).contains(actor),
                    "\(actor) -> \(subject)"
                )
            }
        }
    }

    /// Same graph, same list, in the same order. The walk pops a stack and reads
    /// `Set`s whose iteration order is not promised, so without the sort inside
    /// it two calls could answer two orderings and a client diffing `list`
    /// against its last answer would see churn that means nothing.
    @Test func repeatedWalksOfOneGraphAnswerTheSameOrder() {
        let fixture = Fixture()
        let first = fixture.graph.scope(of: fixture.parent)
        for _ in 0..<8 {
            #expect(fixture.graph.scope(of: fixture.parent) == first)
        }
    }

    /// A closed pane leaves the scope of the pane that opened it. Parentage is
    /// dropped on close, so this holds without anybody pruning a second index.
    @Test func aClosedChildLeavesItsParentsScope() {
        var fixture = Fixture()
        fixture.graph.close(pane: fixture.child)

        let scope = fixture.graph.scope(of: fixture.parent)
        #expect(scope.contains(fixture.child) == false)
        #expect(scope.contains(fixture.grandchild) == false)
    }
}
