import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneChromeMetricsTests {
    /// The glass padding compensation is a live grid's worth of `SIGWINCH` if it
    /// ever moves: +11 is what held a real PTY at 82x23 in the glass-backdrop
    /// grid measurement, and +22 silently cost a row. The derivation
    /// (`paneBarHeight / 2`, symmetric key) is the doc's claim; the value is the
    /// measured one. Moving either is a reviewed diff against this failing, not a
    /// drive-by.
    ///
    /// This is the assertion that earns ``PaneChromeMetrics/paneBarHeight`` its
    /// place now that nothing draws a bar. The constant is not layout any more,
    /// it is the operand of this arithmetic.
    @Test func theGlassPaddingBumpStaysTheMeasuredHalfBar() {
        #expect(PaneChromeMetrics.glassWindowPaddingBump == PaneChromeMetrics.paneBarHeight / 2)
        #expect(PaneChromeMetrics.glassWindowPaddingBump == 11)
    }

    /// The pill's stroke is drawn inset by half its width, so it has to stay
    /// small enough that two of them do not meet in the middle of whatever band
    /// they enclose. Checked against the bar height because that is the
    /// narrowest chrome the stroke has ever been asked to sit inside, and a
    /// width that clears it clears the taller pill by construction.
    @Test func theFocusStrokeFitsInsideTheNarrowestChromeItIsDrawnIn() {
        #expect(PaneChromeMetrics.focusFrameWidth > 0)
        #expect(PaneChromeMetrics.focusFrameWidth * 2 < PaneChromeMetrics.paneBarHeight)
    }

    /// The two 8s are separate constants that happen to agree, and this test
    /// exists to state that the agreement is a coincidence rather than a
    /// coupling. If a later edit moves the pill's inset, this test failing is
    /// the wrong response — the right one is to delete the test, having checked
    /// that the probes still want the footer's 8.
    @Test func theFooterInsetAndThePillInsetAreSeparateConstants() {
        #expect(PaneChromeMetrics.paneBarHorizontalInset == PaneClusterMetrics.horizontalInset)
    }

    /// The capsule is concentric in the band it was drawn in, and the probes
    /// that rebuild the footer place their glyph off this frame rather than off
    /// a transcribed rectangle. That is the whole reason the geometry survived
    /// the bar: a transcription in a probe drifts from what shipped and the
    /// captures stop being comparable.
    @Test func theCapsuleIsConcentricInTheBarItWasDrawnIn() {
        let frame = PaneChromeMetrics.attentionCapsuleFrame(glyphWidth: 5)
        #expect(frame.y == 3)                                   // (22 - 16) / 2
        #expect(frame.height == 16)
        #expect(frame.x == PaneChromeMetrics.paneBarHorizontalInset)
    }

    @Test func aNarrowGlyphStillEarnsTheMinimumWidth() {
        #expect(PaneChromeMetrics.attentionCapsuleFrame(glyphWidth: 5).width == 21)
    }

    @Test func aWideGlyphGrowsTheCapsuleByItsPadding() {
        #expect(PaneChromeMetrics.attentionCapsuleFrame(glyphWidth: 20).width == 32)
    }

    /// The baseline sat inside the height with the hairline still below it. Kept
    /// because `footer-accessory` converts this baseline for an unflipped view
    /// and would draw its text outside the strip if the two constants crossed.
    @Test func theBaselineLeavesRoomForTheHairline() {
        #expect(PaneChromeMetrics.paneBarBaselineFromTop < PaneChromeMetrics.paneBarHeight)
        #expect(PaneChromeMetrics.paneBarBaselineFromTop + PaneChromeMetrics.paneBarHairlineHeight
            <= PaneChromeMetrics.paneBarHeight)
    }
}
