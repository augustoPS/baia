import BaiaSettings
import GhosttyTerminal

/// Everything ``PaneLiftView`` draws with, resolved: the constants in
/// `ChromeMaterials.Lift`/`Motion`, or whatever the debug design panel has
/// dialled in front of them.
///
/// **``shipped`` is exactly the constants, and it is the default.** A lift view
/// that is never handed one of these renders precisely what it rendered before
/// this type existed, which is what makes the whole wire a no-op with the
/// overrides nil. ``from(_:)`` builds a dialled one; nil per field there falls
/// back to the constant, never to zero and never to off.
///
/// **Resolved once, into non-optionals, rather than eight `??` at the draw
/// sites.** `draw(_:)` and `updateShadowPath()` both need the ring and the
/// shadow reach, and a fallback spelled twice is a fallback that can be spelled
/// two ways. It is also what keeps ``PaneLiftView`` free of any import beyond
/// what it already has — `Diagnostics/footer-corners` compiles this file
/// verbatim against `PaneChrome`, `BaiaSettings` and `WorkspaceLayout` alone,
/// and a `DesignOverrides` read inside the view would be a fourth edge that
/// probe cannot link.
///
/// Colours are deliberately absent. The ring and the highlight are white at an
/// alpha, per the plan's Task 6 text, and the panel dials the alphas rather than
/// the hue: a coloured lift is a different effect, not this one turned up.
///
/// **Moved into `PaneChrome` from `Sources/PaneOverlayView.swift`** so
/// ``PaneAppearance/make(settings:overrides:materialIsDark:appearance:)`` can carry a
/// resolved value without reaching for an app-target type. Verbatim, with its
/// doc comment; only the access level changed, from `struct`/`static`/`var` to
/// `public`.
public struct PaneLiftParameters: Sendable, Equatable {
    public var enabled: Bool
    public var ringSpread: Double
    public var ringAlpha: Double
    public var innerHighlightOffsetY: Double
    public var innerHighlightAlpha: Double
    public var shadowDropOffsetY: Double
    public var shadowDropBlur: Double
    public var shadowDropAlpha: Double
    public var duration: Double

    /// The constants, unmoved: what every pane draws until something is dialled.
    ///
    /// `duration` takes the long end of the 140-220 ms band, which is the value
    /// ``PaneLiftView/apply(animated:)`` picked before this type existed and for
    /// the reason recorded there: the lift crosses two panes on a click, and the
    /// short end was tuned for a single-layer fade.
    public static let shipped = PaneLiftParameters(
        enabled: true,
        ringSpread: ChromeMaterials.Lift.ringSpread,
        ringAlpha: ChromeMaterials.Lift.ringAlpha,
        innerHighlightOffsetY: ChromeMaterials.Lift.innerHighlightOffsetY,
        innerHighlightAlpha: ChromeMaterials.Lift.innerHighlightAlpha,
        shadowDropOffsetY: ChromeMaterials.Lift.shadow.dropOffsetY,
        shadowDropBlur: ChromeMaterials.Lift.shadow.dropBlur,
        shadowDropAlpha: ChromeMaterials.Lift.shadow.dropAlpha,
        duration: ChromeMaterials.Motion.liftDurationLong
    )

    /// ``shipped``, with each dialled field standing in front of its constant.
    ///
    /// Field by field rather than "rebuild from the overrides", the same shape
    /// `Settings.applying(_:)` takes and for the same reason: a field this
    /// function has never heard of keeps its constant instead of arriving as a
    /// zero.
    public static func from(_ lift: DesignOverrides.Chrome.Lift) -> PaneLiftParameters {
        var resolved = shipped
        if let value = lift.enabled { resolved.enabled = value }
        if let value = lift.ringSpread { resolved.ringSpread = value }
        if let value = lift.ringAlpha { resolved.ringAlpha = value }
        if let value = lift.innerHighlightOffsetY { resolved.innerHighlightOffsetY = value }
        if let value = lift.innerHighlightAlpha { resolved.innerHighlightAlpha = value }
        if let value = lift.shadowDropOffsetY { resolved.shadowDropOffsetY = value }
        if let value = lift.shadowDropBlur { resolved.shadowDropBlur = value }
        if let value = lift.shadowDropAlpha { resolved.shadowDropAlpha = value }
        if let value = lift.duration { resolved.duration = value }
        return resolved
    }
}

/// The lens rim: the bright top edge `--rim-top` names, drawn inside a pane's
/// own outline.
///
/// **Off by default, and off is exactly today's rendering.** The rim constants
/// have been transcribed and tested in ``ChromeMaterials`` since v5 and no
/// drawing site has ever read them; this is their first consumer, and it draws
/// nothing at all unless ``enabled`` is set. So the wire adds a knob without
/// adding a pixel, which is the acceptance the whole override layer is held to.
///
/// Top edge only, per the constants' own doc (`inset 0 0.5px 0`, a bright top
/// rim). `--rim-bottom` is transcribed beside it in ``ChromeMaterials`` and is
/// deliberately not drawn here: `DesignOverrides.Chrome.Rim` offers one alpha,
/// and a bottom edge nothing can dial would be an effect the owner cannot
/// switch off independently of the one he asked for.
///
/// Moved into `PaneChrome` alongside ``PaneLiftParameters``, for the same
/// reason and verbatim but for access level.
public struct PaneRimParameters: Sendable, Equatable {
    public var enabled: Bool

    /// The bright edge's alpha. Defaults to the *dark* appearance's constant,
    /// which is the one the app draws under today (`ChromeAppearance`'s material
    /// set follows the theme, and the shipped theme is dark).
    ///
    /// One value rather than one per appearance, matching
    /// `DesignOverrides.Chrome.Rim`'s own reasoning: the panel is dialled on the
    /// machine in front of the owner and that machine is in one appearance at a
    /// time.
    public var topAlpha: Double

    /// The edge's thickness, in points: `inset 0 0.5px 0`. Not dialable, and
    /// deliberately so — it is a hairline the token names, and the override
    /// offers an alpha alone.
    public static let thickness: Double = 0.5

    /// Absent: what every pane draws today and what a nil override leaves it
    /// drawing.
    public static let off = PaneRimParameters(
        enabled: false,
        topAlpha: ChromeMaterials.Dark.rimTopAlpha
    )

    public static func from(_ rim: DesignOverrides.Chrome.Rim) -> PaneRimParameters {
        var resolved = off
        if let value = rim.enabled { resolved.enabled = value }
        if let value = rim.topAlpha { resolved.topAlpha = value }
        return resolved
    }
}

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
