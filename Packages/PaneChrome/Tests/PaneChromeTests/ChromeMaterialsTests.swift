import Foundation
import Testing

@testable import PaneChrome

/// Pins the vitreous token literals this package carries as tested constants,
/// the same argument as ``RGBTests`` for ``RGB`` and the ghostty unbind table:
/// a token edit is a reviewed diff against a failing test, not a silent
/// drift between `design/vitreous/tokens/*.css` and the Swift copy of it.
///
/// Every literal here is transcribed from `materials.css` and `appearance.css`,
/// not computed, so each test names the CSS custom property it pins in its
/// comment and the exact rgba/duration the token file spells.
@Suite struct ChromeMaterialsTests {
    // MARK: - Dark fills (materials.css, the `:root` scope)

    @Test func chromeFillMatchesMatFillChromeInDark() {
        // --mat-fill-chrome: rgba(18, 20, 24, 0.44)
        #expect(ChromeMaterials.Dark.fillChrome == RGBA(red: 18, green: 20, blue: 24, alpha: 0.44))
    }

    @Test func sidebarFillMatchesMatFillSidebarInDark() {
        // --mat-fill-sidebar: rgba(18, 20, 24, 0.34)
        #expect(ChromeMaterials.Dark.fillSidebar == RGBA(red: 18, green: 20, blue: 24, alpha: 0.34))
    }

    @Test func thickFillMatchesMatFillThickInDark() {
        // --mat-fill-thick: rgba(22, 24, 28, 0.52)
        #expect(ChromeMaterials.Dark.fillThick == RGBA(red: 22, green: 24, blue: 28, alpha: 0.52))
    }

    @Test func menuFillMatchesMatFillMenuInDark() {
        // --mat-fill-menu: rgba(30, 32, 37, 0.58)
        #expect(ChromeMaterials.Dark.fillMenu == RGBA(red: 30, green: 32, blue: 37, alpha: 0.58))
    }

    // MARK: - Dark rims (materials.css --lens-rim, appearance.css --rim-top/--rim-bottom)

    @Test func rimTopAlphaMatchesDarkRimTop() {
        // --rim-top is declared in color.css's :root (dark base) and read by
        // --lens-rim's `inset 0 0.5px 0 var(--rim-top)`. The alpha vitreous
        // documents for the dark lens rim in README.md is 42% white.
        #expect(ChromeMaterials.Dark.rimTopAlpha == 0.42)
    }

    @Test func rimBottomAlphaMatchesDarkRimBottom() {
        // The dark trailing rim README documents at 38% black.
        #expect(ChromeMaterials.Dark.rimBottomAlpha == 0.38)
    }

    // MARK: - Light fills (appearance.css [data-appearance="light"])

    @Test func chromeFillMatchesMatFillChromeInLight() {
        // --mat-fill-chrome: rgba(252, 252, 254, 0.74)
        #expect(ChromeMaterials.Light.fillChrome == RGBA(red: 252, green: 252, blue: 254, alpha: 0.74))
    }

    @Test func sidebarFillMatchesMatFillSidebarInLight() {
        // --mat-fill-sidebar: rgba(250, 250, 252, 0.60)
        #expect(ChromeMaterials.Light.fillSidebar == RGBA(red: 250, green: 250, blue: 252, alpha: 0.60))
    }

    @Test func thickFillMatchesMatFillThickInLight() {
        // --mat-fill-thick: rgba(255, 255, 255, 0.88)
        #expect(ChromeMaterials.Light.fillThick == RGBA(red: 255, green: 255, blue: 255, alpha: 0.88))
    }

    @Test func menuFillMatchesMatFillMenuInLight() {
        // --mat-fill-menu: rgba(255, 255, 255, 0.86)
        #expect(ChromeMaterials.Light.fillMenu == RGBA(red: 255, green: 255, blue: 255, alpha: 0.86))
    }

    @Test func rimTopAlphaMatchesLightRimTop() {
        // [data-appearance="light"] --rim-top: rgba(255, 255, 255, 0.86)
        #expect(ChromeMaterials.Light.rimTopAlpha == 0.86)
    }

    @Test func rimBottomAlphaMatchesLightRimBottom() {
        // [data-appearance="light"] --rim-bottom: rgba(0, 0, 0, 0.10)
        #expect(ChromeMaterials.Light.rimBottomAlpha == 0.10)
    }

    // MARK: - Shadows (materials.css :root, appearance.css light override)

    @Test func windowShadowMatchesShadowWindowInDark() {
        // --shadow-window: 0 26px 70px rgba(0,0,0,.62), 0 0 0 0.5px rgba(255,255,255,.14)
        let shadow = ChromeMaterials.Dark.shadowWindow
        #expect(shadow.dropOffsetY == 26)
        #expect(shadow.dropBlur == 70)
        #expect(shadow.dropAlpha == 0.62)
        #expect(shadow.ringSpread == 0.5)
        #expect(shadow.ringAlpha == 0.14)
    }

