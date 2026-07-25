import Foundation
import Testing

@testable import WorkspaceLayout

@Suite struct PaneTreeTests {
    @Test func paneIDsReadEveryFirstChildBeforeItsSecond() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)),
            second: .leaf(c)
        )
        #expect(tree.paneIDs == [a, b, c])
    }

    @Test func containsFindsAPaneNestedSeveralLevelsDown() {
        let deep = PaneID()
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(PaneID()),
            second: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(PaneID()),
                second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneID()), second: .leaf(deep))
            )
        )
        #expect(tree.contains(deep))
        #expect(!tree.contains(PaneID()))
    }

    @Test func splittingPutsTheNewPaneSecond() {
        let existing = PaneID()
        let opened = PaneID()
        let split = PaneTree.leaf(existing).splitting(
            existing,
            axis: .horizontal,
            newPane: opened,
            ratio: 0.5
        )
        #expect(split == .split(axis: .horizontal, ratio: 0.5, first: .leaf(existing), second: .leaf(opened)))
    }

    @Test func splittingANestedPaneLeavesTheRestOfTheTreeAlone() {
        let untouched = PaneID()
        let target = PaneID()
        let opened = PaneID()
        // The outer split's own axis and ratio differ from the new one, so a
        // rebuild that dropped them would show up here rather than in a tree where
        // every split happens to look the same.
        let tree = PaneTree.split(
            axis: .vertical,
            ratio: 0.3,
            first: .leaf(untouched),
            second: .leaf(target)
        )

        let split = tree.splitting(target, axis: .horizontal, newPane: opened, ratio: 0.6)

        #expect(split == .split(
            axis: .vertical,
            ratio: 0.3,
            first: .leaf(untouched),
            second: .split(axis: .horizontal, ratio: 0.6, first: .leaf(target), second: .leaf(opened))
        ))
    }

    @Test func splittingAPaneThatIsNotInTheTreeIsNil() {
        let tree = PaneTree.leaf(PaneID())
        #expect(tree.splitting(PaneID(), axis: .horizontal, newPane: PaneID(), ratio: 0.5) == nil)
    }

    @Test func splittingWithAnIDTheTreeAlreadyHoldsIsNil() {
        // A duplicated id makes `contains` true in two places, and then a close
        // removes whichever leaf the walk reaches first while the other pane keeps
        // a shell running somewhere off screen.
        let first = PaneID()
        let second = PaneID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))
        #expect(tree.splitting(first, axis: .vertical, newPane: second, ratio: 0.5) == nil)
    }

    @Test func splittingClampsARatioAtTheEdgeOfTheRange() {
        let existing = PaneID()
        let opened = PaneID()

        let low = PaneTree.leaf(existing).splitting(existing, axis: .horizontal, newPane: opened, ratio: 0)
        let high = PaneTree.leaf(existing).splitting(existing, axis: .horizontal, newPane: opened, ratio: 1)

        #expect(low == .split(axis: .horizontal, ratio: 0.05, first: .leaf(existing), second: .leaf(opened)))
        #expect(high == .split(axis: .horizontal, ratio: 0.95, first: .leaf(existing), second: .leaf(opened)))
    }

    @Test func closingPromotesTheSiblingAndKeepsTheGrandparentsSplit() {
        let kept = PaneID()
        let sibling = PaneID()
        let closed = PaneID()
        // The grandparent is vertical at 0.3 and the parent horizontal at 0.7, so a
        // promotion that rebuilt the spine with the wrong axis or the wrong ratio
        // cannot pass by coincidence.
        let tree = PaneTree.split(
            axis: .vertical,
            ratio: 0.3,
            first: .leaf(kept),
            second: .split(axis: .horizontal, ratio: 0.7, first: .leaf(sibling), second: .leaf(closed))
        )

        #expect(tree.closing(closed) == .split(
            axis: .vertical,
            ratio: 0.3,
            first: .leaf(kept),
            second: .leaf(sibling)
        ))
    }

    @Test func closingLeavesNoSplitWithOneChild() {
        let closed = PaneID()
        let survivor = PaneID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(closed), second: .leaf(survivor))

        // A tree that kept the split around its one remaining child would still
        // answer paneIDs correctly, so the assertion is on the shape and not on the
        // pane list.
        #expect(tree.closing(closed) == .leaf(survivor))
    }

    @Test func closingTheOnlyPaneIsNil() {
        let only = PaneID()
        #expect(PaneTree.leaf(only).closing(only) == nil)
    }

    @Test func closingAPaneThatIsNotInTheTreeIsNil() {
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneID()), second: .leaf(PaneID()))
        #expect(tree.closing(PaneID()) == nil)
    }

    @Test func replacingRatioMovesTheInnermostSplitHoldingThePane() {
        let outer = PaneID()
        let target = PaneID()
        let inner = PaneID()
        let tree = PaneTree.split(
            axis: .vertical,
            ratio: 0.3,
            first: .leaf(outer),
            second: .split(axis: .horizontal, ratio: 0.7, first: .leaf(target), second: .leaf(inner))
        )

        // The outer ratio staying at 0.3 is the point: a drag on an inner divider
        // that moved the outer one would resize a pane the user never touched.
        #expect(tree.replacingRatio(forSplitContaining: target, with: 0.2) == .split(
            axis: .vertical,
            ratio: 0.3,
            first: .leaf(outer),
            second: .split(axis: .horizontal, ratio: 0.2, first: .leaf(target), second: .leaf(inner))
        ))
    }

    @Test func replacingRatioClampsTheNewValue() {
        let first = PaneID()
        let second = PaneID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))

        // A divider dragged past the window edge arrives as a fraction outside the
        // range, and a pane at 0 is a live shell with nothing to click on.
        #expect(tree.replacingRatio(forSplitContaining: second, with: -3) == .split(
            axis: .horizontal,
            ratio: 0.05,
            first: .leaf(first),
            second: .leaf(second)
        ))
    }

    @Test func replacingRatioOnASinglePaneIsNil() {
        let only = PaneID()
        #expect(PaneTree.leaf(only).replacingRatio(forSplitContaining: only, with: 0.5) == nil)
    }

    @Test func replacingRatioForAPaneThatIsNotInTheTreeIsNil() {
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneID()), second: .leaf(PaneID()))
        #expect(tree.replacingRatio(forSplitContaining: PaneID(), with: 0.5) == nil)
    }

    @Test func theSiblingOfAPaneIsTheSubtreeThatTakesItsSpace() {
        let closing = PaneID()
        let heir = PaneID()
        let other = PaneID()
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(other),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(closing), second: .leaf(heir))
        )

        // The whole subtree, not the pane next to it: the sibling can itself be a
        // split, and it is the split that inherits the space.
        #expect(tree.sibling(of: closing) == .leaf(heir))
        #expect(tree.sibling(of: other) == .split(axis: .vertical, ratio: 0.5, first: .leaf(closing), second: .leaf(heir)))
    }

    @Test func theRootLeafHasNoSibling() {
        let only = PaneID()
        #expect(PaneTree.leaf(only).sibling(of: only) == nil)
    }

    @Test func cyclingPanesWrapsPastEachEnd() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )

        #expect(tree.pane(after: b) == c)
        #expect(tree.pane(after: c) == a)
        #expect(tree.pane(before: b) == a)
        #expect(tree.pane(before: a) == c)
    }

    @Test func cyclingIsNilForTheOnlyPaneAndForAnAbsentOne() {
        let only = PaneID()
        // Nil rather than the pane itself, so a caller cannot mistake having wrapped
        // around to where it started for a focus change worth rendering.
        #expect(PaneTree.leaf(only).pane(after: only) == nil)
        #expect(PaneTree.leaf(only).pane(before: only) == nil)
        #expect(PaneTree.leaf(only).pane(after: PaneID()) == nil)
    }
}
