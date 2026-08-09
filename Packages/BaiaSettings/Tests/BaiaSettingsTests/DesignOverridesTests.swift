import Foundation
import Testing

@testable import BaiaSettings

@Suite struct DesignOverridesTests {
    // MARK: - Identity

    @Test func emptyOverridesChangeNothing() {
        // The whole composition rests on this. `ConfigurationCenter` composes
        // before every derivation, including every derivation taken while the
        // panel has never been opened, so an empty value that moved even one
        // field would move the shipped app for an owner who never asked for it.
        #expect(Settings.defaultSettings.applying(DesignOverrides()) == Settings.defaultSettings)
    }

    @Test func emptyOverridesChangeNothingForANonDefaultSettings() {
        // The identity above could pass by accident if `applying` substituted
        // defaults rather than leaving fields alone: every shadowed field would
        // land back on the value it already had. A settings value that differs
        // from the defaults in all seven cannot pass that way.
        var settings = Settings.defaultSettings
        settings.backgroundOpacity = 0.9
        settings.backgroundBlur = false
        settings.chromeStyle = .flat
        settings.attentionStyle = .quiet
        settings.attentionAccent = .accent
        settings.focusAccent = .bone
        settings.transparentTitlebar = false
        #expect(settings.applying(DesignOverrides()) == settings)
    }

    @Test func anEmptyOverrideIsIdentityFieldByField() {
        // Field-by-field rather than only whole-value, so a future field added to
        // `Settings` and wrongly wired into `applying` names itself here instead
        // of hiding inside an `==` that was written before it existed.
        let composed = Settings.defaultSettings.applying(DesignOverrides())
        let defaults = Settings.defaultSettings
        #expect(composed.backgroundOpacity == defaults.backgroundOpacity)
        #expect(composed.backgroundBlur == defaults.backgroundBlur)
        #expect(composed.chromeStyle == defaults.chromeStyle)
        #expect(composed.attentionStyle == defaults.attentionStyle)
        #expect(composed.attentionAccent == defaults.attentionAccent)
        #expect(composed.focusAccent == defaults.focusAccent)
        #expect(composed.transparentTitlebar == defaults.transparentTitlebar)
        #expect(composed.fontSize == defaults.fontSize)
        #expect(composed.windowPadding == defaults.windowPadding)
        #expect(composed.windowPaddingBalance == defaults.windowPaddingBalance)
        #expect(composed.themeName == defaults.themeName)
        #expect(composed.backgroundHex == defaults.backgroundHex)
    }

    // MARK: - Shadowing, one test per shadowed field

    @Test func aSetBackgroundOpacityWins() {
        var overrides = DesignOverrides()
        overrides.backgroundOpacity = 0.7
        #expect(Settings.defaultSettings.applying(overrides).backgroundOpacity == 0.7)
    }

    @Test func aSetBackgroundBlurWins() {
        // False against a true default, so the test cannot pass by the override
        // being ignored. Every one of the three booleans below is set the same
        // way for the same reason.
        var overrides = DesignOverrides()
        overrides.backgroundBlur = false
        #expect(Settings.defaultSettings.backgroundBlur)
        #expect(!Settings.defaultSettings.applying(overrides).backgroundBlur)
    }

    @Test func aSetChromeStyleWins() {
        var overrides = DesignOverrides()
        overrides.chromeStyle = .flat
        #expect(Settings.defaultSettings.chromeStyle == .glass)
        #expect(Settings.defaultSettings.applying(overrides).chromeStyle == .flat)
    }

    @Test func aSetAttentionStyleWins() {
        var overrides = DesignOverrides()
        overrides.attentionStyle = .quiet
        #expect(Settings.defaultSettings.attentionStyle == .loud)
        #expect(Settings.defaultSettings.applying(overrides).attentionStyle == .quiet)
    }

