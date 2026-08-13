import BaiaSettings
import Testing

@testable import PaneChrome

/// The parameterised half of ``PaneTheme``: the constants the debug design
/// panel can stand in front of.
///
/// Two arms per knob and both are load-bearing. **Nil is the identity** — an
/// undialled panel has to render precisely what shipped, and the honest way to
/// say that is to assert the adjusted derivation equals the unadjusted one field
/// by field, rather than to read the `??` and believe it. **Set moves the
/// value** — a knob wired to a site that ignores it is exactly the
/// `focusAccent` defect this codebase names repeatedly (decoded, stored, and
/// never read by the one line that mattered), and a nil-identity arm alone
/// cannot tell a working wire from a dead one.
@Suite struct PaneThemeAdjustmentsTests {
    private var theme: PaneTheme { .darkPastel }

    /// A light theme, so no arm below can pass by a dark-theme coincidence: the
    /// repair chain picks its direction off the backdrop's luminance, and a
    /// ratio dial that only ever moved on a dark palette would be a dial that
    /// works on one theme.
    private var paper: PaneTheme {
        PaneTheme(
            background: .eightBit(0xFA, 0xFA, 0xFA),
            foreground: .eightBit(0x30, 0x30, 0x30),
            focusedAccent: .eightBit(0x30, 0x60, 0xC0),
            ansi: PaneTheme.darkPastel.ansi
        )
    }

    // MARK: - Nil is the identity

    /// The value every existing call site gets, asserted empty field by field
    /// rather than by `== .none`, which would pass on a type whose fields were
    /// all replaced with non-optional defaults — the exact mistake
    /// ``BaiaSettings/DesignOverrides``' own doc comment says its optionality
    /// exists to prevent.
    @Test func noneCarriesNothing() {
        let none = PaneThemeAdjustments.none
        #expect(none.barLift == nil)
        // `actionRowMinimumRatio` and `actionRowInk` were asserted here until
        // the 2026-08-12 ruling removed the "New session" row they dialled, the
        // session header's own pair having gone the same way that morning.
        #expect(none.sectionHeaderMinimumRatio == nil)
        #expect(none.busyDotInk == nil)
    }

    /// A theme built without adjustments carries the empty value, so a call site
    /// that never heard of this type cannot accidentally be dialling one.
    @Test func aThemeStartsUnadjusted() {
        #expect(PaneTheme.darkPastel.adjustments == .none)
        #expect(theme.adjustments.barLift == nil)
    }

