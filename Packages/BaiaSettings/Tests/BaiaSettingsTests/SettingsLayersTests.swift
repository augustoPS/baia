import Testing

@testable import BaiaSettings

@Suite struct SettingsLayersTests {
    private func keys(_ overrides: [TerminalOverride]) -> [String] {
        overrides.map(\.key)
    }

    private func value(_ overrides: [TerminalOverride], _ key: String) -> String? {
        overrides.first { $0.key == key }?.value
    }

    /// The whole reason the split exists.
    ///
    /// `TerminalController` renders base, then the per-session configuration,
    /// then the theme, and ghostty takes the last value for a scalar key. So the
    /// theme layer overrides the session layer, and a `background` sent through
    /// the session layer is silently replaced by whatever black the theme
    /// carries. The owner's `#141414` is deliberately lifted off pure black, so
    /// losing it is a visible regression that reports nothing.
    @Test func theBackgroundBelongsToTheThemeLayerBecauseTheThemeIsRenderedLast() {
        let settings = Settings.defaultSettings
        #expect(keys(settings.themeOverrides) == ["background"])
        #expect(value(settings.themeOverrides, "background") == "#141414")
        #expect(!keys(settings.sessionOverrides).contains("background"))
    }

    /// `theme` is in neither layer, and that is the point.
    ///
    /// The bundled libghostty is a trimmed build that ships no theme files, which
    /// is why the package carries a 485-theme Swift catalog instead. Sending
    /// `theme = Dark Pastel` as a config key would be dropped without a
    /// diagnostic, so themes are resolved through the catalog and applied as a
    /// `TerminalTheme` rather than named in the config.
    @Test func theThemeNameIsNotSentAsAConfigKey() {
        let settings = Settings.defaultSettings
        #expect(!keys(settings.themeOverrides).contains("theme"))
        #expect(!keys(settings.sessionOverrides).contains("theme"))
    }

    /// Nothing may be lost in the split. The two layers plus `theme`, which is
    /// deliberately dropped, have to account for every key the original list
    /// emits, so a field added to `terminalOverrides` later cannot quietly fail
    /// to reach either layer.
    @Test func thetwoLayersAccountForEveryKeyTheOriginalListEmits() {
        for settings in [Settings.defaultSettings, Self.everythingSet] {
            let original = Set(keys(settings.terminalOverrides))
            let split = Set(keys(settings.sessionOverrides))
                .union(keys(settings.themeOverrides))
                .union(["theme"])
            #expect(original == split)
        }
    }

    /// A key that appears in both layers would be applied twice with the theme
    /// silently winning, which is the confusion the split exists to remove.
    @Test func nokeyAppearsInBothLayers() {
        let settings = Settings.defaultSettings
        let session = Set(keys(settings.sessionOverrides))
        let theme = Set(keys(settings.themeOverrides))
        #expect(session.isDisjoint(with: theme))
    }

    /// The session layer keeps the values `terminalOverrides` already produces,
    /// including the integer rounding ghostty's padding keys require. Splitting
    /// the list must not re-render anything.
    @Test func thesessionLayerCarriesTheSameValuesAsBefore() {
        var settings = Settings.defaultSettings
        settings.windowPadding = 8.6
        let session = settings.sessionOverrides
        #expect(value(session, "font-size") == "11.5")
        #expect(value(session, "window-padding-x") == "9")
        #expect(value(session, "window-padding-y") == "9")
        #expect(value(session, "background-opacity") == "0.42")
        #expect(value(session, "background-blur") == "true")
        #expect(value(session, "macos-titlebar-style") == "transparent")
        #expect(value(session, "macos-option-as-alt") == "true")
        #expect(value(session, "cursor-style") == "block")
    }

    /// Unset means omitted, not empty. ghostty reads an empty `font-family` as a
    /// request for no font on some versions and as its default on others.
    @Test func anunsetFontFamilyIsOmittedFromTheSessionLayer() {
        var settings = Settings.defaultSettings
        #expect(settings.fontFamily == nil)
        #expect(!keys(settings.sessionOverrides).contains("font-family"))

        settings.fontFamily = "Berkeley Mono"
        #expect(value(settings.sessionOverrides, "font-family") == "Berkeley Mono")

        settings.fontFamily = ""
        #expect(!keys(settings.sessionOverrides).contains("font-family"))
    }

    /// Every field moved off its default, so the completeness test above sees the
    /// optional key too.
    private static var everythingSet: Settings {
        var settings = Settings.defaultSettings
        settings.fontFamily = "Berkeley Mono"
        settings.transparentTitlebar = false
        settings.optionAsAlt = false
        settings.backgroundBlur = false
        settings.windowPaddingBalance = false
        settings.cursorStyle = .bar
        settings.backgroundHex = "#0a0a0a"
        return settings
    }
}