    @Test func popoverShadowMatchesShadowPopoverInDark() {
        // --shadow-popover: 0 12px 38px rgba(0,0,0,.48), 0 2px 6px rgba(0,0,0,.30)
        let shadow = ChromeMaterials.Dark.shadowPopover
        #expect(shadow.dropOffsetY == 12)
        #expect(shadow.dropBlur == 38)
        #expect(shadow.dropAlpha == 0.48)
        #expect(shadow.secondaryOffsetY == 2)
        #expect(shadow.secondaryBlur == 6)
        #expect(shadow.secondaryAlpha == 0.30)
    }

    @Test func windowShadowMatchesShadowWindowInLight() {
        // [data-appearance="light"] --shadow-window:
        // 0 24px 64px rgba(0,0,0,.42), 0 0 0 0.5px rgba(255,255,255,.30)
        let shadow = ChromeMaterials.Light.shadowWindow
        #expect(shadow.dropOffsetY == 24)
        #expect(shadow.dropBlur == 64)
        #expect(shadow.dropAlpha == 0.42)
        #expect(shadow.ringSpread == 0.5)
        #expect(shadow.ringAlpha == 0.30)
    }

    @Test func popoverShadowMatchesShadowPopoverInLight() {
        // [data-appearance="light"] --shadow-popover:
        // 0 12px 34px rgba(0,0,0,.20), 0 1px 3px rgba(0,0,0,.12)
        let shadow = ChromeMaterials.Light.shadowPopover
        #expect(shadow.dropOffsetY == 12)
        #expect(shadow.dropBlur == 34)
        #expect(shadow.dropAlpha == 0.20)
        #expect(shadow.secondaryOffsetY == 1)
        #expect(shadow.secondaryBlur == 3)
        #expect(shadow.secondaryAlpha == 0.12)
    }

    // MARK: - Motion (motion.css :root)

    @Test func standardEaseMatchesEaseStandard() {
        // --ease-standard: cubic-bezier(0.32, 0.72, 0, 1)
        let curve = ChromeMaterials.Motion.standardEase
        #expect(curve == (0.32, 0.72, 0, 1))
    }

    @Test func liftDurationsSitInsideTheDocumentedBand() {
        // The app's two durations for the lift transition, --dur-2 (140ms) and
        // --dur-3 (220ms), the 140-220ms band the plan names.
        #expect(ChromeMaterials.Motion.liftDurationShort == 0.140)
        #expect(ChromeMaterials.Motion.liftDurationLong == 0.220)
        #expect(ChromeMaterials.Motion.liftDurationShort >= 0.140)
        #expect(ChromeMaterials.Motion.liftDurationLong <= 0.220)
    }

    // MARK: - Focus lift (Task 6's ring and shadow, on the focused pane under glass)

    @Test func liftRingMatchesTheHairlineSpecTheTaskNames() {
        // 0 0 0 0.5px rgba(255,255,255,0.22): a spread-only hairline ring, no
        // offset or blur, transcribed with `ChromeShadow.window`'s same shape
        // (a drop layer plus a ring layer) with the drop layer zeroed, since
        // the lift's outer mark is the ring alone and the drop comes from
        // ``liftShadow`` as its own, separate layer.
        #expect(ChromeMaterials.Lift.ringSpread == 0.5)
        #expect(ChromeMaterials.Lift.ringAlpha == 0.22)
    }

    @Test func liftInnerHighlightMatchesTheInsetSpecTheTaskNames() {
        // inset 0 1px 0 rgba(255,255,255,0.30): a one-point top highlight drawn
        // inside the lift's own outline, the same "bright top edge" shape the
        // lens rim uses elsewhere in this design, carried here as its own pair
        // because Task 6 spells its own alpha rather than reusing the rim's.
        #expect(ChromeMaterials.Lift.innerHighlightOffsetY == 1)
        #expect(ChromeMaterials.Lift.innerHighlightAlpha == 0.30)
    }

    @Test func liftShadowMatchesTheDropSpecTheTaskNames() {
        // 0 12px 34px rgba(0,0,0,0.6)
        let shadow = ChromeMaterials.Lift.shadow
        #expect(shadow.dropOffsetY == 12)
        #expect(shadow.dropBlur == 34)
        #expect(shadow.dropAlpha == 0.6)
        // No ring on this layer: the ring is `ringSpread`/`ringAlpha` above,
        // drawn as its own stroke rather than folded into this shadow's own
        // (unused) ring fields.
        #expect(shadow.ringSpread == 0)
        #expect(shadow.ringAlpha == 0)
    }

