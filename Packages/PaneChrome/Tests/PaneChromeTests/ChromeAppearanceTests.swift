import BaiaSettings
import Foundation
import Testing

@testable import PaneChrome

/// ``ChromeAppearance`` and ``resolvedStyle(setting:materialIsDark:appearance:)``:
/// the rule that decides whether a frame draws flat or glass, and which material
/// set glass resolves to.
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
        #expect(resolvedStyle(setting: .solid, materialIsDark: true, appearance: appearance) == .flat)
    }

    @Test func flatSettingResolvesToFlatInLightToo() {
        let appearance = ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .solid, materialIsDark: false, appearance: appearance) == .flat)
    }

    // MARK: - Glass setting, ordinary path

    @Test func glassSettingResolvesToGlassWhenTransparencyIsNotReduced() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: appearance) == .glass(.dark))
    }

    @Test func glassSettingPicksTheLightMaterialSetUnderALightAppearance() {
        let appearance = ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: false, appearance: appearance) == .glass(.light))
    }

    // MARK: - The material set follows `materialIsDark`, never the system appearance

    @Test func aDarkThemeUnderALightSystemStillPicksTheDarkMaterialSet() {
        // The mismatched case, and the whole reason `materialIsDark` is its own
        // parameter: `ChromeAppearance.isDark` here is the *system's* light
        // appearance, and the material must follow the theme anyway. Before this
        // parameter existed this case resolved to `.glass(.light)` — a light
        // footer and sidebar over dark panes, which is the same mismatch
        // `windowIsDark(paneTheme:)` was added to fix one surface over.
        let lightSystem = ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: lightSystem) == .glass(.dark))
    }

    @Test func aLightThemeUnderADarkSystemStillPicksTheLightMaterialSet() {
        // The mirror of the case above, pinned separately rather than trusted to
        // fall out of it: a rule written as "follow the theme unless the system
        // is dark" would pass one of these two and fail the other.
        let darkSystem = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: false, appearance: darkSystem) == .glass(.light))
    }

    @Test func theSystemAppearanceMovingAloneDoesNotMoveTheMaterialSet() {
        // Stated as an equality across the two system appearances at one fixed
        // theme darkness, which is the acceptance in one line: the system
        // light/dark switch flipping while the theme stays put must resolve to
        // the same material both ways. `ChromeAppearance.isDark` is the only
        // field that differs between these two values.
        let darkSystem = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        let lightSystem = ChromeAppearance(isDark: false, reduceTransparency: false, reduceMotion: false)
        #expect(
            resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: darkSystem)
                == resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: lightSystem)
        )
        #expect(
            resolvedStyle(setting: .liquidGlass, materialIsDark: false, appearance: darkSystem)
                == resolvedStyle(setting: .liquidGlass, materialIsDark: false, appearance: lightSystem)
        )
    }

    @Test func chromeAppearanceIsDarkHasNoMaterialConsumerLeft() {
        // The grep this suite can actually run. `ChromeAppearance.isDark` is
        // still published by `AppearanceObserver` — it is the honest read of
        // `NSApp.effectiveAppearance` and the field's own doc comment says what
        // it is for — but no material selection may read it again. Written as
        // "every combination of the two darkness flags resolves by the theme's",
        // so a re-introduced `appearance.isDark` branch fails here whichever way
        // round it is written.
        for systemIsDark in [true, false] {
            let appearance = ChromeAppearance(
                isDark: systemIsDark,
                reduceTransparency: false,
                reduceMotion: false
            )
            #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: appearance) == .glass(.dark))
            #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: false, appearance: appearance) == .glass(.light))
        }
    }

    // MARK: - Reduce Transparency forces flat

    @Test func reduceTransparencyForcesFlatUnderGlassInDark() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: appearance) == .flat)
    }

    @Test func reduceTransparencyForcesFlatUnderGlassInLight() {
        let appearance = ChromeAppearance(isDark: false, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: false, appearance: appearance) == .flat)
    }

    @Test func reduceTransparencyForcesFlatForEitherMaterialDarknessAndEitherSystemAppearance() {
        // Reduce Transparency keeps its authority over the new parameter too,
        // which is the one thing `materialIsDark` must not be able to reach past:
        // the override lives on `ChromeAppearance` and stays there. All four
        // combinations, so a guard moved below the material branch fails here.
        for systemIsDark in [true, false] {
            for materialIsDark in [true, false] {
                let appearance = ChromeAppearance(
                    isDark: systemIsDark,
                    reduceTransparency: true,
                    reduceMotion: false
                )
                #expect(
                    resolvedStyle(setting: .liquidGlass, materialIsDark: materialIsDark, appearance: appearance) == .flat
                )
            }
        }
    }

    // MARK: - Composition happens above this function, and cannot reach past it

    /// The ordering `ConfigurationCenter.effectiveSettings` relies on, pinned
    /// from the pure side: `Settings.applying(_:)` runs first and decides only
    /// what `setting:` is, then this function reads the live appearance.
    ///
    /// The design panel dials `chromeStyle` through that composition, so an
    /// owner with Reduce Transparency on can set `.glass` and must still get
    /// `.flat`. Spelled as compose-then-resolve rather than as a bare `.glass`
    /// case, because what is under test is that no override path exists that
    /// skips the guard — a composition that reached inside `resolvedStyle`, or
    /// a guard moved below the material branch, both fail here and neither
    /// fails the four-way test above.
    @Test func anOverriddenGlassStyleStillResolvesFlatUnderReduceTransparency() {
        var flatCommitted = Settings.defaultSettings
        flatCommitted.chromeStyle = .solid
        var overrides = DesignOverrides()
        overrides.chromeStyle = .liquidGlass

        let composed = flatCommitted.applying(overrides)
        #expect(composed.chromeStyle == .liquidGlass)

        for materialIsDark in [true, false] {
            let appearance = ChromeAppearance(
                isDark: materialIsDark,
                reduceTransparency: true,
                reduceMotion: false
            )
            #expect(
                resolvedStyle(
                    setting: composed.chromeStyle,
                    materialIsDark: materialIsDark,
                    appearance: appearance
                ) == .flat
            )
        }
    }

    /// The same composition with the accessibility flag off, so the test above
    /// is known to be pinning Reduce Transparency rather than a composition that
    /// quietly failed to apply.
    @Test func anOverriddenGlassStyleResolvesGlassWhenTransparencyIsNotReduced() {
        var flatCommitted = Settings.defaultSettings
        flatCommitted.chromeStyle = .solid
        var overrides = DesignOverrides()
        overrides.chromeStyle = .liquidGlass

        let composed = flatCommitted.applying(overrides)
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(
            resolvedStyle(
                setting: composed.chromeStyle,
                materialIsDark: true,
                appearance: appearance
            ) == .glass(.dark)
        )
    }

    /// The opposite direction, and the one an owner hits by dialling opacity:
    /// `windowIsTransparent` is fed off the same composed value and its own
    /// Reduce Transparency guard is equally unreachable from an override.
    @Test func anOverriddenBackgroundOpacityStillResolvesOpaqueUnderReduceTransparency() {
        var opaqueCommitted = Settings.defaultSettings
        opaqueCommitted.backgroundOpacity = 1
        var overrides = DesignOverrides()
        overrides.backgroundOpacity = 0.42

        let composed = opaqueCommitted.applying(overrides)
        #expect(composed.backgroundOpacity == 0.42)

        let reduced = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(!windowIsTransparent(style: .liquidGlass, backgroundOpacity: composed.backgroundOpacity, appearance: reduced))
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: composed.backgroundBlur,
                backgroundOpacity: composed.backgroundOpacity,
                appearance: reduced,
                paneGlassActive: false
            ) == 0
        )

        let normal = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(windowIsTransparent(style: .liquidGlass, backgroundOpacity: composed.backgroundOpacity, appearance: normal))
    }

    @Test func reduceTransparencyIsInertUnderFlat() {
        // Flat plus Reduce Transparency is still flat: the flag has nothing to
        // override when the setting already draws nothing translucent.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .solid, materialIsDark: true, appearance: appearance) == .flat)
    }

    // MARK: - Window transparency follows opacity, except that solid is opaque

    @Test func aTranslucentBackgroundMakesTheWindowTransparent() {
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(windowIsTransparent(style: .liquidGlass, backgroundOpacity: 0.42, appearance: appearance))
    }

    @Test func anOpaqueBackgroundLeavesTheWindowOpaque() {
        // Nothing to see through, so a non-opaque window would be a compositing
        // cost with no visible effect.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(!windowIsTransparent(style: .liquidGlass, backgroundOpacity: 1, appearance: appearance))
    }

    @Test func reduceTransparencyForcesTheWindowOpaqueEvenAtALowOpacity() {
        // The same override `resolvedStyle` makes one function above, and the
        // reason the two live side by side: accessibility intent has to win on
        // both, or someone who turns it on gets flat chrome over a window the
        // desktop still shows through.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(!windowIsTransparent(style: .liquidGlass, backgroundOpacity: 0.42, appearance: appearance))
    }

    @Test func windowTransparencyStillFollowsOpacityForTheSeeThroughStyles() {
        // What survives of the 2026-08-07 decision. Ghostty parity: a
        // translucent background is a terminal setting, so an owner who dials
        // opacity down under either glass style gets the translucent wells they
        // asked for, and the material is what keeps them readable.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(windowIsTransparent(style: .liquidGlass, backgroundOpacity: 0.42, appearance: appearance))
        #expect(windowIsTransparent(style: .sheer, backgroundOpacity: 0.42, appearance: appearance))
    }

    @Test func solidIsOpaqueAtEveryOpacity() {
        // What retired of it (owner, 2026-08-15). `flat` had no material to
        // diffuse the desktop, so it inherited the window's transparency with
        // nothing between the wallpaper and the text; captures at opacity 0 and
        // 0.5 over a bright wallpaper swallowed whole lines of the transcript.
        // `solid` is the answer, and it has to hold at the bottom of the slider
        // as well as the top or it is not one.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        for opacity in [0.0, 0.25, 0.42, 0.5, 0.99, 1.0] {
            #expect(!windowIsTransparent(style: .solid, backgroundOpacity: opacity, appearance: appearance))
        }
    }

    @Test func theSettingsPredicateAgreesWithTheWindowRule() {
        // `ChromeStyle.usesBackgroundOpacity` is what the settings surface hides
        // the Opacity and Blur rows on; `windowIsTransparent` is what actually
        // makes solid opaque. They live in different packages and nothing but
        // this ties them together, so a change to either alone shows up as a
        // slider that is on screen and inert, or hidden while still doing
        // something. Asserted as the equivalence rather than case by case, so a
        // fourth style has to satisfy it rather than be remembered.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        for style in ChromeStyle.allCases {
            #expect(
                style.usesBackgroundOpacity
                    == windowIsTransparent(style: style, backgroundOpacity: 0.42, appearance: appearance)
            )
        }
    }

    @Test func solidTakesTheCompositorBlurDownWithIt() {
        // The free inheritance the doc comment claims: solid forces the window
        // opaque, there is nothing showing through to blur, and `windowBlurRadius`
        // reads that rather than restating the rule. Asserted with
        // `backgroundBlur: true` so a regression that stopped inheriting would
        // show as a live blur rather than as a setting that happened to be off.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(
            windowBlurRadius(
                style: .solid,
                backgroundBlur: true,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: false
            ) == 0
        )
    }

    @Test func theTwoAccessibilityGatesAgreeUnderReduceTransparency() {
        // Both resolve toward the solid answer together. Written as one
        // expectation over both so a change to either that leaves the other
        // behind fails here rather than on screen.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: appearance) == .flat)
        #expect(!windowIsTransparent(style: .liquidGlass, backgroundOpacity: 0.42, appearance: appearance))
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
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: true,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: false
            ) == parityBlurRadius
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
        #expect(windowIsTransparent(style: .liquidGlass, backgroundOpacity: 0.42, appearance: appearance))
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: false,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: false
            ) == 0
        )
    }

    @Test func anOpaqueWindowGetsNoBlurEvenWithTheSettingOn() {
        // There is nothing behind an opaque window to blur, so this would be a
        // compositor pass with no visible effect — the same reason
        // `windowIsTransparent` leaves that case alone.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: true,
                backgroundOpacity: 1,
                appearance: appearance,
                paneGlassActive: false
            ) == 0
        )
    }

    @Test func reduceTransparencyForcesNoBlurThroughTheTransparencyGate() {
        // The third gate reading `reduceTransparency`, and the reason it does not
        // read the flag itself: it defers to `windowIsTransparent`, which already
        // resolves to opaque here. Kept beside the other two so all three
        // accessibility answers are visible at once.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(!windowIsTransparent(style: .liquidGlass, backgroundOpacity: 0.42, appearance: appearance))
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: true,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: false
            ) == 0
        )
    }

    @Test func allThreeAccessibilityGatesAgreeUnderReduceTransparency() {
        // The `theTwoAccessibilityGatesAgreeUnderReduceTransparency` expectation
        // above, widened as the third gate landed. One test over all three so a
        // change to any that leaves the others behind fails here rather than on
        // screen: flat chrome, an opaque window, and no backdrop blur are one
        // answer to one setting.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: true, reduceMotion: false)
        #expect(resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: appearance) == .flat)
        #expect(!windowIsTransparent(style: .liquidGlass, backgroundOpacity: 0.42, appearance: appearance))
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: true,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: false
            ) == 0
        )
    }

    @Test func blurIgnoresTheChromeStyleTheSameWayTransparencyDoes() {
        // Takes no `ChromeStyle`, for the reason `windowIsTransparent` does not:
        // this follows the terminal settings, so flat chrome over blurred,
        // translucent wells is a supported look rather than a contradiction.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(resolvedStyle(setting: .solid, materialIsDark: true, appearance: appearance) == .flat)
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: true,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: false
            ) == parityBlurRadius
        )
    }

    @Test func glassPanesTurnTheCompositorBlurOff() {
        // Pane-as-glass constraint 3. Every other gate here says yes — the
        // setting is on, the window is transparent, no accessibility flag is
        // overruling anything — and the radius is still `0`, because a glass
        // plane behind every pane is already the stronger low-pass and the
        // compositor pass under it buys nothing. `Diagnostics/pane-glass-blur`
        // measured both halves of that: the blur under a plane is invisible
        // (mean +0.3/255) and the plane retains 1.5% of fine detail against the
        // compositor's 3.7%.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: true,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: true
            ) == 0
        )
    }

    @Test func flatKeepsTheParityBlur() {
        // The other side of the same gate, and the reason it is a parameter
        // rather than a removal: with no plane in the way there is nothing else
        // lensing the desktop, so flat keeps the ghostty-parity radius it has
        // always had.
        let appearance = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        #expect(
            windowBlurRadius(
                style: .liquidGlass,
                backgroundBlur: true,
                backgroundOpacity: 0.42,
                appearance: appearance,
                paneGlassActive: false
            ) == parityBlurRadius
        )
    }

    // MARK: - Reduce Motion does not affect the resolved style

    @Test func reduceMotionDoesNotChangeWhichStyleResolves() {
        // Reduce Motion governs the lift's transition (Task 6), not whether
        // glass renders at all, so it must not appear on either side of this
        // resolution.
        let withMotion = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false)
        let reduced = ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: true)
        #expect(
            resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: withMotion)
                == resolvedStyle(setting: .liquidGlass, materialIsDark: true, appearance: reduced)
        )
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
