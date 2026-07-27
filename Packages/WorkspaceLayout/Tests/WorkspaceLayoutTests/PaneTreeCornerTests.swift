import Foundation
import Testing

@testable import WorkspaceLayout

@Suite struct PaneTreeCornerTests {
    /// The owner's real arrangement: three columns of two rows each.
    private struct Grid2x3 {
        let topLeft = PaneID()
        let bottomLeft = PaneID()
        let topMiddle = PaneID()
        let bottomMiddle = PaneID()
        let topRight = PaneID()
        let bottomRight = PaneID()

        private func column(_ top: PaneID, _ bottom: PaneID) -> PaneTree {
            .split(axis: .vertical, ratio: 0.5, first: .leaf(top), second: .leaf(bottom))
        }

        var tree: PaneTree {
            .split(
                axis: .horizontal,
                ratio: 1.0 / 3.0,
                first: column(topLeft, bottomLeft),
                second: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    first: column(topMiddle, bottomMiddle),
                    second: column(topRight, bottomRight)
                )
            )
        }
    }

    @Test func aSinglePaneOwnsBothBottomCorners() {
        let only = PaneID()
        #expect(PaneTree.leaf(only).bottomCorners(of: only) == .both)
    }

    @Test func aStackedSplitGivesTheBottomPaneBothCornersAndTheTopPaneNone() {
        let top = PaneID()
        let bottom = PaneID()
        let tree = PaneTree.split(axis: .vertical, ratio: 0.5, first: .leaf(top), second: .leaf(bottom))

        #expect(tree.bottomCorners(of: bottom) == .both)
        #expect(tree.bottomCorners(of: top) == [])
    }

    @Test func aSideBySideSplitGivesEachPaneOneCorner() {
        let left = PaneID()
        let right = PaneID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right))

        #expect(tree.bottomCorners(of: left) == .left)
        #expect(tree.bottomCorners(of: right) == .right)
    }

    /// The shape the whole feature exists for. The middle column is the case a
    /// naive "is this pane on the bottom row" test gets wrong: it meets the
    /// window's bottom edge and neither of its sides.
    @Test func aGridGivesTheOutsideBottomPanesOneCornerEachAndTheMiddleNone() {
        let grid = Grid2x3()
        let corners = grid.tree.bottomCorners()

        #expect(corners[grid.bottomLeft] == .left)
        #expect(corners[grid.bottomRight] == .right)
        #expect(corners[grid.bottomMiddle] == [])
    }

    /// The bottom edge alone is not enough, and neither is a side alone.
    @Test func topRowPanesOwnNothingEvenAtTheWindowSides() {
        let grid = Grid2x3()
        let corners = grid.tree.bottomCorners()

        #expect(corners[grid.topLeft] == [])
        #expect(corners[grid.topMiddle] == [])
        #expect(corners[grid.topRight] == [])
    }

    /// Every pane is named, including the ones that own nothing, so a caller can
    /// push a value to each pane it has rather than deciding what a missing key
    /// meant.
    @Test func theMapNamesEveryPane() {
        let grid = Grid2x3()
        let corners = grid.tree.bottomCorners()

        #expect(Set(corners.keys) == Set(grid.tree.paneIDs))
    }

    /// Nesting depth must not change the answer. Three levels of splits leaning
    /// right still put exactly one pane in each bottom corner of the window.
    @Test func deepNestingStillNamesOnePanePerCorner() {
        let ids = (0 ..< 4).map { _ in PaneID() }
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(ids[0]),
            second: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(ids[1]),
                second: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(ids[2]),
                    second: .leaf(ids[3])
                )
            )
        )
        let corners = tree.bottomCorners()

        #expect(corners.filter { $0.value.contains(.left) }.map(\.key) == [ids[0]])
        #expect(corners.filter { $0.value.contains(.right) }.map(\.key) == [ids[3]])
        #expect(corners[ids[1]] == [])
        #expect(corners[ids[2]] == [])
    }

    /// A chain of ratios that are not binary fractions leaves the far edge of the
    /// last pane a unit in the last place away from the window's, and an `==` on
    /// the edges would take the corner off the pane that visibly owns it.
    ///
    /// 0.3 then 0.2 on each axis is the smallest arrangement that drifts: the
    /// pane's `maxX` and `maxY` both land on 0.9999999999999999 rather than on 1.
    /// A third, which is the ratio the owner's grid actually uses, happens to
    /// come out exact, so it would have made this test pass for the wrong reason.
    ///
    /// The first expectation is what keeps this honest: it asserts the drift is
    /// really there. If some future change to ``PaneTree/layout(in:)`` makes the
    /// arithmetic exact, this fails rather than passing for free, and the next
    /// reader learns the case has stopped pinning anything.
    @Test func roundingDoesNotCostAPaneTheCornerItTouches() {
        let ids = (0 ..< 5).map { _ in PaneID() }
        let drifting = PaneTree.split(
            axis: .horizontal,
            ratio: 0.3,
            first: .leaf(ids[0]),
            second: .split(
                axis: .horizontal,
                ratio: 0.2,
                first: .leaf(ids[1]),
                second: .split(
                    axis: .vertical,
                    ratio: 0.3,
                    first: .leaf(ids[2]),
                    second: .split(
                        axis: .vertical,
                        ratio: 0.2,
                        first: .leaf(ids[3]),
                        second: .leaf(ids[4])
                    )
                )
            )
        )
        let placed = drifting.layout(in: .unit)
        let last = placed.first { $0.pane == ids[4] }!.rect
        #expect(last.maxX != LayoutRect.unit.maxX)
        #expect(last.maxY != LayoutRect.unit.maxY)

        #expect(drifting.bottomCorners(of: ids[4]) == .right)
        #expect(drifting.bottomCorners(of: ids[0]) == .left)
        #expect(drifting.bottomCorners(of: ids[1]) == [])
        #expect(drifting.bottomCorners(of: ids[3]) == [])
    }

    /// The other side of the tolerance. A pane that stops short of an edge by a
    /// gap small enough to be a rounding artefact but large enough to see must
    /// not be handed the corner: at 0.0025 of a 1400 pt window that gap is three
    /// and a half points of another pane.
    @Test func aRealGapIsNotSwallowedByTheTolerance() {
        let wide = PaneID()
        let sliver = PaneID()
        let slice = PaneID()
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.95,
            first: .leaf(wide),
            second: .split(axis: .horizontal, ratio: 0.95, first: .leaf(sliver), second: .leaf(slice))
        )

        #expect(tree.bottomCorners(of: sliver) == [])
        #expect(tree.bottomCorners(of: wide) == .left)
        #expect(tree.bottomCorners(of: slice) == .right)
    }

    /// A pane that is not in the tree owns nothing, so a stale id arriving after
    /// its pane closed rounds no corner rather than rounding an arbitrary one.
    @Test func anAbsentPaneOwnsNothing() {
        #expect(PaneTree.leaf(PaneID()).bottomCorners(of: PaneID()) == [])
    }

    /// Ownership is a property of the arrangement, not of the window size, so the
    /// answer is the same against a real frame as against the unit rect the
    /// callers use.
    @Test func theAnswerDoesNotDependOnTheSizeOfTheWindow() {
        let grid = Grid2x3()
        let large = LayoutRect(x: 0, y: 0, width: 1680, height: 1050)
        let offset = LayoutRect(x: 120, y: 64, width: 900, height: 600)

        for rect in [LayoutRect.unit, large, offset] {
            #expect(grid.tree.bottomCorners(of: grid.bottomLeft, in: rect) == .left)
            #expect(grid.tree.bottomCorners(of: grid.bottomRight, in: rect) == .right)
            #expect(grid.tree.bottomCorners(of: grid.bottomMiddle, in: rect) == [])
            #expect(grid.tree.bottomCorners(of: grid.topLeft, in: rect) == [])
        }
    }
}
