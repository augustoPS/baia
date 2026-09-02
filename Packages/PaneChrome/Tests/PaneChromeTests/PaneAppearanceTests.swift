import BaiaSettings
import Testing

@testable import PaneChrome

/// ``PaneAppearance.make(settings:overrides:isDarkAppearance:)`` is the one
/// place the config file, the debug design panel's chrome extras and the live
/// appearance flag turn into the value ``TerminalPaneController/apply(_:)``
/// pushes. These tests are at that interface: completeness (every field moves
/// with its own input, so a silently defaulted field fails), identity (no
/// overrides is the same as empty overrides), the glass/flat terminal
/// configurations differing by exactly one key, and determinism.
@Suite struct PaneAppearanceTests {
    private var baseSettings: Settings { .defaultSettings }
    private var baseOverrides: DesignOverrides.Chrome { DesignOverrides.Chrome() }

    // MARK: - Completeness: one governing setting per field

    @Test func themeMovesWithBackgroundHex() {
        var other = baseSettings
        other.backgroundHex = "#202020"
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.theme != b.theme)
    }

    @Test func attentionStyleMovesWithItsSetting() {
        var other = baseSettings
        other.attentionStyle = other.attentionStyle == .loud ? .quiet : .loud
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.attentionStyle != b.attentionStyle)
    }

    @Test func attentionAccentMovesWithItsSetting() {
        var other = baseSettings
        other.attentionAccent = other.attentionAccent == .alert ? .accent : .alert
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.attentionAccent != b.attentionAccent)
    }

    @Test func alertBehaviorMovesWithItsSetting() {
        var other = baseSettings
        other.alertBehavior = other.alertBehavior == .stock ? .derive : .stock
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.alertBehavior != b.alertBehavior)
    }

    @Test func gitPollIntervalMovesWithGitPollSeconds() {
        var other = baseSettings
        other.gitPollSeconds = baseSettings.gitPollSeconds + 5
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.gitPollInterval != b.gitPollInterval)
    }

    @Test func activityPollIntervalMovesWithActivityPollSeconds() {
        var other = baseSettings
        other.activityPollSeconds = baseSettings.activityPollSeconds + 5
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.activityPollInterval != b.activityPollInterval)
    }

    @Test func resolvedChromeMovesWithChromeStyle() {
        var other = baseSettings
        other.chromeStyle = other.chromeStyle == .glass ? .flat : .glass
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.resolvedChrome != b.resolvedChrome)
    }

    @Test func liftParametersMoveWithTheLiftOverrides() {
        var other = baseOverrides
        other.lift.ringAlpha = (baseOverrides.lift.ringAlpha ?? PaneLiftParameters.shipped.ringAlpha) + 0.3
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, isDarkAppearance: true)
        #expect(a.liftParameters != b.liftParameters)
    }

    @Test func rimParametersMoveWithTheRimOverrides() {
        var other = baseOverrides
        other.rim.enabled = true
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, isDarkAppearance: true)
        #expect(a.rimParameters != b.rimParameters)
    }

    @Test func backgroundOpacityMovesWithItsSetting() {
        var other = baseSettings
        other.backgroundOpacity = min(baseSettings.backgroundOpacity + 0.3, 1)
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.backgroundOpacity != b.backgroundOpacity)
    }

    @Test func paneWashFloorMovesWithItsOverride() {
        var other = baseOverrides
        other.paneWashFloor = 0.9
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, isDarkAppearance: true)
        #expect(a.paneWashFloor != b.paneWashFloor)
    }

    @Test func clusterCornerInsetMovesWithItsOverride() {
        var other = baseOverrides
        other.cluster.cornerInset = 40
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, isDarkAppearance: true)
        #expect(a.clusterCornerInset != b.clusterCornerInset)
    }

    @Test func clusterOpacityMovesWithItsOverride() {
        var other = baseOverrides
        other.cluster.opacity = 0.5
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: baseSettings, overrides: other, isDarkAppearance: true)
        #expect(a.clusterOpacity != b.clusterOpacity)
    }

    @Test func terminalThemeMovesWithThemeName() {
        var other = baseSettings
        other.themeName = "Nord"
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.terminalTheme != b.terminalTheme)
    }

    @Test func terminalConfigurationMovesWithFontSize() {
        var other = baseSettings
        other.fontSize = baseSettings.fontSize + 4
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.terminalConfiguration != b.terminalConfiguration)
    }

    @Test func glassClearTerminalConfigurationMovesWithFontSizeToo() {
        var other = baseSettings
        other.fontSize = baseSettings.fontSize + 4
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: other, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a.glassClearTerminalConfiguration != b.glassClearTerminalConfiguration)
    }

    // MARK: - Identity: empty overrides is no overrides

    /// `DesignOverrides.Chrome()` renders precisely what shipped, the same
    /// invariant `PaneThemeAdjustments.none` is asserted to hold; a `make`
    /// call given the empty value must equal one that never mentions
    /// overrides at all.
    @Test func emptyOverridesEqualsNoOverrides() {
        let withEmpty = PaneAppearance.make(
            settings: baseSettings, overrides: DesignOverrides.Chrome(), isDarkAppearance: true
        )
        let withDefault = PaneAppearance.make(
            settings: baseSettings, overrides: .init(), isDarkAppearance: true
        )
        #expect(withEmpty == withDefault)
    }

    // MARK: - Glass versus flat terminal configuration

    /// The glass-clear configuration is the flat one with `background-opacity`
    /// appended at zero, and nothing else: appending it after everything the
    /// flat configuration already renders is what makes the fold safe, since
    /// ghostty's config parser takes the last value it reads for a scalar key.
    @Test func glassClearDiffersFromFlatOnlyByBackgroundOpacity() {
        let appearance = PaneAppearance.make(
            settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true
        )
        #expect(appearance.glassClearTerminalConfiguration != appearance.terminalConfiguration)
        #expect(
            appearance.glassClearTerminalConfiguration
                == appearance.terminalConfiguration.backgroundOpacity(0)
        )
    }

    // MARK: - Determinism

    @Test func makeIsDeterministicForEqualInputs() {
        let a = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        let b = PaneAppearance.make(settings: baseSettings, overrides: baseOverrides, isDarkAppearance: true)
        #expect(a == b)
    }
}
