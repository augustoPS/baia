import BaiaSettings
import Testing

@testable import PaneChrome

/// ``PaneAppearance.make(settings:overrides:materialIsDark:appearance:)`` is
/// the one place the config file, the debug design panel's chrome extras, the
/// theme-derived darkness and the live appearance turn into the value
/// ``TerminalPaneController/apply(_:)`` pushes. These tests are at that
/// interface: completeness (every field moves with its own input, so a
/// silently defaulted field fails), a pinned baseline (empty overrides render
/// exactly what shipped), the two invariants a prior revision lost
/// (``materialIsDark`` and not the appearance's own `isDark` picks the
/// material set; Reduce Transparency still forces `.flat` on this path), the
/// glass/flat terminal configurations differing by exactly one key, and
/// determinism.
@Suite struct PaneAppearanceTests {
    private var baseSettings: Settings { .defaultSettings }
    private var baseOverrides: DesignOverrides.Chrome { DesignOverrides.Chrome() }
    private var baseAppearance: ChromeAppearance {
        ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
    }

    // MARK: - Completeness: one governing setting per field

    @Test func themeMovesWithBackgroundHex() {
        var other = baseSettings
        other.backgroundHex = "#202020"
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.theme != b.theme)
    }

    @Test func attentionStyleMovesWithItsSetting() {
        var other = baseSettings
        other.attentionStyle = other.attentionStyle == .loud ? .quiet : .loud
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.attentionStyle != b.attentionStyle)
    }

    @Test func attentionAccentMovesWithItsSetting() {
        var other = baseSettings
        other.attentionAccent = other.attentionAccent == .alert ? .accent : .alert
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.attentionAccent != b.attentionAccent)
    }

    @Test func alertBehaviorMovesWithItsSetting() {
        var other = baseSettings
        other.alertBehavior = other.alertBehavior == .stock ? .derive : .stock
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.alertBehavior != b.alertBehavior)
    }

    @Test func gitPollIntervalMovesWithGitPollSeconds() {
        var other = baseSettings
        other.gitPollSeconds = baseSettings.gitPollSeconds + 5
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.gitPollInterval != b.gitPollInterval)
    }

    @Test func activityPollIntervalMovesWithActivityPollSeconds() {
        var other = baseSettings
        other.activityPollSeconds = baseSettings.activityPollSeconds + 5
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.activityPollInterval != b.activityPollInterval)
    }

    @Test func resolvedChromeMovesWithChromeStyle() {
        var other = baseSettings
        other.chromeStyle = other.chromeStyle == .glass ? .flat : .glass
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.resolvedChrome != b.resolvedChrome)
    }

    @Test func liftParametersMoveWithTheLiftOverrides() {
        var other = baseOverrides
        other.lift.ringAlpha = (baseOverrides.lift.ringAlpha ?? PaneLiftParameters.shipped.ringAlpha) + 0.3
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, materialIsDark: true, appearance: baseAppearance)
        #expect(a.liftParameters != b.liftParameters)
    }

    @Test func rimParametersMoveWithTheRimOverrides() {
        var other = baseOverrides
        other.rim.enabled = true
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, materialIsDark: true, appearance: baseAppearance)
        #expect(a.rimParameters != b.rimParameters)
    }

    @Test func backgroundOpacityMovesWithItsSetting() {
        var other = baseSettings
        other.backgroundOpacity = min(baseSettings.backgroundOpacity + 0.3, 1)
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.backgroundOpacity != b.backgroundOpacity)
    }

    @Test func paneWashFloorMovesWithItsOverride() {
        var other = baseOverrides
        other.paneWashFloor = 0.9
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, materialIsDark: true, appearance: baseAppearance)
        #expect(a.paneWashFloor != b.paneWashFloor)
    }

    @Test func clusterCornerInsetMovesWithItsOverride() {
        var other = baseOverrides
        other.cluster.cornerInset = 40
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, materialIsDark: true, appearance: baseAppearance)
        #expect(a.clusterCornerInset != b.clusterCornerInset)
    }

    @Test func clusterOpacityMovesWithItsOverride() {
        var other = baseOverrides
        other.cluster.opacity = 0.5
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, materialIsDark: true, appearance: baseAppearance)
        #expect(a.clusterOpacity != b.clusterOpacity)
    }

    @Test func terminalThemeMovesWithThemeName() {
        var other = baseSettings
        other.themeName = "Nord"
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.terminalTheme != b.terminalTheme)
    }

    @Test func terminalConfigurationMovesWithFontSize() {
        var other = baseSettings
        other.fontSize = baseSettings.fontSize + 4
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.terminalConfiguration != b.terminalConfiguration)
    }

    @Test func glassClearTerminalConfigurationMovesWithFontSizeToo() {
        var other = baseSettings
        other.fontSize = baseSettings.fontSize + 4
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a.glassClearTerminalConfiguration != b.glassClearTerminalConfiguration)
    }

    // MARK: - Baseline: empty overrides render exactly what shipped

    /// `DesignOverrides.Chrome()` renders precisely what shipped, the same
    /// invariant `PaneThemeAdjustments.none` is asserted to hold. Pinned
    /// against the shipped constants themselves, not against a second call to
    /// `make` with the same arguments — that comparison is a tautology and
    /// passes even if `make` silently ignored every override.
    @Test func emptyOverridesRenderExactlyWhatShipped() {
        let a = PaneAppearance.make(
            settings: baseSettings,
            overrides: DesignOverrides.Chrome(),
            materialIsDark: true,
            appearance: ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        )
        #expect(a.liftParameters == PaneLiftParameters.shipped)
        #expect(a.rimParameters == PaneRimParameters.off)
        #expect(a.paneWashFloor == nil)
        #expect(a.clusterCornerInset == nil)
        #expect(a.clusterOpacity == nil)
    }

    // MARK: - Regression: the two invariants a prior revision lost

    /// The material set follows `materialIsDark`, never the appearance's own
    /// `isDark`. `ConfigurationCenter.resolvedChrome`
    /// (`Sources/ConfigurationCenter.swift:276-286`) states why: chrome
    /// matches the theme, never the system, so `windowIsDark` (passed here as
    /// `materialIsDark`) must be the one thing that picks `.dark` or `.light`,
    /// even when the live appearance disagrees.
    @Test func materialSetFollowsMaterialIsDarkNotAppearanceIsDark() {
        var settings = baseSettings
        settings.chromeStyle = .glass
        let a = PaneAppearance.make(
            settings: settings,
            overrides: baseOverrides,
            materialIsDark: true,
            appearance: ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        )
        #expect(a.resolvedChrome == .glass(.dark))
    }

    /// Reduce Transparency still forces `.flat` on this path, regardless of
    /// `chromeStyle` or `materialIsDark`. The force-flat guard lives inside
    /// `resolvedStyle(setting:materialIsDark:appearance:)` and reads
    /// `appearance.reduceTransparency`; this pins that it still reaches here.
    @Test func reduceTransparencyForcesFlatRegardlessOfMaterialIsDark() {
        var settings = baseSettings
        settings.chromeStyle = .glass
        let a = PaneAppearance.make(
            settings: settings,
            overrides: baseOverrides,
            materialIsDark: true,
            appearance: ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        )
        #expect(a.resolvedChrome == .flat)
    }

    // MARK: - Glass versus flat terminal configuration

    /// The glass-clear configuration is the flat one with `background-opacity`
    /// appended at zero, and nothing else: appending it after everything the
    /// flat configuration already renders is what makes the fold safe, since
    /// ghostty's config parser takes the last value it reads for a scalar key.
    @Test func glassClearDiffersFromFlatOnlyByBackgroundOpacity() {
        let appearance = PaneAppearance.make(
            settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance
        )
        #expect(appearance.glassClearTerminalConfiguration != appearance.terminalConfiguration)
        #expect(
            appearance.glassClearTerminalConfiguration
                == appearance.terminalConfiguration.backgroundOpacity(0)
        )
    }

    // MARK: - Determinism

    @Test func makeIsDeterministicForEqualInputs() {
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        let b = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, materialIsDark: true, appearance: baseAppearance)
        #expect(a == b)
    }
}