    @Test func aSetAttentionAccentWins() {
        var overrides = DesignOverrides()
        overrides.attentionAccent = .accent
        #expect(Settings.defaultSettings.attentionAccent == .alert)
        #expect(Settings.defaultSettings.applying(overrides).attentionAccent == .accent)
    }

    @Test func aSetFocusAccentWins() {
        var overrides = DesignOverrides()
        overrides.focusAccent = .nightshade
        #expect(Settings.defaultSettings.focusAccent == .accent)
        #expect(Settings.defaultSettings.applying(overrides).focusAccent == .nightshade)
    }

    @Test func aSetTransparentTitlebarWins() {
        var overrides = DesignOverrides()
        overrides.transparentTitlebar = false
        #expect(Settings.defaultSettings.transparentTitlebar)
        #expect(!Settings.defaultSettings.applying(overrides).transparentTitlebar)
    }

    @Test func aSetFieldShadowsOnlyItself() {
        // The panel dials one knob at a time and the other six have to survive
        // it. A composition written as "rebuild a Settings from the overrides"
        // rather than "replace the fields that are set" passes every single-field
        // test above and fails this one.
        var overrides = DesignOverrides()
        overrides.chromeStyle = .flat
        let composed = Settings.defaultSettings.applying(overrides)
        #expect(composed.chromeStyle == .flat)
        #expect(composed.backgroundOpacity == Settings.defaultSettings.backgroundOpacity)
        #expect(composed.backgroundBlur == Settings.defaultSettings.backgroundBlur)
        #expect(composed.attentionStyle == Settings.defaultSettings.attentionStyle)
        #expect(composed.attentionAccent == Settings.defaultSettings.attentionAccent)
        #expect(composed.focusAccent == Settings.defaultSettings.focusAccent)
        #expect(composed.transparentTitlebar == Settings.defaultSettings.transparentTitlebar)
    }

    @Test func allSevenApplyAtOnce() {
        var overrides = DesignOverrides()
        overrides.backgroundOpacity = 0.55
        overrides.backgroundBlur = false
        overrides.chromeStyle = .flat
        overrides.attentionStyle = .quiet
        overrides.attentionAccent = .accent
        overrides.focusAccent = .sea
        overrides.transparentTitlebar = false

        let composed = Settings.defaultSettings.applying(overrides)
        #expect(composed.backgroundOpacity == 0.55)
        #expect(!composed.backgroundBlur)
        #expect(composed.chromeStyle == .flat)
        #expect(composed.attentionStyle == .quiet)
        #expect(composed.attentionAccent == .accent)
        #expect(composed.focusAccent == .sea)
        #expect(!composed.transparentTitlebar)
    }

    @Test func composingIsIdempotent() {
        // The panel redraws on every dial move and `ConfigurationCenter` composes
        // before every derivation, so the same overrides land on the same
        // committed settings many times over. Composition that accumulated
        // (a delta rather than a replacement) would drift under exactly that use.
        var overrides = DesignOverrides()
        overrides.backgroundOpacity = 0.55
        overrides.focusAccent = .bone
        let once = Settings.defaultSettings.applying(overrides)
        #expect(once.applying(overrides) == once)
    }

    // MARK: - The no-geometry invariant

    @Test func nothingThatResizesAPtySurvivesComposition() {
        // The SIGWINCH wall, stated as a test rather than only as prose on the
        // type. A geometry change resizes a live PTY, and a resize mid-run
        // disturbs whatever agent is running in the pane, which is the one thing
        // a debug panel dialled over real sessions must never do. The type has no
        // field for these, so this cannot be made to fail by setting one. It
        // fails the moment somebody adds the field the doc contract forbids.
        var overrides = DesignOverrides()
        overrides.backgroundOpacity = 0.3
        overrides.chromeStyle = .flat
        let composed = Settings.defaultSettings.applying(overrides)
        #expect(composed.fontSize == Settings.defaultSettings.fontSize)
        #expect(composed.fontFamily == Settings.defaultSettings.fontFamily)
        #expect(composed.windowPadding == Settings.defaultSettings.windowPadding)
        #expect(composed.windowPaddingBalance == Settings.defaultSettings.windowPaddingBalance)
    }

