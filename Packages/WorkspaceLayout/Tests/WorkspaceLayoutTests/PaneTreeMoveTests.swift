import Foundation
import Testing

@testable import WorkspaceLayout

/// What a move is allowed to change, and what it must not.
///
/// A move is the one mutator that changes where a pane sits without changing
/// which panes exist. Everything here is written against that sentence: the set
/// of ids is an invariant, the shape is the only output, and a request that
/// cannot mean anything answers nil rather than half a tree.
@Suite struct PaneTreeMoveTests {
    /// A three-pane tree whose first child is a leaf and whose second is a split,
    /// which is the shape every test below needs: `a`'s sibling is a `.split`, so
    /// inserting beside `a` is the case a naive implementation flattens.
    ///
    /// Every ratio is a half so an `==` between two trees is an assertion about
    /// their shape. A move discards the ratio of the split it collapses and builds
    /// its new one at a half, so a round trip over a tree with any other ratio
    /// could not come back equal whatever the implementation did.
    private struct NestedTree {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()

        var tree: PaneTree {
            .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(a),
                second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
            )
        }
    }

    @Test func movingKeepsEveryPaneItStartedWith() {
        let fixture = NestedTree()
        let moved = fixture.tree.moving(
            fixture.b,
            beside: fixture.a,
            axis: .horizontal,
            before: true
        )
        // The whole point of the operation: nothing is created and nothing is
        // closed, so the pane arrives carrying the id it left with. Written as a
        // close and a split it would arrive with a fresh one, and a fresh id is a
        // fresh surface.
        #expect(moved?.paneIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            == fixture.tree.paneIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
        #expect(moved?.contains(fixture.b) == true)
    }

    /// A move and its inverse come back to the tree they started from.
    ///
    /// **The pane it moves beside has a `.split` for a sibling, and that is the
    /// whole reason this fixture is three panes deep.** Inserting beside `a` has
    /// to build a new split *at `a`'s leaf*; an implementation that instead adds
    /// the pane to `a`'s parent, whose axis already matches, produces a tree that
    /// looks right on screen and never comes back. A round trip over two leaves
    /// cannot tell the two apart, because with two leaves the parent split and the
    /// leaf's own split are the same node.
    ///
    /// The inverse is not the same call with `before` flipped. A move is named by
    /// the pane it lands next to, and the pane `b` lands next to on the way out is
    /// not the one it came from, so coming back names `c`.
    ///
    /// **A pane whose own sibling is a `.split` cannot round trip at all**, and no
    /// implementation can fix that. Moving it away collapses its parent and
    /// promotes the sibling, and coming back would have to rebuild a split whose
    /// child is that whole subtree, which pane-keyed addressing cannot name. So
    /// the split sibling under test here is the target's, which is the half of the
    /// shape a move can be held to.
    @Test func movingAPaneAndMovingItBackReturnsTheTreeItStartedFrom() {
        let fixture = NestedTree()
        let out = fixture.tree.moving(
            fixture.b,
            beside: fixture.a,
            axis: .horizontal,
            before: true
        )
        let back = out?.moving(fixture.b, beside: fixture.c, axis: .vertical, before: true)
        #expect(out != fixture.tree)
        #expect(back == fixture.tree)
    }

    @Test func movingAPaneBesideItselfIsNil() {
        let fixture = NestedTree()
        // Nil rather than the tree unchanged, because a caller that names one pane
        // twice has not described a move at all, and answering with a tree would
        // spend a rebuild, which is a SIGWINCH to every shell in the window.
        #expect(fixture.tree.moving(
            fixture.b,
            beside: fixture.b,
            axis: .horizontal,
            before: false
        ) == nil)
    }

    @Test func movingAPaneThatIsNotInTheTreeIsNil() {
        let fixture = NestedTree()
        #expect(fixture.tree.moving(
            PaneID(),
            beside: fixture.a,
            axis: .horizontal,
            before: false
        ) == nil)
    }

    @Test func movingBesideAPaneThatIsNotInTheTreeIsNil() {
        let fixture = NestedTree()
        // The other half of the same rule, and the one that keeps a cross-tab move
        // out of the type: a pane in another tab is a pane this tree does not
        // hold, so it answers the same nil an invented id gets.
        #expect(fixture.tree.moving(
            fixture.a,
            beside: PaneID(),
            axis: .horizontal,
            before: false
        ) == nil)
    }
}
