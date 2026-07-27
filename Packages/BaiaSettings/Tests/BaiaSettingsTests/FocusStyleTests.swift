import Foundation
import Testing

@testable import BaiaSettings

@Suite struct FocusStyleTests {
    @Test func rawValuesAreTheSpellingsTheConfigFileUses() {
        // Unlike `CursorStyle` these never reach ghostty, so nothing outside baia
        // can reject a rename. What they would break instead is every config file
        // already on disk: a renamed case turns the owner's own value into an
        // unspellable one, which falls back to the default and reports itself as
        // invalid. Pinned here so that shows up as a failing test rather than as a
        // focus treatment that quietly reverted.
        #expect(FocusStyle.allCases.map(\.rawValue) == ["recede", "invert", "frame", "barFrame"])
        #expect(FocusAccent.allCases.map(\.rawValue)
            == ["accent", "bone", "ansi5", "ansi6", "midnight"])
        #expect(AttentionStyle.allCases.map(\.rawValue) == ["loud", "quiet"])
    }

    @Test func theFocusTreatmentIsTheOnlyDefaultThatMoved() {
        // The colour defaults still change nothing. `accent` resolves to the theme's
        // own `focusedAccent`, the value shipping today; the design pass recommends
        // `bone` and deliberately does not default to it, so that installing this
        // release is not also a colour change nobody asked for.
        //
        // The focus *treatment* did move, on purpose. `barFrame` is the pass's
        // answer and `recede` stays reachable for the comparison, so the two are
        // being judged in the running app rather than on paper.
        let defaults = Settings.defaultSettings
        #expect(defaults.focusStyle == .barFrame)
        #expect(defaults.focusAccent == .accent)
        #expect(defaults.attentionStyle == .loud)
        #expect(defaults.unfocusedScrim == 0.28)
    }

    @Test func theDefaultScrimIsInsideTheLimitTheDecoderEnforces() {
        // A default outside its own range would mean the file baia writes on a first
        // launch is one baia reports as invalid the moment it reads it back.
        #expect(Settings.Limits.scrim.contains(Settings.defaultSettings.unfocusedScrim))
    }

    @Test func theScrimStopsShortOfHidingUnfocusedOutput() {
        // The ceiling is load-bearing rather than tidy. The owner reads agent output
        // in the panes he is not typing in, so a scrim heavy enough to make that
        // uncomfortable has defeated the purpose of marking focus at all.
        #expect(Settings.Limits.scrim.upperBound == 0.34)
        #expect(Settings.Limits.scrim.lowerBound == 0)
    }

    @Test func invertQuietensAttentionBecauseBothWouldFillTheSameBar() {
        // `invert` fills the focused footer and `loud` fills an asking one. A bar
        // filled for two reasons carries neither, and the pane that most needs to be
        // findable is the one that would lose.
        var settings = Settings.defaultSettings
        settings.focusStyle = .invert
        settings.attentionStyle = .loud
        #expect(settings.resolvedAttentionStyle == .quiet)
    }

    @Test func theStoredAttentionStyleSurvivesARoundTripThroughInvert() {
        // Resolved on read rather than repaired on write, so trying `invert` and
        // going back does not silently rewrite what the owner asked for. If this
        // were an initializer or a decoder repair, `loud` would be gone for good
        // and the config file would disagree with what he typed.
        var settings = Settings.defaultSettings
        settings.attentionStyle = .loud
        settings.focusStyle = .invert
        #expect(settings.resolvedAttentionStyle == .quiet)

        settings.focusStyle = .recede
        #expect(settings.attentionStyle == .loud)
        #expect(settings.resolvedAttentionStyle == .loud)
    }

    @Test func everyOtherFocusStyleLeavesTheAttentionStyleAlone() {
        for style in [FocusStyle.recede, .frame, .barFrame] {
            var settings = Settings.defaultSettings
            settings.focusStyle = style
            settings.attentionStyle = .loud
            #expect(settings.resolvedAttentionStyle == .loud)
            settings.attentionStyle = .quiet
            #expect(settings.resolvedAttentionStyle == .quiet)
        }
    }
}