    @Test func composedSettingsEmitNoGeometryChangeToGhostty() {
        // The wall measured where it actually stands: `sessionOverrides` is the
        // list `SettingsDerivations.terminalConfiguration(from:)` hands the
        // engine per pane, so it is the last point at which a geometry change
        // could still reach a live PTY. Asserted here rather than on
        // `terminalOverrides`, which is only a faithful proxy for as long as
        // `themeOwnedKeys` stays {background, theme}: a future key added to that
        // filter would silently narrow this test's coverage without failing it.
        //
        // Started from a settings value that names a font, because the defaults
        // leave `fontFamily` nil and `terminalOverrides` omits the key entirely
        // when it is unset. Against the defaults the `font-family` row of this
        // loop compares nil to nil and would pass even if composition moved it.
        var settings = Settings.defaultSettings
        settings.fontFamily = "Menlo"

        var overrides = DesignOverrides()
        overrides.backgroundOpacity = 0.3
        overrides.backgroundBlur = false
        overrides.chromeStyle = .flat
        overrides.focusAccent = .bone

        let before = settings.sessionOverrides
        let after = settings.applying(overrides).sessionOverrides
        let geometryKeys = ["font-size", "font-family", "window-padding-x", "window-padding-y"]
        for key in geometryKeys {
            // Present on both sides as well as equal. An assertion that only
            // compared them would go vacuous again the moment a key stopped
            // being emitted at all.
            let emitted = before.first { $0.key == key }?.value
            #expect(emitted != nil)
            #expect(emitted == after.first { $0.key == key }?.value)
        }
        #expect(after.contains(TerminalOverride(key: "background-opacity", value: "0.3")))
    }

    // MARK: - Chrome extras

    @Test func chromeExtrasAreAllNilByDefault() {
        // nil is "today's constant", so a fresh value has to leave every drawing
        // site exactly where it is. Checked group by group rather than through
        // `==` against a second empty value, which would pass even if a field
        // defaulted to something non-nil.
        let extras = DesignOverrides().chrome
        #expect(extras.lift.enabled == nil)
        #expect(extras.lift.ringSpread == nil)
        #expect(extras.lift.ringAlpha == nil)
        #expect(extras.lift.innerHighlightOffsetY == nil)
        #expect(extras.lift.innerHighlightAlpha == nil)
        #expect(extras.lift.shadowDropOffsetY == nil)
        #expect(extras.lift.shadowDropBlur == nil)
        #expect(extras.lift.shadowDropAlpha == nil)
        #expect(extras.lift.duration == nil)
        #expect(extras.rim.enabled == nil)
        #expect(extras.rim.topAlpha == nil)
        #expect(extras.inks.sessionHeaderMinimumRatio == nil)
        #expect(extras.inks.sessionHeaderHex == nil)
        #expect(extras.inks.actionRowMinimumRatio == nil)
        #expect(extras.inks.actionRowHex == nil)
        #expect(extras.inks.sectionHeaderMinimumRatio == nil)
        #expect(extras.inks.busyDotHex == nil)
        #expect(extras.barLift == nil)
        #expect(extras.surfaces.sidebar == nil)
        #expect(extras.surfaces.palette == nil)
        #expect(extras.surfaces.popover == nil)
        #expect(extras.surfaces.titlebar == nil)
    }

    @Test func anEmptyOverridesCarriesAnEmptyChromeExtras() {
        #expect(DesignOverrides().chrome == DesignOverrides.Chrome())
    }

    // MARK: - bareGlass and sidebarWashFloor, retired 2026-08-08

