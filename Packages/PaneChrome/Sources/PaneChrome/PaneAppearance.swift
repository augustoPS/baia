import BaiaSettings
import GhosttyTerminal

/// Everything the config file decides about how one pane looks and polls,
/// resolved once by the config center and applied by the pane in one step.
///
/// See the glossary entry ("Pane appearance") this type is named for: it
/// excludes geometry and the spawn-frozen terminal configuration choice,
/// which the pane itself makes from ``terminalConfiguration`` and
/// ``glassClearTerminalConfiguration`` by ``TerminalPaneController/isSpawnedUnderGlass``.
///
/// The thirteen stored fields are exactly what
/// `ConfigurationCenter.apply(to:)` assigned, one property each, before this
/// type existed; ``TerminalPaneController/apply(_:)`` is now the one place
/// that pushes them, in the order that method's comments already recorded,
/// so the ordering constraints move into a method `make test` reaches
/// instead of living only as comments at the call site.
///
/// `terminalTheme`, `terminalConfiguration`, and
/// `glassClearTerminalConfiguration` are not pushed as pane properties: they
/// ride along so ``TerminalPaneController/apply(_:)`` can pick the
/// spawn-frozen one and call `applyTerminalConfiguration(_:theme:)` without a
/// second read of `Settings`.
public struct PaneAppearance: Equatable {
    public var theme: PaneTheme
    public var attentionStyle: AttentionStyle
    public var attentionAccent: AttentionAccent
    public var alertBehavior: AlertBehavior
    public var gitPollInterval: Double
    public var activityPollInterval: Double
    public var resolvedChrome: ResolvedChrome
    public var liftParameters: PaneLiftParameters
    public var rimParameters: PaneRimParameters
    public var backgroundOpacity: Double
    public var paneWashFloor: Double?
    public var clusterCornerInset: Double?
    public var clusterOpacity: Double?

    public var terminalTheme: TerminalTheme
    public var terminalConfiguration: TerminalConfiguration
    public var glassClearTerminalConfiguration: TerminalConfiguration

    public init(
        theme: PaneTheme,
        attentionStyle: AttentionStyle,
        attentionAccent: AttentionAccent,
        alertBehavior: AlertBehavior,
        gitPollInterval: Double,
        activityPollInterval: Double,
        resolvedChrome: ResolvedChrome,
        liftParameters: PaneLiftParameters,
        rimParameters: PaneRimParameters,
        backgroundOpacity: Double,
        paneWashFloor: Double?,
        clusterCornerInset: Double?,
        clusterOpacity: Double?,
        terminalTheme: TerminalTheme,
        terminalConfiguration: TerminalConfiguration,
        glassClearTerminalConfiguration: TerminalConfiguration
    ) {
        self.theme = theme
        self.attentionStyle = attentionStyle
        self.attentionAccent = attentionAccent
        self.alertBehavior = alertBehavior
        self.gitPollInterval = gitPollInterval
        self.activityPollInterval = activityPollInterval
        self.resolvedChrome = resolvedChrome
        self.liftParameters = liftParameters
        self.rimParameters = rimParameters
        self.backgroundOpacity = backgroundOpacity
        self.paneWashFloor = paneWashFloor
        self.clusterCornerInset = clusterCornerInset
        self.clusterOpacity = clusterOpacity
        self.terminalTheme = terminalTheme
        self.terminalConfiguration = terminalConfiguration
        self.glassClearTerminalConfiguration = glassClearTerminalConfiguration
    }

    /// Builds the value `settings` plus the debug design panel's `overrides`,
    /// the theme-derived `materialIsDark`, and the live `appearance` mean,
    /// from the derivations that already exist on ``SettingsDerivations`` and
    /// ``resolvedStyle(setting:materialIsDark:appearance:)``.
    ///
    /// **`materialIsDark` must be the theme-derived `windowIsDark`, never the
    /// observer's own `isDark`.** `ConfigurationCenter.resolvedChrome`
    /// (`Sources/ConfigurationCenter.swift:276-286`) states the invariant this
    /// parameter carries: chrome matches the theme and never the system, so
    /// the value passed here must be `windowIsDark(paneTheme:)`, the same
    /// derivation `resolvedChrome` itself passes as `materialIsDark`. Passing
    /// `appearance.isDark` instead would let a dark theme under a light system
    /// appearance draw light glass, the exact mismatch that comment records.
    ///
    /// `appearance` still reaches ``resolvedStyle(setting:materialIsDark:appearance:)``
    /// in full: Reduce Transparency keeps its authority there to force
    /// `.flat` regardless of `materialIsDark`, and Reduce Motion rides along
    /// on the same value for whatever downstream reads it, per
    /// ``ChromeAppearance``'s own doc comment.
    ///
    /// `background-opacity` is appended after everything the terminal
    /// configuration already renders for ``glassClearTerminalConfiguration``,
    /// which is what makes it safe to compose: ghostty's config parser takes
    /// the last value it reads for a scalar key.
    public static func make(
        settings: Settings,
        overrides: DesignOverrides.Chrome,
        materialIsDark: Bool,
        appearance: ChromeAppearance
    ) -> PaneAppearance {
        let resolvedChrome = resolvedStyle(
            setting: settings.chromeStyle,
            materialIsDark: materialIsDark,
            appearance: appearance
        )

        var adjustments = PaneThemeAdjustments.none
        adjustments.barLift = overrides.barLift
        adjustments.sectionHeaderMinimumRatio = overrides.inks.sectionHeaderMinimumRatio
        adjustments.busyDotInk = overrides.inks.busyDotHex.flatMap(RGB.init(hex:))

        let terminalConfiguration = SettingsDerivations.terminalConfiguration(from: settings)

        return PaneAppearance(
            theme: SettingsDerivations.paneTheme(from: settings, adjustments: adjustments),
            attentionStyle: settings.attentionStyle,
            attentionAccent: settings.attentionAccent,
            alertBehavior: settings.alertBehavior,
            gitPollInterval: settings.gitPollSeconds,
            activityPollInterval: settings.activityPollSeconds,
            resolvedChrome: resolvedChrome,
            liftParameters: .from(overrides.lift),
            rimParameters: .from(overrides.rim),
            backgroundOpacity: settings.backgroundOpacity,
            paneWashFloor: overrides.paneWashFloor,
            clusterCornerInset: overrides.cluster.cornerInset,
            clusterOpacity: overrides.cluster.opacity,
            terminalTheme: SettingsDerivations.terminalTheme(from: settings),
            terminalConfiguration: terminalConfiguration,
            glassClearTerminalConfiguration: terminalConfiguration.backgroundOpacity(0)
        )
    }
}
