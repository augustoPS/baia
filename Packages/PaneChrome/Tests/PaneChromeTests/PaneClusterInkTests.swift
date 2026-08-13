import Foundation
import Testing

@testable import PaneChrome

/// The pill's worst face, and the notice ink graded on it.
///
/// Every case here is a way the grading goes wrong: a face that ignores a layer
/// the pill paints, a correction applied in the direction that makes the grade
/// laxer, a notice ink taken raw from the palette without going through the
/// repair chain, and a theme whose alert colour is the one the chain has to
/// rescue.
@Suite struct PaneClusterInkTests {
    /// The default dark theme, and glass, which is the pair
    /// `Diagnostics/cluster-legibility` runs its resting arm on.
    private let glass = ResolvedChrome.glass(.dark)

    /// A theme whose `alert` sits almost exactly on the pill's glass face, so
    /// the raw palette colour cannot clear the floor and the repair chain has
    /// to move it.
    ///
    /// Not synthetic in kind: `#363638` is the byte value
    /// `Diagnostics/cluster-legibility` *measures* the resting pill compositing
    /// to over the brightest backdrop, so this is a theme whose red is the
    /// colour of the surface it would be drawn on. A dark theme with a muted
    /// red is an ordinary ghostty theme (Zenburn ships `#7d5d5d`); one landing
    /// on this exact byte is the sharpest version of the same case.
    private let alertIsTheFace = PaneTheme(
        background: RGB.eightBit(0x14, 0x14, 0x14),
        foreground: RGB.eightBit(0xBB, 0xBB, 0xBB),
        focusedAccent: RGB.eightBit(0xB5, 0xD5, 0xFF),
        ansi: [
            RGB.eightBit(0x00, 0x00, 0x00),
            RGB.eightBit(0x36, 0x36, 0x38),
            RGB.eightBit(0x55, 0xFF, 0x55),
            RGB.eightBit(0xFF, 0xFF, 0x55),
        ]
    )

    /// Light in ghostty's own terms, so nothing here passes only on a dark
    /// pill.
    private let paper = PaneTheme(
        background: RGB.eightBit(0xFF, 0xFF, 0xFF),
        foreground: RGB.eightBit(0x20, 0x20, 0x20),
        focusedAccent: RGB.eightBit(0x1E, 0x5A, 0xA8),
        ansi: [
            RGB.eightBit(0x00, 0x00, 0x00),
            RGB.eightBit(0xB4, 0x11, 0x11),
            RGB.eightBit(0x0F, 0x7A, 0x0F),
            RGB.eightBit(0xA0, 0x7A, 0x00),
        ]
    )

    private var everyTheme: [PaneTheme] { [.darkPastel, paper, alertIsTheFace] }

    // MARK: - The face

    @Test func aFlatPillsFaceIsItsOwnOpaqueBackground() {
        // Opaque, so whatever is beneath composites away entirely: no bright
        // bound to survive and no space divergence to correct. A face that
        // consulted the backdrop under flat would be grading against a colour
        // the pill provably covers.
        for theme in everyTheme {
            #expect(PaneClusterInk.worstFace(theme: theme, chrome: .flat) == theme.background)
        }
    }

    @Test func theGlassFaceIsBrighterThanTheFlatOne() {
        // The whole reason the glass branch exists. A translucent pill lets the
        // backdrop through, so its worst face is lifted toward
        // `brightestMeasuredBackdrop` and text on it has less room than on the
        // opaque one. A glass face equal to (or darker than) the flat one would
        // mean a layer was dropped, which is the failure
        // `cluster-legibility`'s "if the view stopped painting the backing"
        // counterfactual describes from the pixel side.
        for theme in everyTheme where theme.background.isDark {
            let flat = PaneClusterInk.worstFace(theme: theme, chrome: .flat)
            let face = PaneClusterInk.worstFace(theme: theme, chrome: glass)
            #expect(face.relativeLuminance > flat.relativeLuminance)
        }
    }

