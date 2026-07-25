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

    @Test func theAccentStripeAndTheHairlineFitInsideTheBarHeight() {
        // The other half of the same rule. Focus is drawn as a stripe *inside*
        // the bar, so the stripe plus the hairline has to leave room for text
        // within the constant height. A stripe that only fits by being added on
        // top is how a focused bar grows without anyone deciding that it
        // should.
        #expect(PaneStatusBarMetrics.accentStripeHeight
            + PaneStatusBarMetrics.hairlineHeight < PaneStatusBarMetrics.height)
    }
}
