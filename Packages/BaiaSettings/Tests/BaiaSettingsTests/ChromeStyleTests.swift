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
    }
}
