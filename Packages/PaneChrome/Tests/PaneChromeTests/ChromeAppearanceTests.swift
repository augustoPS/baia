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