    // MARK: - RGBA itself

    @Test func rgbaComponentsAreOnZeroToOneAndAlphaIsSeparate() {
        // materials.css spells fills on the 0...255 scale used by rgba(); this
        // constructor accepts that scale and stores components on 0...1, the
        // same convention RGB uses, so a chrome fill and a theme colour can be
        // composited without a second conversion step at the call site.
        let fill = RGBA(red: 18, green: 20, blue: 24, alpha: 0.44)
        #expect(fill.rgb == RGB.eightBit(18, 20, 24))
        #expect(fill.alpha == 0.44)
    }

    @Test func rgbaEqualityComparesAllFourComponents() {
        let a = RGBA(red: 18, green: 20, blue: 24, alpha: 0.44)
        let b = RGBA(red: 18, green: 20, blue: 24, alpha: 0.45)
        #expect(a != b)
    }

    // MARK: - RGBA.composited(over:), Task 4's honest-approximation fill

    @Test func compositingAtZeroAlphaLeavesTheBackdropUnchanged() {
        let fill = RGBA(red: 255, green: 255, blue: 255, alpha: 0)
        let backdrop = RGB.eightBit(20, 30, 40)
        #expect(fill.composited(over: backdrop) == backdrop)
    }

    @Test func compositingAtFullAlphaIsTheFillsOwnColour() {
        let fill = RGBA(red: 18, green: 20, blue: 24, alpha: 1)
        let backdrop = RGB.eightBit(255, 255, 255)
        let result = fill.composited(over: backdrop)
        let expected = RGB.eightBit(18, 20, 24)
        // Tolerance rather than `==`: `RGB.eightBit` and the compositing formula
        // reach the same value through different floating-point paths (division
        // versus a lerp), which land a float epsilon apart rather than bit-equal.
        #expect(abs(result.red - expected.red) < 0.0001)
        #expect(abs(result.green - expected.green) < 0.0001)
        #expect(abs(result.blue - expected.blue) < 0.0001)
    }

    @Test func compositingChromeFillOverDarkBackgroundMatchesLinearInterpolation() {
        // --mat-fill-chrome over a representative dark theme background, checked
        // against the plain alpha-over-opaque formula rather than against
        // `blended` a second time, so a shared bug in both could not cancel out.
        let fill = ChromeMaterials.Dark.fillChrome
        let backdrop = RGB.eightBit(20, 20, 22)
        let result = fill.composited(over: backdrop)

        let expectedRed = 20.0 / 255 + (18.0 / 255 - 20.0 / 255) * 0.44
        let expectedGreen = 20.0 / 255 + (20.0 / 255 - 20.0 / 255) * 0.44
        let expectedBlue = 22.0 / 255 + (24.0 / 255 - 22.0 / 255) * 0.44
        #expect(abs(result.red - expectedRed) < 0.0001)
        #expect(abs(result.green - expectedGreen) < 0.0001)
        #expect(abs(result.blue - expectedBlue) < 0.0001)
    }
}

@Suite("PaneWash")
struct PaneWashTests {
    @Test func theFloorHoldsWhenTheDialIsBelowIt() {
        #expect(ChromeMaterials.PaneWash.opacity(backgroundOpacity: 0.30, floorOverride: nil) == 0.5)
    }

    @Test func theDialWinsAboveTheFloor() {
        #expect(ChromeMaterials.PaneWash.opacity(backgroundOpacity: 0.90, floorOverride: nil) == 0.90)
    }

    @Test func anOverrideReplacesTheConstantInBothDirections() {
        #expect(ChromeMaterials.PaneWash.opacity(backgroundOpacity: 0.30, floorOverride: 0.7) == 0.7)
        #expect(ChromeMaterials.PaneWash.opacity(backgroundOpacity: 0.30, floorOverride: 0.1) == 0.30)
    }

    /// The shipped floor clears the AA bound against the brightest glass this
    /// repo has measured. Diagnostics/pane-glass-legibility: the wash
    /// composites linearly, so #bbbbbb ink holds 4.5:1 when
    /// alpha >= (B - 75) / (B - 20) for a glass backdrop reading B. At
    /// B = 0x7c (glass-backdrop finding 6b, the worst recorded sample,
    /// wallpaper caveat on the sample itself) that is 49/104, about 0.4712.
    /// A future dial of the constant below this line is a legibility
    /// regression, not a taste change.
    @Test func theFloorClearsTheMeasuredBound() {
        let bound = (Double(0x7c) - 75) / (Double(0x7c) - 20)
        #expect(ChromeMaterials.PaneWash.floor >= bound)
    }
}
