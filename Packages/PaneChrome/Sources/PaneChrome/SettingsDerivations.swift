import BaiaSettings
import GhosttyTerminal
import GhosttyTheme

/// What a `Settings` value means, in the vocabularies the app draws with.
///
/// These are the derivations `ConfigurationCenter` used to hold. They moved for
/// the standing reason: anything answerable without a descriptor or an
/// `NSWindow` belongs in a package, and the app target has no test target, so a
/// rule living there is a rule nothing can reach. Five rules were found in
/// `Sources/` across v1.1 and three of the five were wrong or unenforced when
/// they moved.
///
/// **Composition, not decision.** Each of these reads a setting and hands the
/// real question to something that already has tests: `PaneTheme.accent(for:)`
/// resolves the focus accent, `GhosttyThemeCatalog` resolves the theme name, and
/// `TerminalConfiguration`'s builder applies the overrides. That is why they were
/// rated a weaker candidate than the rules that preceded them, and it is also why
/// they are cheap to have here: a composition that cannot be tested is still a
/// composition nobody can check for drift.
///
/// **This package takes both `GhosttyTheme` and `GhosttyTerminal`, and the
/// second one was the question.** `TerminalTheme` and `TerminalConfiguration`
/// are defined in `GhosttyTerminal/Configuration/`, so two of these four cannot
/// be expressed without it, and that module is also where `View/`, `Surface/`
/// and `Platform/` live: the rendering half, which `make test` exists to stay
/// clear of.
///
/// Taking it was measured rather than assumed, twice. A package depending on
/// `GhosttyTheme` alone builds and tests headlessly; so does one that imports
/// `GhosttyTerminal`, because importing a module links it without instantiating
/// anything in it, and nothing here constructs a surface. `make test` runs green
/// with no Metal, no window and no signing, which is the property being
/// protected.
///
/// What that does not buy is licence to widen the seam. Everything here takes a
/// `Settings` and returns a value; a function that took a `TerminalController`
/// or a surface would put a live renderer behind a call the one-second loop
/// makes, and the headless property would go with it.
public enum SettingsDerivations {
    /// The catalog entry for the configured theme name.
    ///
    /// Resolved through `GhosttyThemeCatalog` rather than by sending
    /// `theme = <name>` to ghostty. The bundled libghostty is a trimmed build
    /// that ships no theme files, so the config key would be dropped without a
    /// diagnostic and the terminal would keep its defaults while the config
    /// looked applied.
    ///
    /// An unknown name falls back to the default theme rather than to whatever
    /// libghostty would do on its own, so a typo degrades to the terminal the
    /// owner already runs.
    public static func themeDefinition(from settings: Settings) -> GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: settings.themeName)
            ?? GhosttyThemeCatalog.theme(named: Settings.defaultSettings.themeName)
    }

    /// The terminal theme, with the configured background folded in on top.
    ///
    /// The fold is not cosmetic. `TerminalController` renders base, then the
    /// session configuration, then the theme, and ghostty takes the last value
    /// for a scalar key, so a background sent through the session layer is
    /// replaced by the theme's own. The owner's `#141414` is deliberately lifted
    /// off pure black, and losing it reports nothing.
    public static func terminalTheme(from settings: Settings) -> TerminalTheme {
        guard let definition = themeDefinition(from: settings) else { return .default }
        let overrides = settings.themeOverrides
        let configuration = TerminalConfiguration(
            startingFrom: definition.toTerminalConfiguration()
        ) { builder in
            for override in overrides {
                builder.withCustom(override.key, override.value)
            }
        }
        return TerminalTheme(light: configuration, dark: configuration)
    }

    /// Everything the theme does not own, applied per pane through
    /// `setTerminalConfiguration`.
    public static func terminalConfiguration(from settings: Settings) -> TerminalConfiguration {
        let overrides = settings.sessionOverrides
        return TerminalConfiguration { builder in
            for override in overrides {
                builder.withCustom(override.key, override.value)
            }
        }
    }

    /// The chrome palette, from the same catalog entry the terminal is themed
    /// from.
    ///
    /// One lookup feeding both is the point. The standing rule is that chrome
    /// matches the theme and never the reverse, and two sources for one theme is
    /// how a pane's chrome ends up in Dark Pastel while the surface is in something
    /// else.
    ///
    /// `focusAccent` goes in as an argument rather than being applied to the
    /// result, so this reads the setting and decides nothing about it. The
    /// resolution is `PaneTheme.accent(for:)`, which has tests; a line here
    /// would not, and a line here is how the key came to be decoded, stored and
    /// never read.
    ///
    /// The fallback keeps the shipped accent. It is reached only when the
    /// catalog cannot produce even its own default theme, which is a broken
    /// build rather than a config the owner wrote, and there is no palette in
    /// hand at that point to resolve a choice against anyway.
    /// `adjustments` is the debug design panel's shadow over the handful of
    /// ``PaneTheme`` constants it can dial, threaded as a parameter rather than
    /// reached for as a global. ``PaneThemeAdjustments/none`` — the default, and
    /// what every caller outside `ConfigurationCenter` passes — is exactly the
    /// identity, asserted field by field in `PaneThemeAdjustmentsTests`, so a
    /// Release build (where the app-side overrides are structurally absent)
    /// derives precisely the theme it derived before this parameter existed.
    ///
    /// A parameter and not a `PaneTheme` field the app assigns afterwards, for
    /// the same reason `focusAccent` immediately below is one: an assignment is
    /// a line a caller can forget, and this codebase has the scar — that key was
    /// decoded, stored and tested for a week while nothing read it. The
    /// fallback path (`.darkPastel`, a broken build rather than a config the
    /// owner wrote) carries the adjustments too, so no branch here is a branch
    /// where a dialled value silently stops applying.
    public static func paneTheme(
        from settings: Settings,
        adjustments: PaneThemeAdjustments = .none
    ) -> PaneTheme {
        guard let definition = themeDefinition(from: settings) else {
            var fallback = PaneTheme.darkPastel
            fallback.adjustments = adjustments
            return fallback
        }
        var theme = PaneTheme(
            background: settings.backgroundHex,
            foreground: definition.foreground,
            selectionBackground: definition.selectionBackground,
            palette: definition.palette,
            focusAccent: settings.focusAccent
        )
        theme.adjustments = adjustments
        return theme
    }
}
