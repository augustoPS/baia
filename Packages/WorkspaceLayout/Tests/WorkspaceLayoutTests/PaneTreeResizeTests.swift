import Foundation
import Testing

@testable import WorkspaceLayout

/// The keyboard resize: which divider a grow key moves, and by how much.
///
/// Separate from `PaneTreeTests` because every case here shares one question —
/// given a pane and an arrow, which split governs — and answering it wrong is
/// silent: the wrong divider moves, two panes the user never named change size,
/// and nothing reports an error.
@Suite struct PaneTreeResizeTests {
    /// Two columns, the right one split into two rows. `a` is the whole left
    /// column, so it has a divider to its right and none to its left, and `b`/`c`
    /// have a horizontal divider one level up and a vertical one between them.
    private struct Grid {
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

    /// The ratio a named split lays out at, or nil when the path names no split.
    private func ratio(_ tree: PaneTree?, _ path: SplitPath) -> Double? {
        tree?.ratio(at: path)
    }

    private func isNear(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        // 0.05 is not exact in binary, so a step added to a half is 0.55 only to
        // within a few ulps. Asserting on `==` would make every one of these tests
        // a test of floating point rather than of the walk.
        return abs(value - expected) < 1e-9
    }

    @Test func growingRightRaisesTheRatioOfTheSplitThePaneIsFirstIn() {
        let panes = Grid()
        let grown = panes.tree.adjustingRatio(forPane: panes.a, direction: .right, by: 0.05)

        // `first` is the left child, so the pane on the left grows by pushing the
        // divider away from the origin.
        #expect(isNear(ratio(grown, SplitPath()), 0.55))
        // And nothing else moved.
        #expect(isNear(ratio(grown, SplitPath([1])), 0.5))
    }

    @Test func growingLeftLowersTheRatioOfTheSplitThePaneIsSecondIn() {
        let panes = Grid()
        // `b` is inside the right column, which is the root split's second child,
        // so the divider on its left is the root's.
        let grown = panes.tree.adjustingRatio(forPane: panes.b, direction: .left, by: 0.05)

        #expect(isNear(ratio(grown, SplitPath()), 0.45))
        #expect(isNear(ratio(grown, SplitPath([1])), 0.5))
    }

    @Test func theLeftmostPaneGrowingLeftIsNil() {
        let panes = Grid()
        // `a` is the whole left column: no split on its path has a divider to its
        // left. Nil rather than moving some ancestor, which is the failure this
        // pins: an ancestor divider that is not the one the user is looking at.
        #expect(panes.tree.adjustingRatio(forPane: panes.a, direction: .left, by: 0.05) == nil)
    }

    @Test func theTopmostPaneGrowingUpIsNil() {
        let panes = Grid()
        // `b` is the top row of the right column. The vertical split holding it
        // has its divider below, and the only other split on the path is
        // horizontal, so up names nothing.
        #expect(panes.tree.adjustingRatio(forPane: panes.b, direction: .up, by: 0.05) == nil)
    }

    @Test func aDirectionWithNoMatchingAxisAnywhereOnThePathIsNil() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        // Two horizontal splits and nothing else, so neither up nor down can move
        // anything at all.
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )

