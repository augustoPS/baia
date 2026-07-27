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

    /// Two splits on the same spine, at different ratios, so a mutation that
    /// addressed the wrong one cannot pass by coincidence.
    private struct NestedSplits {
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

    @Test func replacingRatioAtPathMovesTheNamedSplitNotTheInnermostOne() {
        let panes = NestedSplits()

        // The empty path names the root. This is the exact case
        // `replacingRatio(forSplitContaining:)` gets wrong: it descends to the
        // innermost split holding a pane, so a drag on the outer divider would
        // move the inner one and resize two panes the user never touched.
        let moved = panes.tree.replacingRatio(at: SplitPath(), with: 0.3)

        #expect(moved == .split(
            axis: .horizontal,
            ratio: 0.3,
            first: .leaf(panes.a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(panes.b), second: .leaf(panes.c))
        ))
    }

    @Test func replacingRatioAtPathMovesTheSplitTheIndicesNameAndNothingAbove() {
        let panes = NestedSplits()

        let moved = panes.tree.replacingRatio(at: SplitPath([1]), with: 0.25)

        #expect(moved == .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(panes.a),
            second: .split(axis: .vertical, ratio: 0.25, first: .leaf(panes.b), second: .leaf(panes.c))
        ))
    }

    @Test func replacingRatioAtAPathThatRunsIntoALeafIsNil() {
        let panes = NestedSplits()
        // Index 0 of the root is a leaf, so there is no divider that far down and
        // the caller must not persist anything.
        #expect(panes.tree.replacingRatio(at: SplitPath([0]), with: 0.3) == nil)
        #expect(panes.tree.replacingRatio(at: SplitPath([1, 0]), with: 0.3) == nil)
        #expect(PaneTree.leaf(panes.a).replacingRatio(at: SplitPath(), with: 0.3) == nil)
    }

    @Test func replacingRatioAtAnIndexNoChildHasIsNil() {
        let panes = NestedSplits()
        // A split has exactly two children, so anything other than 0 or 1 names
        // nothing at all rather than falling back to one of them.
        #expect(panes.tree.replacingRatio(at: SplitPath([2]), with: 0.3) == nil)
        #expect(panes.tree.replacingRatio(at: SplitPath([-1]), with: 0.3) == nil)
    }

    @Test func replacingRatioAtPathClampsWhatItStoresNotJustWhatItReportsBack() {
        let panes = NestedSplits()

        // A drag carried past the window edge arrives as a fraction outside the
        // range, and the view layer clamps with this same function, so the stored
        // value and the drawn position agree instead of the divider being yanked
        // back a layout pass later.
        //
        // Read out of the case rather than through `ratio(at:)`, which clamps as
        // it reads and would report 0.05 for a stored -3. Asserting through it
        // passes whatever is in the tree, and what is in the tree is what
        // `SessionSnapshot` encodes and hands to the next launch.
        #expect(storedRatio(panes.tree.replacingRatio(at: SplitPath(), with: -3)) == 0.05)
        #expect(storedRatio(panes.tree.replacingRatio(at: SplitPath(), with: 9)) == 0.95)

        // And through the JSON, since that is the copy that outlives the process.
        //
        // A round trip rather than a search for "-3" in the encoded text, which
        // this used to be and which failed about one run in three for a reason
        // that had nothing to do with ratios: a pane id encodes as a UUID string,
        // and any UUID whose second, third, fourth or fifth group begins with a
        // three carries "-3" in it.
        let encoded = try? JSONEncoder().encode(panes.tree.replacingRatio(at: SplitPath(), with: -3))
        let decoded = encoded.flatMap { try? JSONDecoder().decode(PaneTree.self, from: $0) }
        #expect(storedRatio(decoded) == 0.05)
    }

    /// The ratio the root case actually carries, with no accessor in the way.
    private func storedRatio(_ tree: PaneTree?) -> Double? {
        guard case let .split(_, ratio, _, _) = tree else { return nil }
        return ratio
    }

    @Test func replacingRatioAtPathIsNilWhenTheClampedValueIsUnchanged() {
        let panes = NestedSplits()

        // Nil rather than an identical tree, so a click that moved the divider by
        // nothing does not write the session file.
        #expect(panes.tree.replacingRatio(at: SplitPath(), with: 0.5) == nil)
        #expect(panes.tree.replacingRatio(at: SplitPath([1]), with: 0.5) == nil)
    }

    @Test func ratioAtPathReadsTheNamedSplitAndIsNilForAnythingElse() {
        let panes = NestedSplits()
        let tree = panes.tree.replacingRatio(at: SplitPath([1]), with: 0.25)

        #expect(tree?.ratio(at: SplitPath()) == 0.5)
        #expect(tree?.ratio(at: SplitPath([1])) == 0.25)
        #expect(tree?.ratio(at: SplitPath([0])) == nil)
        #expect(tree?.ratio(at: SplitPath([1, 1])) == nil)
    }

    @Test func ratioAtPathReportsWhatTheSplitLaysOutAtRatherThanWhatIsStored() {
        // A hand-built case can carry any Double, and `layout(in:)` clamps as it
        // reads. Reporting the raw 0.99 would tell a caller comparing against a
        // measured on-screen fraction that the divider had moved when it had not.
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.99, first: .leaf(PaneID()), second: .leaf(PaneID()))
        #expect(tree.ratio(at: SplitPath()) == 0.95)
    }

    @Test func layoutAfterReplacingRatioAtPathMovesOnlyTheNamedSplitsPanes() {
        let panes = NestedSplits()
        let moved = panes.tree.replacingRatio(at: SplitPath([1]), with: 0.25)
        let placed = moved?.layout(in: .unit) ?? []

        // The left column is untouched at half the width; the right column's own
        // divider sits a quarter of the way down. This is the assertion that ties
        // the addressing scheme to what the window actually shows.
        #expect(placed.map(\.pane) == [panes.a, panes.b, panes.c])
        #expect(placed[0].rect == LayoutRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(placed[1].rect == LayoutRect(x: 0.5, y: 0, width: 0.5, height: 0.25))
        #expect(placed[2].rect == LayoutRect(x: 0.5, y: 0.25, width: 0.5, height: 0.75))
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
