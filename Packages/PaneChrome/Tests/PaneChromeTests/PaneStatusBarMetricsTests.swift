import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneStatusBarMetricsTests {
    @Test func theBarHeightDoesNotDependOnFocus() {
        // The most important assertion in this package. A focused bar that is
        // even one point taller shrinks the terminal view above it, ghostty
        // reflows the grid, and the pane's child process takes a SIGWINCH:
        // moving focus would reflow a running agent's output. `reservedHeight`
        // takes the focus flag purely so this test has a branch to catch, and
        // it fails the moment that body starts reading the flag.
        #expect(PaneStatusBarMetrics.reservedHeight(focused: true)
            == PaneStatusBarMetrics.reservedHeight(focused: false))
        #expect(PaneStatusBarMetrics.reservedHeight(focused: true) == PaneStatusBarMetrics.height)
    }

    @Test func theBaselineLeavesRoomForTheTallestSegmentAndTheHairline() {
        // Every segment is drawn on one baseline rather than centred
        // individually, because the bar now mixes four point sizes and two sizes
        // centred independently in 22 pt sit a quarter of a point apart, which
        // reads as a mistake rather than as a difference. The baseline has to sit
        // inside the height with the hairline still below it.
        #expect(PaneStatusBarMetrics.baselineFromTop < PaneStatusBarMetrics.height)
        #expect(PaneStatusBarMetrics.baselineFromTop + PaneStatusBarMetrics.hairlineHeight
            <= PaneStatusBarMetrics.height)
    }

    @Test func segmentsInOneGroupSitCloserThanSegmentsInTwo() {
        // Spacing is the only grouping device left once every tier shares a
        // baseline, so the two gaps have to be far enough apart to read as
        // deliberate. Equal values would collapse the bar back into one run of
        // words, which is the thing the tiers were introduced to fix.
        #expect(PaneStatusBarMetrics.spacingWithinGroup < PaneStatusBarMetrics.spacingBetweenGroups)
    }

    @Test func theSpacingHelperAgreesWithTheTwoConstants() {
        // The width solver and the drawing code both route through this, which is
        // what stops a bar from measuring as fitting and then drawing past its
        // own inset. When there was one constant they agreed for free.
        #expect(PaneStatusBarMetrics.spacing(from: .repository, to: .repository)
            == PaneStatusBarMetrics.spacingWithinGroup)
        #expect(PaneStatusBarMetrics.spacing(from: .identity, to: .repository)
            == PaneStatusBarMetrics.spacingBetweenGroups)
    }

    @Test func everyRoleBelongsToExactlyOneGroup() {
        // The mapping is derived from the role so that two call sites cannot
        // disagree about it. This is the assertion that a role added later was
        // actually placed in a group rather than left to fall through.
        let grouped = Dictionary(
            grouping: PaneStatusSegmentRole.allCases,
            by: { $0.group }
        )
        #expect(grouped[.identity]?.count == 2)
        #expect(grouped[.repository]?.count == 3)
        #expect(grouped[.agent]?.count == 1)
        #expect(grouped[.context]?.count == 1)
    }
}
