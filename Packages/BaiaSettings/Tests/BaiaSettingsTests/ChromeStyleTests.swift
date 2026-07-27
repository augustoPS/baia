import Foundation
import Testing

@testable import BaiaSettings

@Suite struct ChromeStyleTests {
    @Test func rawValuesAreTheSpellingsTheConfigFileUses() {
        // Unlike `CursorStyle` these never reach ghostty, so nothing outside baia
        // can reject a rename. What they would break instead is every config file
        // already on disk: a renamed case turns the owner's own value into an
        // unspellable one, which falls back to the default and reports itself as
        // invalid. Pinned here so that shows up as a failing test rather than as a
        // treatment that quietly reverted.
        #expect(FocusAccent.allCases.map(\.rawValue)
            == ["accent", "bone", "ansi5", "ansi6", "midnight"])
        #expect(AttentionStyle.allCases.map(\.rawValue) == ["loud", "quiet"])
        #expect(AttentionAccent.allCases.map(\.rawValue) == ["alert", "accent"])
        #expect(AlertBehavior.allCases.map(\.rawValue) == ["stock", "noCollision", "derive"])
    }

    @Test func theAttentionAccentIsSpelledAlertRatherThanRed() {
        // `PaneTheme.alert` is `ansi[1]`, so on a theme whose `ansi[1]` is orange
        // or maroon the spelling `red` would be a promise the theme does not keep.
        // A config names a derivation and lets the theme decide what it resolves
        // to; this is the same reason `focusAccent` has no hex.
        #expect(AttentionAccent(rawValue: "red") == nil)
        #expect(AttentionAccent(rawValue: "alert") == .alert)
    }

    @Test func theDesignDefaultsChangeNothingAboutHowTheAppLooks() {
        // `accent` resolves to the theme's own `focusedAccent`, the value shipping
        // today; the design pass recommends `bone` and deliberately does not default
        // to it, so that installing a release is not also a colour change nobody
        // asked for. `loud` is the volume the two-level attention model shipped
        // with, and it is now read straight rather than through a resolver: one
        // treatment fills the bar, so nothing else can claim it first.
        let defaults = Settings.defaultSettings
        #expect(defaults.focusAccent == .accent)
        #expect(defaults.attentionStyle == .loud)
        // `alert` is `ansi[1]`, what the wash, the quiet line, the acknowledged
        // square and the pane frame have always been drawn in, and `stock` leaves
        // a collision alone. Together they are today's behaviour spelled out, so
        // an upgrade renders an existing config identically rather than moving a
        // colour nobody asked to move.
        #expect(defaults.attentionAccent == .alert)
        #expect(defaults.alertBehavior == .stock)
    }
}
