import Foundation
import Testing

@testable import WorkspaceLayout

@Suite struct PaneTreeLayoutTests {
    /// Two columns whose dividers sit at different heights: the left one splits at
    /// 0.75 and the right one at 0.25.
    ///
    /// This is the shape that separates a geometric answer from a tree walk. A walk
    /// leaving the bottom-left pane crosses to the right column and takes its first
    /// child, which is the pane at the *top* right. Every ratio here is an exact
    /// binary fraction, so the expectations can compare rects with `==` instead of
    /// carrying a tolerance that would hide a real drift.
    private struct UnevenColumns {
        let topLeft = PaneID()
        let bottomLeft = PaneID()
        let topRight = PaneID()
        let bottomRight = PaneID()

        var tree: PaneTree {
            .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .split(
                    axis: .vertical,
                    ratio: 0.75,
                    first: .leaf(topLeft),
                    second: .leaf(bottomLeft)
                ),
                second: .split(
                    axis: .vertical,
                    ratio: 0.25,
                    first: .leaf(topRight),
                    second: .leaf(bottomRight)
                )
            )
        }
    }

    /// Three columns of uneven rows: a left column split at 0.75, a middle one split
    /// in half, and a right one split at 0.75 again.
    ///
    /// Built to make the two tie-break rules load-bearing, which the two-column shape
    /// above cannot. There, the candidate with the nearest perpendicular edge is also
    /// the first one in visual order, so a search that ignored the offset entirely
    /// would still answer correctly. Here the bottom-right pane wins on offset while
    /// coming last, and it also wins on offset when the correct answer is a nearer
    /// pane in the middle column.
    private struct ThreeUnevenColumns {
        let topLeft = PaneID()
        let bottomLeft = PaneID()
        let middleTop = PaneID()
        let middleBottom = PaneID()
        let rightTop = PaneID()
        let rightBottom = PaneID()

        var tree: PaneTree {
            .split(
                axis: .horizontal,
                ratio: 0.4,
                first: .split(
                    axis: .vertical,
                    ratio: 0.75,
                    first: .leaf(topLeft),
                    second: .leaf(bottomLeft)
                ),
                second: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        first: .leaf(middleTop),
                        second: .leaf(middleBottom)
                    ),
                    second: .split(
                        axis: .vertical,
                        ratio: 0.75,
                        first: .leaf(rightTop),
                        second: .leaf(rightBottom)
                    )
                )
            )
        }
    }

    /// One pane across the top and two side by side under it.
    private struct BannerOverTwo {
        let banner = PaneID()
        let left = PaneID()
        let right = PaneID()

        var tree: PaneTree {
            .split(
                axis: .vertical,
                ratio: 0.25,
                first: .leaf(banner),
                second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right))
            )
        }
    }

    /// The rect a layout gave one pane, or an empty rect when the pane is not in the
    /// layout at all. A missing pane then reads as a failed expectation instead of
    /// crashing the whole test run inside a force unwrap.
    private func rect(of pane: PaneID, in placed: [(pane: PaneID, rect: LayoutRect)]) -> LayoutRect {
        placed.first { $0.pane == pane }?.rect ?? LayoutRect(x: 0, y: 0, width: 0, height: 0)
    }

    @Test func aSinglePaneFillsTheWholeRect() {
        let only = PaneID()
        let frame = LayoutRect(x: 10, y: 20, width: 800, height: 600)

        let placed = PaneTree.leaf(only).layout(in: frame)

        #expect(placed.count == 1)
        #expect(placed[0].pane == only)
        #expect(placed[0].rect == frame)
    }

    @Test func aHorizontalSplitGivesTheFirstPaneTheLeftFraction() {
        let left = PaneID()
        let right = PaneID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.25, first: .leaf(left), second: .leaf(right))

        let placed = tree.layout(in: LayoutRect(x: 0, y: 0, width: 800, height: 600))

        #expect(rect(of: left, in: placed) == LayoutRect(x: 0, y: 0, width: 200, height: 600))
        #expect(rect(of: right, in: placed) == LayoutRect(x: 200, y: 0, width: 600, height: 600))
    }

    @Test func aVerticalSplitGivesTheFirstPaneTheTopFraction() {
        let top = PaneID()
        let bottom = PaneID()
        let tree = PaneTree.split(axis: .vertical, ratio: 0.25, first: .leaf(top), second: .leaf(bottom))

        let placed = tree.layout(in: LayoutRect(x: 0, y: 0, width: 800, height: 600))

        // Top-left origin: the first child is the one with the smaller y. Under
        // AppKit's default coordinates this pair would be the other way round, which
        // is the flip the view layer owns.
        #expect(rect(of: top, in: placed) == LayoutRect(x: 0, y: 0, width: 800, height: 150))
        #expect(rect(of: bottom, in: placed) == LayoutRect(x: 0, y: 150, width: 800, height: 450))
    }

    @Test func nestedSplitsTileTheRectWithoutAGapOrAnOverlap() {
        let panes = UnevenColumns()

        let placed = panes.tree.layout(in: .unit)

        #expect(placed.count == 4)
        #expect(rect(of: panes.topLeft, in: placed) == LayoutRect(x: 0, y: 0, width: 0.5, height: 0.75))
        #expect(rect(of: panes.bottomLeft, in: placed) == LayoutRect(x: 0, y: 0.75, width: 0.5, height: 0.25))
        #expect(rect(of: panes.topRight, in: placed) == LayoutRect(x: 0.5, y: 0, width: 0.5, height: 0.25))
        #expect(rect(of: panes.bottomRight, in: placed) == LayoutRect(x: 0.5, y: 0.25, width: 0.5, height: 0.75))
    }

    @Test func layoutClampsARatioOfZeroSoNeitherPaneIsInvisible() {
        let first = PaneID()
        let second = PaneID()
        // A stored 0 is what a hand-edited session file or a bad divider drag leaves
        // behind, and `layout` is the last place it can be caught before a pane with
        // no width is handed to the view layer with a live shell in it.
        let tree = PaneTree.split(axis: .horizontal, ratio: 0, first: .leaf(first), second: .leaf(second))

        let placed = tree.layout(in: .unit)

        #expect(rect(of: first, in: placed).width == 0.05)
        #expect(rect(of: second, in: placed).x == 0.05)
        #expect(rect(of: second, in: placed).width > 0.9)
    }

    @Test func layoutClampsARatioOfOneSoNeitherPaneIsInvisible() {
        let first = PaneID()
        let second = PaneID()
        let tree = PaneTree.split(axis: .vertical, ratio: 1, first: .leaf(first), second: .leaf(second))

        let placed = tree.layout(in: .unit)

        #expect(rect(of: first, in: placed).height == 0.95)
        #expect(rect(of: second, in: placed).y == 0.95)
        #expect(rect(of: second, in: placed).height > 0)
    }

    @Test func layoutTreatsANonFiniteRatioAsAnEvenSplit() {
        let first = PaneID()
        let second = PaneID()
        // NaN cannot be clamped: `min` and `max` propagate it, so a clamp that only
        // bounded the range would hand both panes a NaN size, and a NaN frame lays
        // out as nothing at all rather than as a small pane.
        let notANumber = PaneTree.split(
            axis: .horizontal,
            ratio: Double.nan,
            first: .leaf(first),
            second: .leaf(second)
        )
        let infinite = PaneTree.split(
            axis: .horizontal,
            ratio: .infinity,
            first: .leaf(first),
            second: .leaf(second)
        )

        #expect(rect(of: first, in: notANumber.layout(in: .unit)).width == 0.5)
        #expect(rect(of: second, in: notANumber.layout(in: .unit)).width == 0.5)
        #expect(rect(of: first, in: infinite.layout(in: .unit)).width == 0.5)
        #expect(rect(of: second, in: infinite.layout(in: .unit)).width == 0.5)
    }

    @Test func focusCrossesToThePaneWhoseSpanOverlaps() {
        let panes = UnevenColumns()
        // The bottom-left pane spans the last quarter of the window, which only the
        // bottom-right pane reaches. A tree walk crosses to the right column and
        // takes its first child, the top-right pane, and so does walking `paneIDs`
        // in order. This is the test the whole rect layout exists for.
        #expect(panes.tree.neighbour(of: panes.bottomLeft, direction: .right, in: .unit) == panes.bottomRight)
    }

    @Test func focusCrossesTheDividerBothWays() {
        let panes = UnevenColumns()
        // The plain case, where the pane across the divider is the only candidate whose
        // span reaches the source at all.
        #expect(panes.tree.neighbour(of: panes.topRight, direction: .left, in: .unit) == panes.topLeft)
        #expect(panes.tree.neighbour(of: panes.topLeft, direction: .right, in: .unit) == panes.topRight)
    }

    @Test func aTieOnTheDividerGoesToTheNearestPerpendicularEdge() {
        let panes = ThreeUnevenColumns()
        // Both right-column panes touch the divider, so both score a gap of 0. The
        // bottom one's top edge is a quarter of the window from the source's and the top
        // one's is half of it, and the bottom one comes last in visual order. Taking the
        // first candidate that shares the divider would answer with the top one.
        #expect(panes.tree.neighbour(of: panes.middleBottom, direction: .right, in: .unit) == panes.rightBottom)
    }

    @Test func theNearerPaneWinsOverTheOneWhoseEdgeLinesUpBetter() {
        let panes = ThreeUnevenColumns()
        // The bottom-right pane starts at exactly the source's own top edge, so it wins
        // the perpendicular offset outright, and it is a whole column away. The middle
        // column's lower pane is the one the user can see next to the source. Gap first,
        // offset only to break a tie, in that order.
        #expect(panes.tree.neighbour(of: panes.bottomLeft, direction: .right, in: .unit) == panes.middleBottom)
    }

    @Test func aFullWidthPaneIsFoundFromBothPanesUnderIt() {
        let panes = BannerOverTwo()
        #expect(panes.tree.neighbour(of: panes.left, direction: .up, in: .unit) == panes.banner)
        #expect(panes.tree.neighbour(of: panes.right, direction: .up, in: .unit) == panes.banner)
    }

    @Test func movingDownFromAFullWidthPanePicksTheLeftOfTheTwoBelowIt() {
        let panes = BannerOverTwo()
        // Both panes below share the divider, so the tie falls to the one whose left
        // edge lines up with the source's.
        #expect(panes.tree.neighbour(of: panes.banner, direction: .down, in: .unit) == panes.left)
    }

    @Test func nothingSitsBesideOrAboveTheFullWidthPane() {
        let panes = BannerOverTwo()
        // Nothing is beside the banner, though two panes come after it in `paneIDs`.
        // An order-based cycle would answer with one of them, which is why cmd+alt
        // arrows and the cycle key are separate operations.
        #expect(panes.tree.neighbour(of: panes.banner, direction: .left, in: .unit) == nil)
        #expect(panes.tree.neighbour(of: panes.banner, direction: .right, in: .unit) == nil)
        #expect(panes.tree.neighbour(of: panes.banner, direction: .up, in: .unit) == nil)
    }

    @Test func everyDirectionFromTheOnlyPaneIsNil() {
        let only = PaneID()
        let tree = PaneTree.leaf(only)
        #expect(tree.neighbour(of: only, direction: .left, in: .unit) == nil)
        #expect(tree.neighbour(of: only, direction: .right, in: .unit) == nil)
        #expect(tree.neighbour(of: only, direction: .up, in: .unit) == nil)
        #expect(tree.neighbour(of: only, direction: .down, in: .unit) == nil)
    }

    @Test func everyOutwardDirectionAtTheEdgesOfTheLayoutIsNil() {
        let panes = UnevenColumns()
        let tree = panes.tree
        #expect(tree.neighbour(of: panes.topLeft, direction: .left, in: .unit) == nil)
        #expect(tree.neighbour(of: panes.topLeft, direction: .up, in: .unit) == nil)
        #expect(tree.neighbour(of: panes.bottomRight, direction: .right, in: .unit) == nil)
        #expect(tree.neighbour(of: panes.bottomRight, direction: .down, in: .unit) == nil)
        #expect(tree.neighbour(of: panes.bottomLeft, direction: .down, in: .unit) == nil)
        #expect(tree.neighbour(of: panes.topRight, direction: .up, in: .unit) == nil)
    }

    @Test func aPaneThatIsNotInTheTreeHasNoNeighbour() {
        let panes = UnevenColumns()
        #expect(panes.tree.neighbour(of: PaneID(), direction: .left, in: .unit) == nil)
    }

    @Test func theAnswerIsTheSameForAWindowSizedRectAsForTheUnitRect() {
        let panes = UnevenColumns()
        // What licenses ``Workspace`` to resolve arrow keys against the unit rect
        // instead of threading a window frame through every menu action. The frame
        // here is offset as well as scaled, since a window on a second display has a
        // non-zero origin.
        let frame = LayoutRect(x: 120, y: -400, width: 1680, height: 1050)
        #expect(panes.tree.neighbour(of: panes.bottomLeft, direction: .right, in: frame) == panes.bottomRight)
        #expect(panes.tree.neighbour(of: panes.bottomRight, direction: .left, in: frame) == panes.topLeft)
        #expect(panes.tree.neighbour(of: panes.topLeft, direction: .left, in: frame) == nil)
    }
}