    // **Three `bareGlass` arms stood here, and one `sidebarWashFloor` field
    // assertion above, until the knob they guarded was retired.**
    //
    // They held that `bareGlass` was an extra reaching no `Settings` field,
    // that it set only itself among the extras, and that a written `false` was
    // distinguishable from unset. All three were about a knob that existed to
    // ask one question: is the native glass better naked than under this app's
    // hand-drawn wash? The owner answered it on 2026-08-08 by A/B-ing the two
    // over his own desktop, and ruled that naked wins.
    //
    // So the washes are gone from the drawing sites and the knob is gone with
    // them, which is why these arms are a tombstone rather than a rewrite:
    // there is no field left to assert about, and re-pointing them at a
    // surviving knob would keep the names while testing something else. What
    // they were really defending — that a debug-only extra never leaks into the
    // value the config file round-trips — is still held for every remaining
    // extra by `chromeExtrasSurviveCompositionByNotEnteringSettings`,
    // `chromeExtrasAreAllNilByDefault` and
    // `anEmptyOverridesCarriesAnEmptyChromeExtras`.
    //
    // The one piece of the layer that survived the ruling is the caps label's
    // legibility repair (`SurfaceTitleView.labelInk`), now unconditional on
    // glass. `PaneThemeAdjustmentsTests` still keeps the standing arms
    // explaining why that repair cannot be expressed as an adjustments value.

    // MARK: - Per-surface material choice

    // **These arms named `footer` as their subject until 2026-08-09** and now
    // name `sidebar`. Unlike the `bareGlass` tombstone above, that is a move
    // rather than a deletion: what they hold — that a surface starts nil, that
    // it accepts every material that exists, that dialling one leaves the rest
    // alone, that a choice reaches no `Settings` field — is a property of the
    // ``Surfaces`` type and not of the footer, so it transfers whole to a
    // surviving slot. The footer's own slot went because ABSORB deletes the
    // glass view it wrote to; see `DesignOverrides.Chrome`.

    @Test func everySurfaceStartsOnItsOwnFill() {
        // nil means "the fill this surface draws today", and today is not the
        // same fill for all four. A surface defaulting to a named material would
        // repaint it the moment the panel existed.
        let surfaces = DesignOverrides().chrome.surfaces
        #expect(surfaces.sidebar == nil)
        #expect(surfaces.palette == nil)
        #expect(surfaces.popover == nil)
        #expect(surfaces.titlebar == nil)
    }

    @Test func aSurfaceCanBePointedAtEachMaterialThatExists() {
        // Enumerated rather than spot-checked, so this fails if a case is added
        // to `Material` without a drawing site that can resolve it. The count is
        // pinned for the same reason: `ChromeMaterials` carries exactly these
        // four roles and its own doc comment forbids adding a fifth ahead of a
        // consumer, so a new case here has to be a deliberate, reviewed diff.
        #expect(DesignOverrides.Chrome.Material.allCases.count == 4)
        for material in DesignOverrides.Chrome.Material.allCases {
            var overrides = DesignOverrides()
            overrides.chrome.surfaces.sidebar = material
            #expect(overrides.chrome.surfaces.sidebar == material)
        }
    }