        #expect(tree.adjustingRatio(forPane: b, direction: .up, by: 0.05) == nil)
        #expect(tree.adjustingRatio(forPane: b, direction: .down, by: 0.05) == nil)
        #expect(tree.adjustingRatio(forPane: a, direction: .down, by: 0.05) == nil)
    }

    @Test func growingPicksTheDeepestMatchingSplitOnThePathNotTheRoot() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        // Two horizontal splits on one spine. `b` sits in `first` of the inner one
        // and in `second` of the root, so growing right qualifies only at the
        // inner split while growing left qualifies only at the root. The inner one
        // is the divider touching `b`'s edge; moving the root instead would resize
        // `a` and the whole right column, neither of which the user pointed at.
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.4,
            first: .leaf(a),
            second: .split(axis: .horizontal, ratio: 0.6, first: .leaf(b), second: .leaf(c))
        )

        let grown = tree.adjustingRatio(forPane: b, direction: .right, by: 0.05)
        #expect(isNear(ratio(grown, SplitPath([1])), 0.65))
        #expect(isNear(ratio(grown, SplitPath()), 0.4))
    }

    @Test func growingPicksTheDeepestMatchingSplitFromTwoLevelsDown() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        let d = PaneID()
        // Three levels, alternating axes, with `d` at the bottom. Growing up has
        // exactly one candidate, the vertical split two levels down, and the walk
        // has to cross a horizontal split to reach it without stopping there.
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(b),
                second: .split(axis: .vertical, ratio: 0.5, first: .leaf(c), second: .leaf(d))
            )
        )

        let grown = tree.adjustingRatio(forPane: d, direction: .up, by: 0.05)
        #expect(isNear(ratio(grown, SplitPath([1, 1])), 0.45))
        #expect(isNear(ratio(grown, SplitPath([1])), 0.5))
        #expect(isNear(ratio(grown, SplitPath()), 0.5))
    }

    @Test func theStepIsAFractionSoAWideAndANarrowSplitMoveByTheSameProportion() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        // The right column is half the window, so the nested split is half the
        // thickness of the root one. A step in points would move the two dividers
        // by the same number of points and therefore by different proportions,
        // which reads as the key doing more in a small pane than a large one.
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        let window = LayoutRect(x: 0, y: 0, width: 1000, height: 600)

        func width(_ tree: PaneTree?, _ pane: PaneID) -> Double {
            tree?.layout(in: window).first { $0.pane == pane }?.rect.width ?? -1
        }

        let wide = tree.adjustingRatio(forPane: a, direction: .right, by: 0.05)
        let narrow = tree.adjustingRatio(forPane: b, direction: .right, by: 0.05)

        // The root split spans the window's 1000, the nested one 500, so the same
        // command moves 50 points at the top and 25 points one level down.
        #expect(abs(width(wide, a) - (500 + 50)) < 1e-9)
        #expect(abs(width(narrow, b) - (250 + 25)) < 1e-9)
        // Same fraction of each split's own thickness, which is the invariant the
        // point figures above are only an illustration of.
        #expect(isNear(ratio(wide, SplitPath()), 0.55))
        #expect(isNear(ratio(narrow, SplitPath([1])), 0.55))
    }

    @Test func repeatedGrowsStopAtTheClampRatherThanWalkingPastIt() {
        let a = PaneID()
        let b = PaneID()
        var tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))

        // `b`, not `a`. `a` is the first child, so it has no divider to its left
        // at all and growing it left is the nil case `theLeftmostPaneGrowingLeft`
        // pins; this loop would have run zero times and asserted nothing. `b` is
        // the second child, so growing it left walks the ratio down towards the
        // clamp, which is the direction the assertions below are written for.
        //
        // Bounded so a walk that never converges fails as a wrong count rather
        // than hanging the suite.
        var presses = 0
        while presses < 50, let grown = tree.adjustingRatio(forPane: b, direction: .left, by: 0.05) {
            tree = grown
            presses += 1
        }

        // It stopped, it stopped at the bound `clampedRatio` enforces, and it did
        // so in about the nine presses 0.05 steps take to cross from a half. One
        // extra press is allowed for the last one landing a few ulps off the bound
        // and being clamped onto it.
        #expect(presses <= 10)
        #expect(tree.ratio(at: SplitPath()) == 0.05)
        // And staying there is a refusal, not a silent no-op tree: the caller uses
        // nil to skip the session write and the divider push.
        #expect(tree.adjustingRatio(forPane: b, direction: .left, by: 0.05) == nil)
    }

    @Test func aPaneThatIsNotInTheTreeGrowsNothing() {
        let panes = Grid()
        // A key arriving after the pane closed must move no divider at all rather
        // than the nearest one.
        #expect(panes.tree.adjustingRatio(forPane: PaneID(), direction: .right, by: 0.05) == nil)
        #expect(PaneTree.leaf(panes.a).adjustingRatio(forPane: panes.a, direction: .right, by: 0.05) == nil)
    }

    /// The rule stated where it is visible, and the case that rejected weighting by
    /// leaves.
    ///
    /// A column of three between two single panes. Weighting by leaves gives every
    /// pane the same area and makes that middle column three times as wide as its
    /// neighbours, which is what shipped for about an hour on 2026-07-31 and was
    /// rejected on sight. Evening out siblings makes all three columns a third.
    @Test func equalizedEvensColumnsRatherThanPanes() {
        let tall = PaneID()
        let stacked = (top: PaneID(), middle: PaneID(), bottom: PaneID())
        let other = PaneID()
        let column = PaneTree.split(
            axis: .vertical,
            ratio: 0.8,
            first: .leaf(stacked.top),
            second: .split(axis: .vertical, ratio: 0.1, first: .leaf(stacked.middle), second: .leaf(stacked.bottom))
        )
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.2,
            first: .leaf(tall),
            second: .split(axis: .horizontal, ratio: 0.9, first: column, second: .leaf(other))
        )

        let laid = tree.equalized.layout(in: LayoutRect(x: 0, y: 0, width: 900, height: 900))
        let width = Dictionary(uniqueKeysWithValues: laid.map { ($0.pane, $0.rect.width) })
        let height = Dictionary(uniqueKeysWithValues: laid.map { ($0.pane, $0.rect.height) })

        // Three columns of the same width, whatever is inside them.
        #expect(width[tall] == 300)
        #expect(width[stacked.top] == 300)
        #expect(width[other] == 300)
        // And the column divides its own third between its three.
        #expect(height[tall] == 900)
        #expect(height[stacked.top] == 300)
        #expect(height[stacked.middle] == 300)
        #expect(height[stacked.bottom] == 300)
    }

    /// Three side by side, which is the arrangement that made this a defect. They
    /// nest as `a | (b | c)`, so halving every split gave a half and two quarters
    /// and the key handed back the shape it was pressed to undo.
    @Test func equalizedMakesThreeSideBySideThirds() {
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(PaneID()),
            second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneID()), second: .leaf(PaneID()))
        )

        let widths = tree.equalized
            .layout(in: LayoutRect(x: 0, y: 0, width: 900, height: 900))
            .map { $0.rect.width }

        #expect(widths == [300, 300, 300])
    }

    /// A tree where the answer is halves all the way down, and it is worth pinning
    /// because it is the answer the old rule gave for the wrong reason. Every split
    /// here has one slot on each side: a pane against a column, then a pane against
    /// a row, then a pane against a pane.
    @Test func equalizedIsHalvesWhenEverySplitHasOneSlotEachSide() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        let d = PaneID()
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.2,
            first: .leaf(a),
            second: .split(
                axis: .vertical,
                ratio: 0.9,
                first: .leaf(b),
                second: .split(axis: .horizontal, ratio: 0.3, first: .leaf(c), second: .leaf(d))
            )
        )

        let even = tree.equalized

        #expect(even == .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(b),
                second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(c), second: .leaf(d))
            )
        ))
        // Axes and pane order are untouched: equalizing is not a reshuffle.
        #expect(even.paneIDs == tree.paneIDs)
    }

    /// Idempotent, which is what makes the second press a refusal.
    ///
    /// Stated as equalizing twice rather than against a hand-written tree, because
    /// "already even" is the rule's own output and writing it out again here would
    /// only assert that two copies of the arithmetic agree.
    @Test func equalizingAnAlreadyEvenTreeChangesNothing() {
        let panes = Grid()
        // A pane beside a column is already even at halves, so this one is
        // untouched outright.
        #expect(panes.tree.equalized == panes.tree)
        #expect(PaneTree.leaf(panes.a).equalized == .leaf(panes.a))

        // Idempotence on a tree that does move, so the line above is not the only
        // evidence: three side by side even to thirds and stay there.
        let spine = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(PaneID()),
            second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneID()), second: .leaf(PaneID()))
        )
        #expect(spine.equalized != spine)
        #expect(spine.equalized.equalized == spine.equalized)
    }

    @Test func theKeyboardStepDividesTheClampRangeWithNothingLeftOver() {
        // Eighteen steps from a half reach either bound exactly, so a held key
        // stops on the stop rather than a step short of it with a remainder that
        // can never be spent. The count is whatever the step makes it; what this
        // pins is that the division comes out whole.
        let span = 0.5 - PaneTree.clampedRatio(0)
        let steps = span / PaneTree.keyboardResizeStep
        #expect(abs(steps - steps.rounded()) < 1e-9)
    }
}