    /// Every derivation the adjustments reach, with nothing dialled, equals what
    /// the same derivation answered before the parameter existed. Across two
    /// themes, because half of these pick a direction off the backdrop.
    @Test func nilLeavesEveryDerivationExactlyWhereItWas() {
        for base in [theme, paper] {
            var adjusted = base
            adjusted.adjustments = .none

            #expect(adjusted.barBackground == base.barBackground)
            #expect(adjusted.busyDot == base.ok)
            #expect(adjusted.sectionHeaderInk(on: base.barBackground)
                == base.sectionHeaderInk(on: base.barBackground))
        }
    }

    /// The ink is `inkFaint` on a backdrop that already clears, which is what
    /// makes flat byte-identical: the repair is a no-op there and this is the
    /// arm that says so, rather than the prose alone. Two others were asserted
    /// beside it until 2026-08-12, the session header's and the action row's,
    /// each retiring with the row the owner's rulings removed that day.
    @Test func theUnadjustedInksAreTheFaintTierOnABarThatAlreadyClears() {
        #expect(theme.sectionHeaderInk(on: theme.barBackground) == theme.inkFaint)
    }

    /// **The backdrop these are handed is the whole question, and this arm is
    /// the one that would have caught getting it wrong.**
    ///
    /// A repair is only a no-op where the candidate already clears. On the
    /// bright-glass stand-in the sidebar's glass was measured against
    /// (`#4b4b4b`, `WorkspaceSurface.measuredBrightGlass`) it does not: the
    /// faint tier scores under the 4.5 floor there and the chain walks it two
    /// steps to near-white. So "these derivations are the identity" is true of
    /// the bar and false of that backdrop, and a drawing site that branched on
    /// `resolvedChrome` to pass the glass stand-in would have moved a pixel with
    /// every override nil.
    ///
    /// That branch was written and reverted, and this arm is why. It was tried
    /// on the sidebar's action row, which passed `barBackground` on both paths;
    /// grading it here instead walked its keycap glyph from `#898989` to
    /// `#dcdcdc` on every glass launch with every override nil, which is the
    /// rendering change a nil-moves-nothing wire may not make. Only
    /// `SurfaceTitleView`'s caps label — which was *always* graded here, so
    /// routing it through a derivation was identity — keeps the glass branch.
    ///
    /// **Both counterexamples are gone and the arm is not.** The session header
    /// was the second such row until 2026-08-12 and the action row the last, the
    /// owner's rulings that day removing both. What is measured here is a
    /// property of the repair chain against a backdrop, not of any row: the next
    /// site tempted to grade a faint ink against sampled glass is told the price
    /// before it draws, and the sole surviving reader's "glass only" claim still
    /// needs a backdrop on which the repair demonstrably fires.
    ///
    /// The numbers are asserted rather than described, so a change to `inkFaint`
    /// or to the repair chain that made the two backdrops agree would fail here
    /// instead of quietly making the prose above wrong.
    @Test func theRepairIsNotANoOpOnTheBrightGlassStandIn() {
        let brightGlass = RGB.eightBit(0x4B, 0x4B, 0x4B)
        #expect(theme.inkFaint.contrastRatio(against: brightGlass) < PaneTheme.minimumTextContrast)

        let repaired = theme.sectionHeaderInk(on: brightGlass)
        #expect(repaired != theme.inkFaint)
        #expect(repaired.contrastRatio(against: brightGlass) >= PaneTheme.minimumTextContrast)
    }

    /// The unadjusted busy dot is the constant the drawing site used to name
    /// directly, so re-pointing that site at this derivation moved no pixel.
    @Test func theUnadjustedBusyDotIsTheOkColour() {
        for base in [theme, paper] {
            #expect(base.busyDot == base.ok)
        }
    }

    // MARK: - The shapes bareGlass composed

    /// **`bareGlass` was never a field on this type, and this arm is what says
    /// so deliberately rather than by omission.**
    ///
    /// The knob itself retired on 2026-08-08, when the owner's A/B of naked
    /// native glass against the hand-drawn layer settled the question it was
    /// built to ask; these arms outlive it because what they measured is a
    /// property of *this type*, not of that knob. The reasoning below is why the
    /// suppression could not ride either channel offered here, and it is exactly
    /// what would have to be rediscovered if anyone tried to route a future
    /// glass-only behaviour through an adjustments value.
    ///
    /// The app's `chrome.bareGlass` suppressed the hand-drawn glass-era layer,
    /// and none of it landed here. Every suppression is at a drawing site that
    /// knows its own `resolvedChrome`, because the two channels this type
    /// offers — a `barLift` fraction and an ink ratio — are both **path-blind**:
    /// one adjustments value feeds the flat branch and the glass branch of the
    /// same derivation, so anything composed into it reaches flat as well.
    ///
    /// That is not a style preference, it is what the two arms below measured.
    /// A `bareGlass: Bool?` field here would be worse still: it would add one
    /// more thing that has to be nil for ``PaneThemeAdjustments/none`` to stay
    /// the identity, and it would put "which chrome is live" inside a package
    /// that deliberately does not know — this type shadows *numbers*, and
    /// glass-versus-flat is the app's question.
    ///
    /// So `.none` is untouched by the knob, and stays exactly the identity it
    /// was.
    @Test func aBarLiftOfZeroWouldMoveTheFlatBarWhichIsWhyTheKnobDoesNotComposeOne() {
        // Site 2's tempting spelling: lift the bar by nothing, so it sits on the
        // terminal background instead of being lifted off it.
        for base in [theme, paper] {
            var bare = base
            bare.adjustments.barLift = 0

            #expect(bare.barBackground == base.background)
            #expect(bare.barBackground != base.barBackground)
        }

        // And the reason it is not composed: `barBackground` is the fill the
        // **flat** chrome paints (`PaneStatusBarView.draw(_:)` filled it only
        // when `materialSet == nil`, and drew no fill at all under glass; the
        // capsule inherited that split when the footer was deleted). So
        // this value moves a flat pixel and no glass one, which is the exact
        // inverse of what the knob is for.
    }

    /// A floor of 1.0 is the floor every colour clears, since a contrast ratio
    /// cannot fall below 1:1 — so the repair chain returns its first link
    /// untouched and the ink renders its raw derivation.
    ///
    /// This was site 3's suppression, and it is deliberate un-repair: on the
    /// bright-glass stand-in the faint tier is *measurably* illegible
    /// (``theRepairIsNotANoOpOnTheBrightGlassStandIn`` pins that), and under
    /// `bareGlass` the owner was meant to see exactly that, because what the
    /// glass alone does to legibility was the thing being judged. The repair is
    /// unconditional on glass since the knob retired, which is what makes this
    /// arm a record of the alternative rather than of live behaviour.
    @Test func aRatioOfOneReturnsTheSectionHeaderInkAsItsRawDerivation() {
        let brightGlass = RGB.eightBit(0x4B, 0x4B, 0x4B)
        var bare = theme
        bare.adjustments.sectionHeaderMinimumRatio = Self.bareGlassRatio

        // Raw `inkFaint`, on the backdrop where the unsuppressed chain repairs.
        #expect(bare.sectionHeaderInk(on: brightGlass) == theme.inkFaint)

        // And the un-repair is real: what it returns is the colour the shipped
        // chain refused, below the floor 10 pt bold text is owed.
        #expect(bare.sectionHeaderInk(on: brightGlass)
            != theme.sectionHeaderInk(on: brightGlass))
        #expect(bare.sectionHeaderInk(on: brightGlass)
            .contrastRatio(against: brightGlass) < PaneTheme.minimumTextContrast)
    }

    // `theSidebarRowsRepairFiresOnTheBarItselfOnALightTheme` stood here until
    // 2026-08-12. It was the arm that narrowed `bareGlass`'s ink suppression to
    // one site, by measuring on `paper` that `inkFaint` fails the 4.5 floor
    // against `barBackground` itself, so a ratio pinned for a row graded there
    // reaches the *flat* path. It asserted that on the action row's ink, the
    // owner's ruling that day removed the row, and the derivation retired with
    // it, so the arm had no site left to pin.
    //
    // Nothing it established is unmeasured. The arm below makes the same claim
    // one layer down and on the same light theme, against
    // `sectionHeaderMinimumRatio`, which is the ratio that still exists: a pin
    // is invisible on the dark bar and a flat-path rendering change on the light
    // one. That was always the load-bearing half, this one having been the step
    // that got there.

    /// **Why the ink suppression is not spelled as a pinned ratio at all.**
    ///
    /// The suppression was narrowed to the caps label alone by an arm on the
    /// sidebar's action row, retired above with the row it measured. The
    /// remaining spelling was to pin
    /// ``PaneThemeAdjustments/sectionHeaderMinimumRatio`` to ``bareGlassRatio``.
    /// That fails here for the same reason one layer down: on the light theme the
    /// caps label's repair fires against ``PaneTheme/barBackground`` too, so a
    /// pinned ratio moves the **flat** caps label.
    ///
    /// A ratio cannot express "glass only". It is handed to
    /// ``PaneTheme/readable(_:on:minimumRatio:)`` with no idea which backdrop it
    /// is about to grade, and the flat path and the glass path go through the
    /// same derivation with the same adjustments value. So the knob cannot ride
    /// this channel: `SurfaceTitleView.labelInk` suppresses at its own site, on
    /// the `.glass` branch it already has, where `resolvedChrome` is known.
    ///
    /// Kept because it is the arm that would fail again if someone moved the
    /// suppression back into the ratio to "simplify" it.
    @Test func aPinnedRatioCannotExpressGlassOnlyBecauseFlatSharesTheDerivation() {
        // Dark: the pin is invisible on the bar, which is what made the ratio
        // spelling look correct.
        var bareDark = theme
        bareDark.adjustments.sectionHeaderMinimumRatio = Self.bareGlassRatio
        #expect(bareDark.sectionHeaderInk(on: theme.barBackground)
            == theme.sectionHeaderInk(on: theme.barBackground))

        // Light: it is not, so the same pin is a flat-path rendering change.
        var barePaper = paper
        barePaper.adjustments.sectionHeaderMinimumRatio = Self.bareGlassRatio
        #expect(barePaper.sectionHeaderInk(on: paper.barBackground)
            != paper.sectionHeaderInk(on: paper.barBackground))
    }

    /// 1:1, the floor no pair of colours can fail, which is how the repair chain
    /// is switched off through the channel that was built to raise it.
    ///
    /// Named here beside the arms that prove what it does rather than left as a
    /// literal at the app's composition site, so a reader who finds the `1.0`
    /// there has somewhere to go.
    static let bareGlassRatio: Double = 1

    // MARK: - Set moves the value

    /// `barLift` moves the bar off the terminal background, and moves it in the
    /// direction it names: a larger fraction lands further from `background`.
    @Test func barLiftMovesTheBarAndItsDirectionIsTheOneItNames() {
        var lifted = theme
        lifted.adjustments.barLift = 0.30

        #expect(lifted.barBackground != theme.barBackground)
        #expect(lifted.barBackground == theme.background.blended(with: theme.foreground, fraction: 0.30))
        // Further from the terminal background than the shipped 0.08, which is
        // what "lifted further" has to mean for the knob to be legible.
        #expect(lifted.barBackground.contrastRatio(against: theme.background)
            > theme.barBackground.contrastRatio(against: theme.background))
    }

    /// Zero is a value and not an absence: dialling the lift to nothing has to
    /// collapse the bar onto the terminal background rather than fall back to
    /// 0.08. This is the arm that would fail on an `if let value, value > 0`
    /// spelling.
    @Test func aZeroBarLiftCollapsesTheBarRatherThanFallingBackToTheConstant() {
        var flattened = theme
        flattened.adjustments.barLift = 0
        #expect(flattened.barBackground == theme.background)
        #expect(flattened.barBackground != theme.barBackground)
    }

    /// Chrome ink follows the bar it is graded on, which is the coupling
    /// `DesignOverrides.Chrome.barLift`'s doc comment warns about: one slider,
    /// two things move.
    @Test func barLiftAlsoMovesTheInkGradedAgainstTheBar() {
        var lifted = theme
        lifted.adjustments.barLift = 0.55
        #expect(lifted.color(for: .faint, focused: false)
            != theme.color(for: .faint, focused: false))
    }

    /// Raising the floor walks the repair chain further up, on a backdrop where
    /// the faint tier already clears the shipped 4.5 and would otherwise be
    /// returned untouched. That is the whole claim the ratio dial makes.
    @Test func raisingASectionHeaderRatioBrightensTheInkItRepairs() {
        let backdrop = theme.barBackground
        var raised = theme
        raised.adjustments.sectionHeaderMinimumRatio = 12

        let shipped = theme.sectionHeaderInk(on: backdrop)
        let dialled = raised.sectionHeaderInk(on: backdrop)
        #expect(dialled != shipped)
        #expect(dialled.contrastRatio(against: backdrop) > shipped.contrastRatio(against: backdrop))
        #expect(dialled.contrastRatio(against: backdrop) >= 12)
    }

    /// The same claim on a light theme as well as a dark one: the chain picks
    /// its direction off the backdrop's luminance, so a ratio that only worked
    /// downhill would pass a dark-only arm.
    ///
    /// Asserted on the section header's ratio, which is the only one left. It
    /// ran on the action row's until 2026-08-12 and the session header's until
    /// that morning, both retiring with the rows the owner's rulings removed;
    /// what they demonstrated was the chain's direction, which is a property of
    /// the chain rather than of the ink handed to it.
    @Test func raisingASidebarRatioBrightensTheSidebarInk() {
        for base in [theme, paper] {
            let backdrop = base.barBackground

            var raised = base
            raised.adjustments.sectionHeaderMinimumRatio = 11
            #expect(raised.sectionHeaderInk(on: backdrop).contrastRatio(against: backdrop)
                > base.sectionHeaderInk(on: backdrop).contrastRatio(against: backdrop))
        }
    }

    // `eachRatioMovesOnlyItsOwnInk` stood here until 2026-08-12. It pinned that
    // a ratio reaches exactly one ink, separate fields that moved together being
    // one field with two names, and it needed two ratios to say so. The owner's
    // rulings that day removed the session header and the action row, and with
    // their derivations went every ratio but the section header's: an arm about
    // one dial not disturbing another has nothing left to disturb. It comes back
    // the day a second ink ratio does, and `DesignOverrides.Chrome.Inks` still
    // records why they would be spelled apart.

    // `aHexIsReturnedUnrepairedEvenWhereItIsIllegible` and
    // `aHexWinsOverTheRatioBesideIt` stood here too, and retired the same day
    // for the same reason. Both were about the repair chain being bypassed by a
    // named colour, and both ran on `actionRowInk`, the last hex that sat beside
    // a ratio. `busyDotInk` is not a substitute: it is a plain `??` over `ok`
    // with no chain to bypass and no ratio to win over, which is exactly what
    // `PaneThemeAdjustments` says about it, and asserting the hazard there would
    // be asserting it where it cannot occur.

    /// The dot's colour is replaceable and nothing else about it is. Geometry is
    /// deliberately absent from the whole override layer (the SIGWINCH wall), so
    /// the only thing this knob can do is change a colour.
    @Test func theBusyDotInkReplacesTheOkColour() {
        var dialled = theme
        dialled.adjustments.busyDotInk = .eightBit(0xFF, 0x00, 0x99)
        #expect(dialled.busyDot == RGB.eightBit(0xFF, 0x00, 0x99))
        #expect(dialled.busyDot != theme.ok)
    }

    // MARK: - The derivation seam

    /// The app-facing seam, with nothing dialled, equals the unparameterised
    /// derivation. `ConfigurationCenter` calls the parameterised form
    /// unconditionally, so this is what makes a Release build — where the
    /// overrides are always nil — render what it always did.
    @Test func theDerivationWithNoAdjustmentsMatchesTheDerivationWithout() {
        var settings = Settings.defaultSettings
        settings.themeName = "Dark Pastel"
        settings.backgroundHex = "#141414"

        let plain = SettingsDerivations.paneTheme(from: settings)
        let unadjusted = SettingsDerivations.paneTheme(from: settings, adjustments: .none)
        #expect(plain == unadjusted)
        #expect(unadjusted.adjustments == .none)
        #expect(unadjusted.barBackground == plain.barBackground)
    }

    /// And carries a dialled value through to the theme it builds, so the app
    /// side has one call rather than a build-then-assign a caller can forget —
    /// the shape `focusAccent`'s own doc comment argues for.
    @Test func theDerivationCarriesAdjustmentsIntoTheThemeItBuilds() {
        var settings = Settings.defaultSettings
        settings.themeName = "Dark Pastel"

        var adjustments = PaneThemeAdjustments.none
        adjustments.barLift = 0.42
        let theme = SettingsDerivations.paneTheme(from: settings, adjustments: adjustments)

        #expect(theme.adjustments.barLift == 0.42)
        #expect(theme.barBackground != SettingsDerivations.paneTheme(from: settings).barBackground)
    }

}
