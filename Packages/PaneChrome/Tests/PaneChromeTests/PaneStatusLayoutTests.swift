import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneStatusLayoutTests {
    /// The bar width that leaves exactly `content` points between the insets, so
    /// a test can say how much room it is giving rather than doing the arithmetic
    /// in its head and getting the off-by-one wrong.
    private func barWidth(content: Double) -> Double {
        content + PaneStatusBarMetrics.horizontalInset * 2
    }

    /// The gap the solver will actually leave between two roles, which now
    /// depends on whether they answer the same question. Spelled as a call rather
    /// than a constant so a test states which pair it means and cannot quietly
    /// assume the wrong one of the two spacings.
    private func spacing(_ from: PaneStatusSegmentRole, _ to: PaneStatusSegmentRole) -> Double {
        PaneStatusBarMetrics.spacing(from: from.group, to: to.group)
    }

    private var inset: Double { PaneStatusBarMetrics.horizontalInset }

    @Test func mismatchedWidthCountsReturnAnEmptyResult() {
        // A measurement bug must not crash the app, and it must not silently
        // draw a bar built from the wrong widths either. Empty on both sides is
        // the only answer that is not a lie.
        let result = PaneStatusLayout.solve(
            segments: [Sample.segment(role: .anchorName), Sample.segment(role: .branch)],
            widths: [40],
            availableWidth: 400
        )
        #expect(result.placed.isEmpty)
        #expect(result.dropped.isEmpty)
    }

    @Test func everythingFitsWhenTheBarIsWideEnough() {
        let segments = [
            Sample.segment(role: .anchorName),
            Sample.segment(role: .branch),
            Sample.segment(role: .workingDirectory, alignment: .trailing),
        ]
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [40, 30, 60],
            availableWidth: 400
        )
        #expect(result.dropped.isEmpty)
        #expect(result.placed.map(\.segment.role) == [.anchorName, .branch, .workingDirectory])
    }

    @Test func leadingSegmentsRunFromTheInsetWithOneGapBetweenThem() {
        let result = PaneStatusLayout.solve(
            segments: [Sample.segment(role: .anchorName), Sample.segment(role: .branch)],
            widths: [40, 30],
            availableWidth: 400
        )
        #expect(result.placed.map(\.x) == [inset, inset + 40 + spacing(.anchorName, .branch)])
        #expect(result.placed.map(\.width) == [40, 30])
    }

    @Test func theTrailingClusterIsMeasuredFromTheRightEdgeLeftwards() {
        // Array order still reads left to right on screen: the agent label sits
        // to the left of the working directory, matching the table it was built
        // from. Measuring the cluster forwards instead would put the path
        // against the agent label and leave the gap on the wrong side.
        let segments = [
            Sample.segment(role: .agent, alignment: .trailing),
            Sample.segment(role: .workingDirectory, alignment: .trailing),
        ]
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [50, 70],
            availableWidth: barWidth(content: 300)
        )
        let rightEdge = barWidth(content: 300) - inset
        #expect(result.placed.map(\.segment.role) == [.agent, .workingDirectory])
        #expect(result.placed.map(\.x) == [
            rightEdge - 70 - spacing(.agent, .workingDirectory) - 50,
            rightEdge - 70,
        ])
    }

    @Test func theLowestPrioritySegmentDropsFirst() {
        let segments = [
            Sample.segment(role: .anchorName, priority: 100),
            Sample.segment(role: .branch, priority: 40),
            Sample.segment(role: .workingDirectory, alignment: .trailing, priority: 10),
        ]
        // 100 + 40 + 10 of text plus two gaps needs 166, and 148 without the
        // path. A content box of 160 therefore forces exactly one drop.
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [100, 40, 10],
            availableWidth: barWidth(content: 160)
        )
        #expect(result.dropped.map(\.role) == [.workingDirectory])
        #expect(result.placed.map(\.segment.role) == [.anchorName, .branch])
    }

    @Test func onlyAsManySegmentsAsNecessaryAreDropped() {
        // The solver re-measures after each drop instead of dropping until it
        // has room for the widest possible bar. Dropping the path alone is
        // enough here, and a solver that dropped down to the highest priority
        // would also pass theLowestPrioritySegmentDropsFirst.
        let segments = [
            Sample.segment(role: .anchorName, priority: 100),
            Sample.segment(role: .indicators, priority: 60),
            Sample.segment(role: .branch, priority: 40),
            Sample.segment(role: .workingDirectory, alignment: .trailing, priority: 10),
        ]
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [50, 20, 30, 90],
            availableWidth: barWidth(content: 130)
        )
        #expect(result.dropped.map(\.role) == [.workingDirectory])
    }

    @Test func theDropOrderIsDeterministicWhenTwoSegmentsSharePriority() {
        // Both segments have the same priority and the same width, so nothing
        // but the tie rule can decide. Run twice with the roles swapped: an
        // implementation that relied on sort stability, or on the role, would
        // agree with one of these and not the other.
        let pinFirst = PaneStatusLayout.solve(
            segments: [
                Sample.segment(role: .pin, priority: 80),
                Sample.segment(role: .operation, priority: 80),
            ],
            widths: [60, 60],
            availableWidth: barWidth(content: 100)
        )
        let operationFirst = PaneStatusLayout.solve(
            segments: [
                Sample.segment(role: .operation, priority: 80),
                Sample.segment(role: .pin, priority: 80),
            ],
            widths: [60, 60],
            availableWidth: barWidth(content: 100)
        )
        #expect(pinFirst.dropped.map(\.role) == [.operation])
        #expect(operationFirst.dropped.map(\.role) == [.pin])
    }

    @Test func aSegmentWiderThanTheBarIsPlacedAndTruncatedRatherThanDropped() {
        // A bar with nothing in it is worse than a clipped project name, and an
        // unnameable pane is the failure the bar exists to prevent. The width
        // comes back clamped to the content box so the app clips rather than
        // drawing past the inset.
        let result = PaneStatusLayout.solve(
            segments: [Sample.segment(role: .anchorName)],
            widths: [500],
            availableWidth: barWidth(content: 60)
        )
        #expect(result.dropped.isEmpty)
        #expect(result.placed.map(\.width) == [60])
        #expect(result.placed.map(\.x) == [inset])
    }

    @Test func placedRectanglesNeverOverlap() {
        // Both clusters at once, sized so the bar is nearly full. The two are
        // measured from opposite edges, so nothing but the fit check keeps the
        // last leading segment out of the first trailing one.
        let segments = [
            Sample.segment(role: .anchorName, priority: 100),
            Sample.segment(role: .branch, priority: 40),
            Sample.segment(role: .agent, alignment: .trailing, priority: 80),
            Sample.segment(role: .workingDirectory, alignment: .trailing, priority: 10),
        ]
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [40, 30, 50, 60],
            // Spelled as the sum rather than as a number, because the gaps are no
            // longer one constant times three. Writing 204 here again would say
            // the bar was full when it had in fact overflowed by a whole gap.
            availableWidth: barWidth(content: 40 + 30 + 50 + 60
                + spacing(.anchorName, .branch)
                + spacing(.branch, .agent)
                + spacing(.agent, .workingDirectory))
        )
        #expect(result.dropped.isEmpty)
        for (left, right) in zip(result.placed, result.placed.dropFirst()) {
            #expect(left.x + left.width <= right.x)
        }
    }

    @Test func placedRectanglesNeverOverlapWhenTheBarIsExactlyFull() {
        // The boundary case of placedRectanglesNeverOverlap: the widths and
        // gaps add up to the content box exactly, which is where a fit check
        // written with `<` instead of `<=` and a placement that forgot the gap
        // between the clusters both start overlapping.
        let segments = [
            Sample.segment(role: .anchorName, priority: 100),
            Sample.segment(role: .agent, alignment: .trailing, priority: 80),
        ]
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [40, 60],
            availableWidth: barWidth(content: 40 + 60 + spacing(.anchorName, .agent))
        )
        #expect(result.dropped.isEmpty)
        for (left, right) in zip(result.placed, result.placed.dropFirst()) {
            #expect(left.x + left.width <= right.x)
        }
    }

    @Test func twoSegmentsInOneGroupSitCloserThanTwoInDifferentGroups() {
        // The visible half of the grouping rule. A branch and its markers answer
        // the same question and read as one fact; the markers and the agent label
        // do not. With one spacing constant the bar read as a sentence when it is
        // a table, and spacing is the only device left to say so now that every
        // tier shares a baseline.
        let sameGroup = PaneStatusLayout.solve(
            segments: [Sample.segment(role: .branch), Sample.segment(role: .indicators)],
            widths: [40, 30],
            availableWidth: 400
        )
        let differentGroups = PaneStatusLayout.solve(
            segments: [Sample.segment(role: .anchorName), Sample.segment(role: .branch)],
            widths: [40, 30],
            availableWidth: 400
        )
        #expect(sameGroup.placed[1].x < differentGroups.placed[1].x)
        #expect(sameGroup.placed[1].x == inset + 40 + PaneStatusBarMetrics.spacingWithinGroup)
    }

    @Test func theFitCheckSumsTheGapsItIsAboutToAddRatherThanAssumingOne() {
        // With one constant, `spacing × (n − 1)` was the same number. With two it
        // is not, and a solver that assumed either would drop a segment that
        // fitted or place one past the inset, depending on how many groups
        // happened to survive. Three segments in one group is the case where
        // assuming the wide gap costs a segment that had room.
        let segments = [
            Sample.segment(role: .operation, priority: 80),
            Sample.segment(role: .branch, priority: 40),
            Sample.segment(role: .indicators, priority: 60),
        ]
        let exact = 30.0 * 3 + PaneStatusBarMetrics.spacingWithinGroup * 2
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [30, 30, 30],
            availableWidth: barWidth(content: exact)
        )
        #expect(result.dropped.isEmpty)
        #expect(result.placed.count == 3)
    }

    @Test func aNegativeMeasurementNeverBecomesANegativeWidth() {
        // A caller measuring an empty attributed string, or one whose font
        // failed to load, can hand back a negative width. Summed as it stands
        // it would make an overflowing bar report as fitting, and drawn as it
        // stands it is a rectangle with its edges crossed.
        let result = PaneStatusLayout.solve(
            segments: [Sample.segment(role: .anchorName), Sample.segment(role: .branch)],
            widths: [-40, 30],
            availableWidth: barWidth(content: 100)
        )
        #expect(result.placed.allSatisfy { $0.width >= 0 })
    }

    @Test func droppedSegmentsAreReportedInTheirOriginalOrder() {
        // The order they arrived in, not the order they were dropped in. The
        // app shows them in the pane's tooltip, where the bar's own order is
        // the one the owner recognises.
        let segments = [
            Sample.segment(role: .anchorName, priority: 100),
            Sample.segment(role: .indicators, priority: 20),
            Sample.segment(role: .branch, priority: 30),
            Sample.segment(role: .workingDirectory, alignment: .trailing, priority: 10),
        ]
        let result = PaneStatusLayout.solve(
            segments: segments,
            widths: [40, 40, 40, 40],
            availableWidth: barWidth(content: 45)
        )
        #expect(result.dropped.map(\.role) == [.indicators, .branch, .workingDirectory])
        #expect(result.placed.map(\.segment.role) == [.anchorName])
    }

    @Test func aBarNarrowerThanItsOwnInsetsPlacesNothing() {
        // A pane passes through this while the split view animates a divider to
        // the edge. Placing anything here means a rectangle outside the bar,
        // and reporting nothing dropped would tell the app the bar is complete.
        let result = PaneStatusLayout.solve(
            segments: [Sample.segment(role: .anchorName)],
            widths: [40],
            availableWidth: PaneStatusBarMetrics.horizontalInset * 2
        )
        #expect(result.placed.isEmpty)
        #expect(result.dropped.map(\.role) == [.anchorName])
    }

    @Test func noSegmentsPlaceNothingAndDropNothing() {
        let result = PaneStatusLayout.solve(segments: [], widths: [], availableWidth: 400)
        #expect(result.placed.isEmpty)
        #expect(result.dropped.isEmpty)
    }

    @Test func aRealStatusFitsOnATypicalHalfWidthPane() {
        // The end to end case: the segment table, measured at roughly seven
        // points a character, in half of a 1440 point window. Nothing should
        // drop there, and a priority table that dropped something in the
        // owner's normal working layout would be wrong however well it behaved
        // under pressure.
        let segments = PaneStatusSegments.build(from: Sample.everything())
        let widths = segments.map { Double($0.text.count) * 7 }
        let result = PaneStatusLayout.solve(segments: segments, widths: widths, availableWidth: 720)
        #expect(result.dropped.isEmpty)
        #expect(result.placed.count == segments.count)
    }
}