    @Test func theGlassFaceStaysBelowTheBackdropItGradesAgainst() {
        // Both layers are dark paint over the bright bound, so the face must
        // land between the theme's background and the backdrop, never past it.
        // A face brighter than the backdrop would mean the composite ran the
        // wrong way round — fill under backdrop rather than over it.
        for theme in everyTheme where theme.background.isDark {
            let face = PaneClusterInk.worstFace(theme: theme, chrome: glass)
            #expect(
                face.relativeLuminance
                    < PaneClusterInk.brightestMeasuredBackdrop.relativeLuminance
            )
        }
    }

    @Test func theCompositingCorrectionOnlyEverMakesTheGradeStricter() {
        // The headroom is a correction toward what AppKit measures, applied in
        // the one direction that cannot let ink through under the floor: it
        // lifts the face, and a brighter face is a harder grade. Asserted as
        // the arithmetic against the uncorrected flatten, so a sign flip fails
        // here rather than shipping ink at 4.41:1 on a face reading 4.79:1.
        let theme = PaneTheme.darkPastel
        let washed = RGBA(rgb: theme.background, alpha: ChromeMaterials.PaneWash.floor)
            .composited(over: PaneClusterInk.brightestMeasuredBackdrop)
        let uncorrected = MaterialSet.dark.fillChrome.composited(over: washed)
        let face = PaneClusterInk.worstFace(theme: theme, chrome: glass)

        #expect(face.red == uncorrected.red + PaneClusterInk.compositingHeadroom)
        #expect(face.green == uncorrected.green + PaneClusterInk.compositingHeadroom)
        #expect(face.blue == uncorrected.blue + PaneClusterInk.compositingHeadroom)
        #expect(face.relativeLuminance > uncorrected.relativeLuminance)
    }

    @Test func theFaceIsTheOneTheOfferAlreadyGradesOn() {
        // One assembly. `InitOfferView.worstFace` used to own this derivation
        // and now reads it back; the constants it exposes under its own names
        // are these. If the two ever part, the sidebar offer and the capsule
        // are grading the same pill against two different faces.
        #expect(
            PaneClusterInk.brightestMeasuredBackdrop
                == RGB(red: 124.0 / 255, green: 124.0 / 255, blue: 124.0 / 255)
        )
        #expect(PaneClusterInk.compositingHeadroom == 6.0 / 255)
    }

    // MARK: - The notice ink

    @Test func theNoticeInkClearsTheTextFloorOnEveryChrome() {
        // The whole point of grading it. `theme.alert` is a hue rather than a
        // luminance tier, so nothing guarantees it clears the floor on the
        // pill's own face; the repair chain is what makes it, and this is the
        // assertion that the chain was actually consulted.
        for theme in everyTheme {
            for chrome in [ResolvedChrome.flat, glass] {
                let face = PaneClusterInk.worstFace(theme: theme, chrome: chrome)
                let ink = PaneClusterInk.noticeInk(theme: theme, chrome: chrome)
                #expect(ink.contrastRatio(against: face) >= PaneTheme.minimumTextContrast)
            }
        }
    }

    @Test func aThemeWhoseAlertIsTheFaceIsRepairedRatherThanDrawnInvisible() {
        // The case the floor exists for, and the one an ungraded ink fails.
        // Undecided, this theme's `alert` is the face byte for byte: 1.00:1,
        // a sentence the eye cannot find. The chain must move it.
        let face = PaneClusterInk.worstFace(theme: alertIsTheFace, chrome: glass)
        #expect(alertIsTheFace.alert.contrastRatio(against: face) < PaneTheme.minimumTextContrast)

        let ink = PaneClusterInk.noticeInk(theme: alertIsTheFace, chrome: glass)
        #expect(ink != alertIsTheFace.alert)
        #expect(ink.contrastRatio(against: face) >= PaneTheme.minimumTextContrast)
    }

    @Test func aThemeWhoseAlertAlreadyClearsTheFloorIsLeftAlone() {
        // The other half of "repaired rather than reassigned": the chain moves
        // only the themes that fail, and moves them only as far as the floor.
        // An ink that differed from the palette's alert on a theme that never
        // needed repairing would mean a new tier had been stated by hand.
        let theme = PaneTheme.darkPastel
        let face = PaneClusterInk.worstFace(theme: theme, chrome: .flat)
        #expect(theme.alert.contrastRatio(against: face) >= PaneTheme.minimumTextContrast)
        #expect(PaneClusterInk.noticeInk(theme: theme, chrome: .flat) == theme.alert)
    }

    @Test func theNoticeInkIsTheFootersAlertTierAskedOnThePillsFace() {
        // One derivation of a tier's colour, not a second red picked here. The
        // footer builds its notice segment at `.alert`
        // (`PaneStatusSegmentsTests.aNoticeIsAnAlertItNeverElides`) and asks
        // `theme.color(for:focused:on:)` for the ink; the capsule asks the same
        // function the same question, differing only in the surface it names.
        // A hand-picked colour here would pass every floor check above and
        // still fail this.
        for theme in everyTheme {
            for chrome in [ResolvedChrome.flat, glass] {
                let face = PaneClusterInk.worstFace(theme: theme, chrome: chrome)
                #expect(
                    PaneClusterInk.noticeInk(theme: theme, chrome: chrome)
                        == theme.color(for: .alert, focused: false, on: face)
                )
            }
        }
    }

    @Test func focusDoesNotMoveTheNoticeInk() {
        // `focused` reaches `color(for:focused:on:)` only to swap the `strong`
        // tier for the focus accent, and `.alert` is not that tier — which is
        // what makes the literal `false` inside `noticeInk` a decision rather
        // than a dropped wire. Pinned so that a palette change giving `.alert`
        // a focus variant has to come here and say so.
        for theme in everyTheme {
            for chrome in [ResolvedChrome.flat, glass] {
                let face = PaneClusterInk.worstFace(theme: theme, chrome: chrome)
                #expect(
                    theme.color(for: .alert, focused: true, on: face)
                        == theme.color(for: .alert, focused: false, on: face)
                )
            }
        }
    }
}
