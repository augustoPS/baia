import Foundation
import PaneControl
import Testing

@testable import WorkspaceLayout

@Suite struct FocusDirectionTests {
    /// One assertion per ``ControlDirection`` case. `direction(of:)` has no
    /// `default:` arm, matching the wire enum exactly, so a fifth case added to
    /// either side has to be mapped here before anything compiles again — the
    /// exact shape the `--kinds` mapping got wrong the first time it moved.
    @Test func mapsEveryControlDirectionToItsFocusDirection() {
        #expect(FocusDirection.direction(of: .left) == .left)
        #expect(FocusDirection.direction(of: .right) == .right)
        #expect(FocusDirection.direction(of: .up) == .up)
        #expect(FocusDirection.direction(of: .down) == .down)
    }


    /// Half the window, on the left.
    private let source = LayoutRect(x: 0, y: 0, width: 0.5, height: 0.5)

    @Test func aPaneSharingTheDividerScoresNoGap() {
        let touching = LayoutRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        #expect(FocusDirection.right.reach(from: source, to: touching)?.gap == 0)
        #expect(FocusDirection.right.reach(from: source, to: touching)?.offset == 0)
    }

    @Test func aPaneBehindAnotherScoresTheGapBetweenThem() {
        let far = LayoutRect(x: 0.75, y: 0, width: 0.25, height: 0.5)
        // Measured to the candidate's near edge, not to its middle: a wide pane and a
        // narrow one starting at the same place are the same distance away.
        #expect(FocusDirection.right.reach(from: source, to: far)?.gap == 0.25)
    }

    @Test func aPaneInTheOppositeDirectionIsNotAReach() {
        let behind = LayoutRect(x: -0.5, y: 0, width: 0.5, height: 0.5)
        #expect(FocusDirection.right.reach(from: source, to: behind) == nil)
        #expect(FocusDirection.left.reach(from: source, to: behind) != nil)
    }

    @Test func aPaneTouchingOnlyAtACornerIsNotAReach() {
        // Diagonally down and to the right, sharing exactly the point (0.5, 0.5).
        // Without the span check an arrow key could travel diagonally, which is the
        // one thing four separate directions exist to prevent. No pane tree can lay
        // this out, since a tree's rects always tile, so the rule is pinned here
        // rather than through ``PaneTree``.
        let diagonal = LayoutRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        #expect(FocusDirection.right.reach(from: source, to: diagonal) == nil)
        #expect(FocusDirection.down.reach(from: source, to: diagonal) == nil)
    }

    @Test func aPaneOverlappingBySomeOfItsSpanIsAReach() {
        // The mirror of the corner case: moved up by a hair so the spans genuinely
        // cross. The pair is what pins the span check to overlap rather than to
        // proximity, since either test alone passes whichever way the comparison goes.
        let overlapping = LayoutRect(x: 0.5, y: 0.4, width: 0.5, height: 0.5)
        #expect(FocusDirection.right.reach(from: source, to: overlapping) != nil)
    }

    @Test func edgesThatMissByRoundingCountAsTheSameEdge() {
        // A divider coordinate reached by multiplying ratios in a different order than
        // its neighbour's can miss the equality by a bit, and an arrow key that does
        // nothing at one particular window size is the worst kind of bug to report.
        let offByRounding = LayoutRect(x: 0.5 - 1e-13, y: 0, width: 0.5, height: 0.5)
        #expect(FocusDirection.right.reach(from: source, to: offByRounding) != nil)
    }

    @Test func spansThatOverlapByLessThanTheToleranceDoNotCount() {
        // The other side of the same number: a slice of the window a ten-thousandth of
        // a point tall is rounding, not a pane the user can see.
        let barelyOverlapping = LayoutRect(x: 0.5, y: 0.5 - 1e-13, width: 0.5, height: 0.5)
        #expect(FocusDirection.right.reach(from: source, to: barelyOverlapping) == nil)
    }

    @Test func upAndDownMeasureAgainstTheTopLeftOrigin() {
        let above = LayoutRect(x: 0, y: -0.5, width: 0.5, height: 0.5)
        let below = LayoutRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        // Up is towards the smaller y. Getting this backwards would send cmd+alt+up to
        // the pane underneath, which no test on a tree with one row would catch.
        #expect(FocusDirection.up.reach(from: source, to: above)?.gap == 0)
        #expect(FocusDirection.up.reach(from: source, to: below) == nil)
        #expect(FocusDirection.down.reach(from: source, to: below)?.gap == 0)
        #expect(FocusDirection.down.reach(from: source, to: above) == nil)
    }
}
