import BaiaSettings
import Testing

@testable import PaneChrome

/// The compositions that lived in the app target, where nothing could reach
/// them.
///
/// Each one delegates its real question to something already tested, which is
/// why they were rated a weaker move than the rules that went before them. What
/// no test covered until they moved is the composition itself: which catalog
/// entry is chosen, what happens to a name that is not in it, and which of two
/// backgrounds survives into the chrome.
@Suite struct SettingsDerivationsTests {
    private func settings(themeName: String, backgroundHex: String = "#141414") -> Settings {
        var settings = Settings.defaultSettings
        settings.themeName = themeName
        settings.backgroundHex = backgroundHex
        return settings
    }

    @Test func resolvesAThemeThatIsInTheCatalog() {
        let definition = SettingsDerivations.themeDefinition(from: settings(themeName: "Dark Pastel"))
        #expect(definition != nil)
    }

    /// A typo degrades to the terminal the owner already runs, rather than to
    /// whatever libghostty would do with a name it cannot resolve.
    ///
    /// The fallback is the *default* theme and not nil, which is the half a
    /// reader is most likely to get wrong: the function is optional-returning,
    /// so an unknown name looks like it should answer nil.
    @Test func fallsBackToTheDefaultThemeForANameTheCatalogDoesNotHold() {
        let fallback = SettingsDerivations.themeDefinition(from: settings(themeName: "no such theme"))
        let byDefault = SettingsDerivations.themeDefinition(
            from: settings(themeName: Settings.defaultSettings.themeName)
        )
        #expect(fallback != nil)
        #expect(fallback?.palette == byDefault?.palette)
        #expect(fallback?.foreground == byDefault?.foreground)
        #expect(fallback?.background == byDefault?.background)
    }

    /// The configured background wins over the theme's own, which is the whole
    /// reason `themeOverrides` exists as a separate layer.
    ///
    /// `#141414` is deliberately lifted off pure black, and a theme carrying its
    /// own background would otherwise replace it with no diagnostic.
    @Test func theChromeCarriesTheConfiguredBackgroundAndNotTheThemes() {
        let chrome = SettingsDerivations.paneTheme(
            from: settings(themeName: "Dark Pastel", backgroundHex: "#141414")
        )
        #expect(chrome.background == RGB(hex: "#141414"))

        // A second value, so the arm cannot pass by the theme happening to carry
        // the same background the fixture asks for.
        let other = SettingsDerivations.paneTheme(
            from: settings(themeName: "Dark Pastel", backgroundHex: "#202020")
        )
        #expect(other.background == RGB(hex: "#202020"))
        #expect(chrome.background != other.background)
    }

    /// Chrome and terminal come from one catalog lookup, which is the standing
    /// rule: chrome matches the theme and never the reverse. Two sources for one
    /// theme is how a footer ends up in Dark Pastel while the surface is not.
    @Test func chromeAndTerminalAgreeOnTheThemeTheyResolved() {
        let value = settings(themeName: "Dark Pastel")
        let chrome = SettingsDerivations.paneTheme(from: value)
        let definition = SettingsDerivations.themeDefinition(from: value)
        #expect(chrome.foreground == RGB(hex: definition?.foreground ?? ""))
        // The palette is keyed by ANSI slot, so slot 0 is compared by key rather
        // than by whatever order a dictionary happens to iterate in.
        #expect(chrome.ansi.count == definition?.palette.count)
        #expect(chrome.ansi.first == RGB(hex: definition?.palette[0] ?? ""))
    }
}
