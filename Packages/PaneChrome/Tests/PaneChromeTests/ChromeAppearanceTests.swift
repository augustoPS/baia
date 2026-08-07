import BaiaSettings
import Foundation
import Testing

@testable import PaneChrome

/// ``ChromeAppearance`` and ``resolvedStyle(setting:appearance:)``: the rule
/// that decides whether a frame draws flat or glass, and which material set
/// glass resolves to.
///
/// This suite is the whole reason the rule lives here rather than beside
/// `AppearanceObserver` in the app target: the app target has no test bundle,
/// so a resolution rule written there is a rule nothing can check for drift,
/// which is the exact failure `focusAccent` sat in for nine days (see
/// `ChromeStyle.swift`). `resolvedStyle` takes a `ChromeStyle` and a
/// `ChromeAppearance` and returns a `ResolvedChrome`; nothing here reaches
/// `NSApp` or `NSWorkspace`, which is what keeps it testable at all.
@Suite struct ChromeAppearanceTests {
    // MARK: - Flat setting

    @Test func flatSettingResolvesToFlatRegardlessOfAppearance() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .flat, appearance: appearance) == .flat)
    }

    @Test func flatSettingResolvesToFlatInLightToo() {
        let appearance = ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .flat, appearance: appearance) == .flat)
    }

    // MARK: - Glass setting, ordinary path

    @Test func glassSettingResolvesToGlassWhenTransparencyIsNotReduced() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .glass, appearance: appearance) == .glass(.dark))
    }

    @Test func glassSettingPicksTheLightMaterialSetUnderALightAppearance() {
        let appearance = ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .glass, appearance: appearance) == .glass(.light))
    }

    // MARK: - Reduce Transparency forces flat

    @Test func reduceTransparencyForcesFlatUnderGlassInDark() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .glass, appearance: appearance) == .flat)
    }

    @Test func reduceTransparencyForcesFlatUnderGlassInLight() {
        let appearance = ChromeAppearance(isDark: false, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .glass, appearance: appearance) == .flat)
    }

    @Test func reduceTransparencyIsInertUnderFlat() {
        // Flat plus Reduce Transparency is still flat: the flag has nothing to
        // override when the setting already draws nothing translucent.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .flat, appearance: appearance) == .flat)
    }

    // MARK: - Window transparency follows the opacity setting, not the chrome

    @Test func aTranslucentBackgroundMakesTheWindowTransparent() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(windowIsTransparent(backgroundOpacity: 0.42, appearance: appearance))
    }

    @Test func anOpaqueBackgroundLeavesTheWindowOpaque() {
        // Nothing to see through, so a non-opaque window would be a compositing
        // cost with no visible effect.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(!windowIsTransparent(backgroundOpacity: 1, appearance: appearance))
    }

    @Test func reduceTransparencyForcesTheWindowOpaqueEvenAtALowOpacity() {
        // The same override `resolvedStyle` makes one function above, and the
        // reason the two live side by side: accessibility intent has to win on
        // both, or someone who turns it on gets flat chrome over a window the
        // desktop still shows through.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(!windowIsTransparent(backgroundOpacity: 0.42, appearance: appearance))
    }

    @Test func windowTransparencyIgnoresTheChromeStyleEntirely() {
        // Owner decision, 2026-08-07: this follows `backgroundOpacity`, so flat
        // chrome over translucent wells is a supported look. The function takes
        // no `ChromeStyle` at all, which is what makes that unforgettable; this
        // pins that the same opacity answers the same way whatever the chrome
        // beside it resolved to.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .flat, appearance: appearance) == .flat)
        #expect(windowIsTransparent(backgroundOpacity: 0.42, appearance: appearance))
    }

    @Test func theTwoAccessibilityGatesAgreeUnderReduceTransparency() {
        // Both resolve toward the solid answer together. Written as one
        // expectation over both so a change to either that leaves the other
        // behind fails here rather than on screen.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .glass, appearance: appearance) == .flat)
        #expect(!windowIsTransparent(backgroundOpacity: 0.42, appearance: appearance))
    }

    // MARK: - The window's own chrome follows the pane theme, never the system appearance

    @Test func aDarkThemeBackgroundMakesTheWindowDark() {
        #expect(windowIsDark(paneTheme: .darkPastel))
    }

    @Test func aLightThemeBackgroundMakesTheWindowLight() {
        let paper = PaneTheme(
            background: .eightBit(0xFA, 0xFA, 0xFA),
            foreground: .eightBit(0x20, 0x20, 0x20),
            focusedAccent: .eightBit(0x00, 0x5F, 0xD5),
            ansi: PaneTheme.darkPastel.ansi
        )
        #expect(!windowIsDark(paneTheme: paper))
    }

    @Test func windowIsDarkReusesRGBsOwnDarkTestRatherThanASecondFormula() {
        // Pinned as a direct comparison against `RGB.isDark` rather than as two
        // independent expectations, so a second luminance mapping introduced
        // here — the exact drift `PaneTheme.readable`'s own doc comment warns
        // about — fails this test even if it happened to agree with the two
        // cases above by coincidence.
        let theme = PaneTheme(
            background: .eightBit(0x40, 0x60, 0x80),
            foreground: PaneTheme.darkPastel.foreground,
            focusedAccent: PaneTheme.darkPastel.focusedAccent,
            ansi: PaneTheme.darkPastel.ansi
        )
        #expect(windowIsDark(paneTheme: theme) == theme.background.isDark)
    }

    @Test func windowIsDarkBoundaryMatchesRGBsOwnDarkTestThreshold() {
        // `RGB.isDark` is libghostty's own test, `0.299r + 0.587g + 0.114b <
        // 128` on 0...255 — not WCAG relative luminance, which is what
        // `readable(_:on:minimumRatio:)` grades contrast with instead. Pinned
        // here at the neutral grey where that formula flips. `RGB.eightBit`
        // divides by 255 into a `Double` and `isDark` multiplies back by 255,
        // and that round trip does not land on the same integer boundary
        // 0...255 arithmetic would suggest: measured directly, 127 is the
        // last grey the test calls dark and 128 the first it calls light, not
        // 128/129 as `128 * 0.299 + 128 * 0.587 + 128 * 0.114 < 128` alone
        // would imply. Pinning the measured value rather than the naive one
        // is the point — a threshold "derived" by eye here would be exactly
        // the second, silently-drifting mapping this whole function exists to
        // avoid. The choice of formula, not just its outcome, is what this
        // test and `windowIsDarkReusesRGBsOwnDarkTestRatherThan…` together pin.
        let lastDark = PaneTheme(
            background: .eightBit(0x7F, 0x7F, 0x7F),
            foreground: PaneTheme.darkPastel.foreground,
            focusedAccent: PaneTheme.darkPastel.focusedAccent,
            ansi: PaneTheme.darkPastel.ansi
        )
        let firstLight = PaneTheme(
            background: .eightBit(0x80, 0x80, 0x80),
            foreground: PaneTheme.darkPastel.foreground,
            focusedAccent: PaneTheme.darkPastel.focusedAccent,
            ansi: PaneTheme.darkPastel.ansi
        )
        #expect(windowIsDark(paneTheme: lastDark))
        #expect(!windowIsDark(paneTheme: firstLight))
    }

    // MARK: - Backdrop blur needs the setting *and* a window to see through

    @Test func blurAppliesTheParityRadiusWhenTheSettingAndTheWindowBothAllowIt() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(
            windowBlurRadius(backgroundBlur: true, backgroundOpacity: 0.42, appearance: appearance)
                == parityBlurRadius
        )
    }

    @Test func theParityRadiusIsGhosttysOwnDefaultForBackgroundBlurTrue() {
        // Pinned as a number rather than only referred to by name, because the
        // number is the whole point: ghostty 1.3.1 documents `background-blur =
        // true` as "the default blur intensity of 20", and baia's setting is the
        // same boolean. A change here is a decision to stop matching the
        // terminal this app replaces, and it should have to be typed.
        #expect(parityBlurRadius == 20)
    }

    @Test func theBlurSettingOffMeansNoBlurEvenThroughATransparentWindow() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(windowIsTransparent(backgroundOpacity: 0.42, appearance: appearance))
        #expect(
            windowBlurRadius(backgroundBlur: false, backgroundOpacity: 0.42, appearance: appearance) == 0
        )
    }

    @Test func anOpaqueWindowGetsNoBlurEvenWithTheSettingOn() {
        // There is nothing behind an opaque window to blur, so this would be a
        // compositor pass with no visible effect — the same reason
        // `windowIsTransparent` leaves that case alone.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(windowBlurRadius(backgroundBlur: true, backgroundOpacity: 1, appearance: appearance) == 0)
    }

    @Test func reduceTransparencyForcesNoBlurThroughTheTransparencyGate() {
        // The third gate reading `reduceTransparency`, and the reason it does not
        // read the flag itself: it defers to `windowIsTransparent`, which already
        // resolves to opaque here. Kept beside the other two so all three
        // accessibility answers are visible at once.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(!windowIsTransparent(backgroundOpacity: 0.42, appearance: appearance))
        #expect(windowBlurRadius(backgroundBlur: true, backgroundOpacity: 0.42, appearance: appearance) == 0)
    }

    @Test func allThreeAccessibilityGatesAgreeUnderReduceTransparency() {
        // The `theTwoAccessibilityGatesAgreeUnderReduceTransparency` expectation
        // above, widened as the third gate landed. One test over all three so a
        // change to any that leaves the others behind fails here rather than on
        // screen: flat chrome, an opaque window, and no backdrop blur are one
        // answer to one setting.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .glass, appearance: appearance) == .flat)
        #expect(!windowIsTransparent(backgroundOpacity: 0.42, appearance: appearance))
        #expect(windowBlurRadius(backgroundBlur: true, backgroundOpacity: 0.42, appearance: appearance) == 0)
    }

    @Test func blurIgnoresTheChromeStyleTheSameWayTransparencyDoes() {
        // Takes no `ChromeStyle`, for the reason `windowIsTransparent` does not:
        // this follows the terminal settings, so flat chrome over blurred,
        // translucent wells is a supported look rather than a contradiction.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .flat, appearance: appearance) == .flat)
        #expect(
            windowBlurRadius(backgroundBlur: true, backgroundOpacity: 0.42, appearance: appearance)
                == parityBlurRadius
        )
    }

    // MARK: - Reduce Motion does not affect the resolved style

    @Test func reduceMotionDoesNotChangeWhichStyleResolves() {
        // Reduce Motion governs the lift's transition (Task 6), not whether
        // glass renders at all, so it must not appear on either side of this
        // resolution.
        let withMotion = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        let reduced = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: true)
        #expect(resolvedStyle(setting: .glass, appearance: withMotion) == resolvedStyle(setting: .glass, appearance: reduced))
    }

    // MARK: - MaterialSet carries the right token table

    @Test func darkMaterialSetCarriesTheDarkChromeMaterialsFills() {
        let set = MaterialSet.dark
        #expect(set.fillChrome == ChromeMaterials.Dark.fillChrome)
        #expect(set.fillSidebar == ChromeMaterials.Dark.fillSidebar)
        #expect(set.fillThick == ChromeMaterials.Dark.fillThick)
        #expect(set.fillMenu == ChromeMaterials.Dark.fillMenu)
        #expect(set.rimTopAlpha == ChromeMaterials.Dark.rimTopAlpha)
        #expect(set.rimBottomAlpha == ChromeMaterials.Dark.rimBottomAlpha)
        #expect(set.shadowWindow == ChromeMaterials.Dark.shadowWindow)
        #expect(set.shadowPopover == ChromeMaterials.Dark.shadowPopover)
    }

    @Test func lightMaterialSetCarriesTheLightChromeMaterialsFills() {
        let set = MaterialSet.light
        #expect(set.fillChrome == ChromeMaterials.Light.fillChrome)
        #expect(set.fillSidebar == ChromeMaterials.Light.fillSidebar)
        #expect(set.fillThick == ChromeMaterials.Light.fillThick)
        #expect(set.fillMenu == ChromeMaterials.Light.fillMenu)
        #expect(set.rimTopAlpha == ChromeMaterials.Light.rimTopAlpha)
        #expect(set.rimBottomAlpha == ChromeMaterials.Light.rimBottomAlpha)
        #expect(set.shadowWindow == ChromeMaterials.Light.shadowWindow)
        #expect(set.shadowPopover == ChromeMaterials.Light.shadowPopover)
    }

    // MARK: - Equatable, for tests and callers that diff a resolution

    @Test func resolvedChromeFlatEqualsFlat() {
        #expect(ResolvedChrome.flat == ResolvedChrome.flat)
    }

    @Test func resolvedChromeGlassComparesByMaterialSet() {
        #expect(ResolvedChrome.glass(.dark) != ResolvedChrome.glass(.light))
        #expect(ResolvedChrome.glass(.dark) == ResolvedChrome.glass(.dark))
    }

    @Test func resolvedChromeFlatNeverEqualsGlass() {
        #expect(ResolvedChrome.flat != ResolvedChrome.glass(.dark))
    }

    // MARK: - ChromeAppearance itself

    @Test func chromeAppearanceIsEquatable() {
        let a = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        let b = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        let c = ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        #expect(a == b)
        #expect(a != c)
    }
}
