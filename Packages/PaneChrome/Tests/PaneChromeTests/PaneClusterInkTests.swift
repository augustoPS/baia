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

    @Test func theNoticeInkIsTheAlertTierAskedOnThePillsFace() {
        // One derivation of a tier's colour, not a second red picked here. The
        // footer built its notice segment at `.alert` and asked
        // `theme.color(for:focused:on:)` for the ink; the capsule asks the same
        // function the same question, differing only in the surface it names.
        // The footer was deleted on 2026-08-13 and the tier stayed, because
        // `.alert` is the tier reserved for "act now" and a refusal is the
        // loudest thing a pane says.
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

    // MARK: - The operation ink

    /// A theme whose `warn` sits on the pill's glass face, so the raw palette
    /// blend cannot clear the floor and the chain has to move it.
    ///
    /// Built the way ``alertIsTheFace`` is, but through `warn`'s own
    /// construction rather than by naming a colour: `PaneTheme.warn` is
    /// `background.blended(with: ansi[3], fraction: 0.75)`, so an `ansi[3]` set
    /// to the measured face byte lands the blend near it rather than exactly on
    /// it. That is the realistic version of the failure — a theme whose yellow
    /// is the colour of the surface it is printed on — and it is sharper than a
    /// hand-picked near-miss because the arithmetic, not the author, chose it.
    private let warnIsNearTheFace = PaneTheme(
        background: RGB.eightBit(0x36, 0x36, 0x38),
        foreground: RGB.eightBit(0xBB, 0xBB, 0xBB),
        focusedAccent: RGB.eightBit(0xB5, 0xD5, 0xFF),
        ansi: [
            RGB.eightBit(0x00, 0x00, 0x00),
            RGB.eightBit(0xFF, 0x55, 0x55),
            RGB.eightBit(0x55, 0xFF, 0x55),
            RGB.eightBit(0x36, 0x36, 0x38),
        ]
    )

    @Test func theOperationInkClearsTheTextFloorOnEveryChrome() {
        // Same reason the notice is graded: `theme.warn` is a hue-bearing blend
        // rather than a luminance tier, so nothing guarantees it clears the
        // floor on the pill's face. `warn` needs the chain more than `alert`
        // does — it is blended three quarters of the way *toward* the
        // background, so it starts nearer the surface it is drawn on.
        for theme in everyTheme + [warnIsNearTheFace] {
            for chrome in [ResolvedChrome.flat, glass] {
                let face = PaneClusterInk.worstFace(theme: theme, chrome: chrome)
                let ink = PaneClusterInk.operationInk(theme: theme, chrome: chrome)
                #expect(ink.contrastRatio(against: face) >= PaneTheme.minimumTextContrast)
            }
        }
    }

    @Test func aThemeWhoseWarnIsTheFaceIsRepairedRatherThanDrawnInvisible() {
        // The case the floor exists for. Undecided, this theme's `warn` cannot
        // be found on the pill; the chain must move it. The first `#expect` is
        // what makes the second one evidence: if the raw blend already cleared
        // the floor, the repair would be untested and the test would pass on a
        // `operationInk` that did no grading at all.
        let face = PaneClusterInk.worstFace(theme: warnIsNearTheFace, chrome: glass)
        #expect(
            warnIsNearTheFace.warn.contrastRatio(against: face) < PaneTheme.minimumTextContrast
        )

        let ink = PaneClusterInk.operationInk(theme: warnIsNearTheFace, chrome: glass)
        #expect(ink != warnIsNearTheFace.warn)
        #expect(ink.contrastRatio(against: face) >= PaneTheme.minimumTextContrast)
    }

    /// **The reservation of alert, which is the load-bearing decision here.**
    ///
    /// The footer drew the operation at `.warn` and said why: alert stays
    /// reserved for conflicted files and for an agent asking, so that one colour
    /// means "act now" and a mid-rebase pane does not cry it the whole time it
    /// is mid-rebase. The notice — the pill's *other* rehomed fact — is drawn at
    /// alert. If the operation took alert too, the pill would wear the loud
    /// colour continuously for as long as a rebase is unresolved and the
    /// three-second sentence that actually needs the eye would arrive in a
    /// colour already on screen.
    ///
    /// Asserted as the two inks *differing* rather than as "operationInk ==
    /// warn tier", which would restate the implementation.
    ///
    /// **The guarantee is conditional, and measurement is what made that
    /// honest.** The first version of this test asserted the two inks differ
    /// unconditionally and failed on the light `paper` theme under glass, where
    /// the pill's face is mid-grey (0.47 luminance) and *both* tiers exhaust
    /// ``PaneTheme/readable(_:on:minimumRatio:)``'s fallback chain and land on
    /// its last resort, black. That is the shared repair chain's behaviour and
    /// not this derivation's — ``noticeInk(theme:chrome:)`` had it before
    /// `operationInk` existed — and a test demanding otherwise would be
    /// demanding that one of the two facts ship under the contrast floor in
    /// order to stay a different colour. Legibility outranks the distinction, so
    /// the collapse is stated here rather than engineered away.
    ///
    /// What *is* unconditional is the tier asked for: the operation never asks
    /// for alert, so on every theme where the palette and the chain leave room
    /// for two colours there are two colours. Both halves are asserted rather
    /// than assumed, so a change that collapsed the tiers on a theme that did
    /// have room fails here rather than passing as "another collapse".
    ///
    /// **The permitted collapse is named, not counted, and the counting version
    /// was near-inert.** This asserted `distinguishable > collapsed`, which is
    /// 7 > 1 over these fixtures: three more of the eight pairs could start
    /// collapsing and it would still pass, `darkPastel/glass` — the shipped
    /// theme, the one users actually look at — among them. An allowlist fails on
    /// the first pair that joins the set, which is the claim the prose above
    /// makes.
    ///
    /// **And the escape hatch says what it checks.** The doc used to call this
    /// permission "the chain's last resort" while the assertion was
    /// `operation == black || white`, which cannot mean that:
    /// ``PaneTheme/readable(_:on:minimumRatio:)`` walks `[candidate, blend@0.35,
    /// blend@0.70, away]` before taking a last-resort maximum over
    /// `[foreground, paleEnd, darkEnd]`, and its `away` — step 4, an ordinary
    /// success — *is* `paleEnd` or `darkEnd`. Black or white is therefore
    /// evidence of nothing about which step produced it.
    ///
    /// What is asserted instead is the chain's precondition: neither tier's
    /// palette colour could be drawn on this face at all, which is the state
    /// that forces both of them down the chain in the first place. That is a
    /// claim about *why* the collapse is excusable rather than about the byte it
    /// landed on, and it is checkable without re-walking the chain here (a
    /// second copy of the thing under test).
    ///
    /// **It is not, however, stricter, and saying so would repeat the mistake
    /// this fix is for.** Swept over ~2000 synthetic themes (background,
    /// `ansi[1]` and `ansi[3]` varied, both chromes), the old permission and this
    /// one accept and reject exactly the same collapses: zero divergences in
    /// either direction. Every collapse reachable that way has both tiers under
    /// the floor already. The change buys honesty about what is verified, not
    /// coverage — the allowlist above is the half that adds teeth.
    @Test func theOperationIsNeverDrawnInTheNoticesAlertInk() {
        // Named, so the allowlist can name. `warnIsNearTheFace` is the fixture
        // built for the warn tier specifically and joins the same sweep.
        let fixtures: [(name: String, theme: PaneTheme)] = [
            ("darkPastel", .darkPastel),
            ("paper", paper),
            ("alertIsTheFace", alertIsTheFace),
            ("warnIsNearTheFace", warnIsNearTheFace),
        ]

        // The one pair whose palette and face leave no room for two legible
        // colours, measured rather than assumed: `paper` is white-backed, so
        // under glass the pill's face is a mid-grey (0.47 luminance) that both a
        // muted red and a muted yellow fail against, and both tiers exhaust the
        // chain onto black. Every other pair here keeps two colours. A fifth
        // entry does not belong in this list until someone has looked at the
        // theme and decided the collapse is legibility winning rather than the
        // reservation breaking.
        let mayCollapse: Set<String> = ["paper/glass"]

        for (name, theme) in fixtures {
            for (chromeName, chrome) in [("flat", ResolvedChrome.flat), ("glass", glass)] {
                let pair = "\(name)/\(chromeName)"
                let face = PaneClusterInk.worstFace(theme: theme, chrome: chrome)
                let operation = PaneClusterInk.operationInk(theme: theme, chrome: chrome)
                let notice = PaneClusterInk.noticeInk(theme: theme, chrome: chrome)

                // The tier asked for is warn's, never alert's, whatever the
                // repair chain does downstream of the request.
                #expect(operation == theme.color(for: .warn, focused: false, on: face))

                #expect(
                    (operation == notice) == mayCollapse.contains(pair),
                    (operation == notice)
                        ? "\(pair) collapsed onto \(operation.hexString) and is not in the allowlist"
                        : "\(pair) is allowed to collapse but no longer does; drop it from the allowlist"
                )

                guard operation == notice else { continue }

                // The sanctioned reason, checked as the chain's own
                // precondition: a collapse is only excusable when neither tier's
                // palette colour could be drawn at all on this face, which is
                // what pushes both of them past every repair candidate. A theme
                // whose warn or alert clears the floor on its own has a better
                // answer available and must not be here.
                let floor = PaneTheme.minimumTextContrast
                #expect(
                    theme.warn.contrastRatio(against: face) < floor,
                    "\(pair): warn clears the floor on its own, so the chain was not exhausted"
                )
                #expect(
                    theme.alert.contrastRatio(against: face) < floor,
                    "\(pair): alert clears the floor on its own, so the chain was not exhausted"
                )
                // And the colour actually drawn does clear it, which is what the
                // collapse was accepted in exchange for.
                #expect(operation.contrastRatio(against: face) >= floor)
            }
        }
    }

    @Test func theOperationInkIsTheWarnTierAskedOnThePillsFace() {
        // One derivation of a tier's colour, not a second yellow picked here.
        // The footer built its operation segment at `.warn` and asked
        // `theme.color(for:focused:on:)` for the ink; the capsule asks the same
        // function the same question, differing only in the surface it names.
        // The tier survives the footer's deletion on its own argument: a
        // half-finished rebase changes what every other fact means, which is a
        // warning, while `.alert` stays reserved for conflicts and for an agent
        // asking, so that one colour means "act now".
        for theme in everyTheme + [warnIsNearTheFace] {
            for chrome in [ResolvedChrome.flat, glass] {
                let face = PaneClusterInk.worstFace(theme: theme, chrome: chrome)
                #expect(
                    PaneClusterInk.operationInk(theme: theme, chrome: chrome)
                        == theme.color(for: .warn, focused: false, on: face)
                )
            }
        }
    }

    @Test func focusDoesNotMoveTheOperationInk() {
        // `focused` swaps only the `strong` tier for the focus accent, and
        // `.warn` is not that tier — which is what makes the literal `false`
        // inside `operationInk` a decision rather than a dropped wire.
        for theme in everyTheme + [warnIsNearTheFace] {
            for chrome in [ResolvedChrome.flat, glass] {
                let face = PaneClusterInk.worstFace(theme: theme, chrome: chrome)
                #expect(
                    theme.color(for: .warn, focused: true, on: face)
                        == theme.color(for: .warn, focused: false, on: face)
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
