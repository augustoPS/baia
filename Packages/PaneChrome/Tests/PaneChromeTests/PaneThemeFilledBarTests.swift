import BaiaSettings
import Foundation
import Testing

@testable import PaneChrome

/// Pins the attention-fill collapse that used to live in
/// `PaneStatusBarView.colour(for:)`: on an ordinary bar every tier keeps its
/// own colour, and on a bar filled for attention every tier collapses onto
/// one of two inks derived from the fill, because a fill bright enough to be
/// worth filling a bar with reverses the direction the repair chain pushes
/// in.
@Suite struct PaneThemeFilledBarTests {
    private let theme = PaneTheme.darkPastel

    @Test func unfilledMatchesTheOrdinaryTierColour() {
        for emphasis in PaneStatusEmphasis.allCases {
            #expect(theme.color(for: emphasis, focused: true, filled: false, on: theme.barBackground)
                == theme.color(for: emphasis, focused: true, on: theme.barBackground))
        }
    }

    @Test func filledCollapsesContextAndFaintOntoMutedInk() {
        let fill = theme.attentionColour(.alert, behavior: .stock)
        #expect(theme.color(for: .context, focused: true, filled: true, on: fill) == theme.mutedInk(on: fill))
        #expect(theme.color(for: .faint, focused: true, filled: true, on: fill) == theme.mutedInk(on: fill))
    }

    @Test func filledCollapsesEveryOtherTierOntoInk() {
        let fill = theme.attentionColour(.alert, behavior: .stock)
        for emphasis in PaneStatusEmphasis.allCases where emphasis != .context && emphasis != .faint {
            #expect(theme.color(for: emphasis, focused: true, filled: true, on: fill) == theme.ink(on: fill))
        }
    }
}
