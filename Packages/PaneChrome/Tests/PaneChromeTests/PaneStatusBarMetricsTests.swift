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

    @Test func theFocusFrameFitsInsideTheHeightItMayNotChange() {
        // The frame is inset *within* the 22 pt rather than added to it, so the
        // only thing between it and a resized ghostty grid is that the two
        // strokes stay smaller than the band they are drawn in.
        #expect(PaneStatusBarMetrics.focusFrameWidth * 2 < PaneStatusBarMetrics.height)

        // The bottom stroke has to stop above the baseline, or the frame crosses
        // the text instead of enclosing it. This is as far as the package can
        // check: how far the descenders fall below that baseline is a font
        // metric the app owns, and `PaneChrome` has no AppKit to ask. A width
        // that clears this and still swallows the text is possible, and would
        // have to be caught by looking at the app.
        #expect(PaneStatusBarMetrics.height - PaneStatusBarMetrics.focusFrameWidth
            > PaneStatusBarMetrics.baselineFromTop)
    }

    @Test func aNarrowBarDropsItsSideEdgesAndBecomesABracket() {
        // A frame on a short bar reads as a chip rather than as a band: the
        // rectangle stops being wide enough for enclosure to be the shape the
        // eye resolves, and starts looking like a button, which is the one thing
        // nothing in a pane may look like.
        #expect(PaneStatusBarMetrics.framesSides(atWidth: 400))
        #expect(PaneStatusBarMetrics.framesSides(atWidth: 120))
        #expect(!PaneStatusBarMetrics.framesSides(atWidth: 119))
        #expect(!PaneStatusBarMetrics.framesSides(atWidth: 0))
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

    @Test func leadingReservesRoomForThePinChipAndTheBusyDot() {
        // The pin chip always reserves its padding; the busy dot only reserves
        // space while it is actually drawn, since an idle agent segment has
        // nothing there to make room for. Every other role starts flush.
        #expect(PaneStatusBarMetrics.leading(for: .pin, busy: false, chipPadding: 4, busyDotAdvance: 10) == 4)
        #expect(PaneStatusBarMetrics.leading(for: .pin, busy: true, chipPadding: 4, busyDotAdvance: 10) == 4)
        #expect(PaneStatusBarMetrics.leading(for: .agent, busy: true, chipPadding: 4, busyDotAdvance: 10) == 10)
        #expect(PaneStatusBarMetrics.leading(for: .agent, busy: false, chipPadding: 4, busyDotAdvance: 10) == 0)
        #expect(PaneStatusBarMetrics.leading(for: .branch, busy: true, chipPadding: 4, busyDotAdvance: 10) == 0)
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

    @Test func theCapsuleIsConcentricInTheBar() {
        let frame = PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 5)
        #expect(frame.y == 3)                                   // (22 - 16) / 2
        #expect(frame.height == 16)
        #expect(frame.x == PaneStatusBarMetrics.horizontalInset)
    }

    @Test func aNarrowGlyphStillEarnsTheMinimumWidth() {
        #expect(PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 5).width == 21)
    }

    @Test func aWideGlyphGrowsTheCapsuleByItsPadding() {
        #expect(PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 20).width == 32)
    }

    @Test func onlyTheCapsuleLevelsAdvanceTheSegments() {
        let advance = { (a: PaneStatus.Attention) in
            PaneStatusBarMetrics.attentionLeadingAdvance(
                for: a, glyphWidth: 5, doneGlyphWidth: 7
            )
        }
        #expect(advance(.none) == 0)
        #expect(advance(.asking) == 27)        // capsule 21 + gap 6
        #expect(advance(.acknowledged) == 27)
        #expect(advance(.done) == 13)          // bare glyph 7 + gap 6
    }
}
