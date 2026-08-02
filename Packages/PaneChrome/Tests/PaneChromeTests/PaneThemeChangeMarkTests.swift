import Foundation
import Testing

@testable import PaneChrome

/// Pins the mark-colour policy that ``ChangesSurface`` and ``FilesSurface``
/// both draw from, so the two call sites cannot drift apart the way the four
/// candidate resolvers already had before this package existed.
@Suite struct PaneThemeChangeMarkTests {
    @Test func eachMarkResolvesToTheThemesOwnColour() {
        let theme = PaneTheme.darkPastel
        // Not `ok`, whose own documentation says it is never used for text.
        // `staged` is that green given `warn`'s construction, so the pair a
        // reader has to tell apart is one vocabulary rather than two.
        #expect(theme.colour(for: .staged) == theme.staged)
        #expect(theme.colour(for: .unstaged) == theme.warn)
        #expect(theme.colour(for: .untracked) == theme.inkFaint)
        #expect(theme.colour(for: .conflict) == theme.alert)
    }
}