    @Test func theFourMaterialsAreTheRolesChromeMaterialsCarries() {
        // Spelled out by name, because these strings are how a surface selection
        // is read back and matched to a fill role at the drawing site. A rename
        // that looked harmless here would silently stop resolving there.
        #expect(Set(DesignOverrides.Chrome.Material.allCases.map(\.rawValue))
            == ["chrome", "sidebar", "thick", "menu"])
    }

    @Test func aDialledSurfaceLeavesTheOtherThreeAlone() {
        // The same independence the seven shadow fields get. A panel dials one
        // surface at a time and the others must not follow it.
        var overrides = DesignOverrides()
        overrides.chrome.surfaces.sidebar = .thick
        #expect(overrides.chrome.surfaces.sidebar == .thick)
        #expect(overrides.chrome.surfaces.palette == nil)
        #expect(overrides.chrome.surfaces.popover == nil)
        #expect(overrides.chrome.surfaces.titlebar == nil)
    }

    @Test func surfaceChoicesReachNoSettingsField() {
        // Extras, like the rest of `Chrome`: a material selection maps to no
        // `Settings` field and must survive composition by being carried past it
        // rather than folded in. `chromeStyle` is the nearby field that *is*
        // shadowed, and it stays untouched by a surface dial.
        var overrides = DesignOverrides()
        overrides.chrome.surfaces.sidebar = .menu
        overrides.chrome.surfaces.titlebar = .chrome

        let composed = Settings.defaultSettings.applying(overrides)
        #expect(composed == Settings.defaultSettings)
        #expect(composed.chromeStyle == Settings.defaultSettings.chromeStyle)
        #expect(overrides.chrome.surfaces.sidebar == .menu)
        #expect(overrides.chrome.surfaces.titlebar == .chrome)
    }

    @Test func surfaceChoicesParticipateInEquality() {
        // `ConfigurationCenter` skips a re-derivation when a dial lands back
        // where it was, so equality has to reach three levels down.
        var first = DesignOverrides()
        first.chrome.surfaces.palette = .menu
        var second = DesignOverrides()
        second.chrome.surfaces.palette = .menu
        #expect(first == second)

        second.chrome.surfaces.palette = .thick
        #expect(first != second)

        second.chrome.surfaces.palette = nil
        #expect(first != second)
    }

    @Test func chromeExtrasSurviveCompositionByNotEnteringSettings() {
        // The extras half maps to no `Settings` field, and that is the design
        // rather than an omission: these numbers reach drawing sites directly.
        // Composition must therefore neither consume them nor drop them, so the
        // app side reads them off the overrides value it already holds.
        var overrides = DesignOverrides()
        overrides.chrome.lift.ringAlpha = 0.4
        overrides.chrome.inks.busyDotHex = "#ff0000"
        overrides.chrome.barLift = 0.2

        #expect(Settings.defaultSettings.applying(overrides) == Settings.defaultSettings)
        #expect(overrides.chrome.lift.ringAlpha == 0.4)
        #expect(overrides.chrome.inks.busyDotHex == "#ff0000")
        #expect(overrides.chrome.barLift == 0.2)
    }

    @Test func extrasAndShadowFieldsAreIndependent() {
        // Setting an extra must not disturb the seven, and setting one of the
        // seven must not disturb the extras. Both directions, because the panel
        // dials across the two halves in one sitting.
        var overrides = DesignOverrides()
        overrides.chrome.lift.enabled = false
        overrides.chromeStyle = .flat

        let composed = Settings.defaultSettings.applying(overrides)
        #expect(composed.chromeStyle == .flat)
        #expect(composed.backgroundOpacity == Settings.defaultSettings.backgroundOpacity)
        #expect(overrides.chrome.lift.enabled == false)
    }

    // MARK: - Being a value

    @Test func isAValueTypeRatherThanAReference() {
        // The panel hands overrides across to `ConfigurationCenter` and keeps
        // dialling. A reference here would let a half-dialled value reach a
        // derivation that already read it.
        var first = DesignOverrides()
        first.backgroundOpacity = 0.5
        var second = first
        second.backgroundOpacity = 0.9
        second.chrome.barLift = 0.3
        #expect(first.backgroundOpacity == 0.5)
        #expect(first.chrome.barLift == nil)
        #expect(second.backgroundOpacity == 0.9)
    }

    @Test func twoOverridesWithTheSameFieldsAreEqual() {
        // Equality is what lets `ConfigurationCenter` skip a re-derivation when a
        // dial lands back where it was, so it has to reach the nested extras and
        // not just the seven flat fields.
        var first = DesignOverrides()
        first.focusAccent = .sea
        first.chrome.rim.topAlpha = 0.5
        var second = DesignOverrides()
        second.focusAccent = .sea
        second.chrome.rim.topAlpha = 0.5
        #expect(first == second)

        second.chrome.rim.topAlpha = 0.6
        #expect(first != second)
    }
}
