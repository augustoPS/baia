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
        #expect(none.sessionHeaderMinimumRatio == nil)
        #expect(none.sessionHeaderInk == nil)
        #expect(none.actionRowMinimumRatio == nil)
        #expect(none.actionRowInk == nil)
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
            #expect(adjusted.sessionHeaderInk(on: base.barBackground)
                == base.sessionHeaderInk(on: base.barBackground))
            #expect(adjusted.actionRowInk(on: base.barBackground)
                == base.actionRowInk(on: base.barBackground))
        }
    }

    /// The three inks are `inkFaint` on a backdrop that already clears, which is
    /// what makes flat byte-identical: the repair is a no-op there and this is
    /// the arm that says so, rather than the prose alone.
    @Test func theUnadjustedInksAreTheFaintTierOnABarThatAlreadyClears() {
        #expect(theme.sessionHeaderInk(on: theme.barBackground) == theme.inkFaint)
        #expect(theme.actionRowInk(on: theme.barBackground) == theme.inkFaint)
        #expect(theme.sectionHeaderInk(on: theme.barBackground) == theme.inkFaint)
    }

    /// The unadjusted busy dot is the constant the drawing site used to name
    /// directly, so re-pointing that site at this derivation moved no pixel.
    @Test func theUnadjustedBusyDotIsTheOkColour() {
        for base in [theme, paper] {
            #expect(base.busyDot == base.ok)
        }
    }

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

    /// The footer's ink follows the bar it is graded on, which is the coupling
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

    /// The same, on the two sidebar inks, and on both a dark and a light theme:
    /// the chain picks its direction off the backdrop's luminance, so a ratio
    /// that only worked downhill would pass a dark-only arm.
    @Test func raisingASidebarRatioBrightensBothSidebarInks() {
        for base in [theme, paper] {
            let backdrop = base.barBackground

            var session = base
            session.adjustments.sessionHeaderMinimumRatio = 11
            #expect(session.sessionHeaderInk(on: backdrop).contrastRatio(against: backdrop)
                > base.sessionHeaderInk(on: backdrop).contrastRatio(against: backdrop))

            var action = base
            action.adjustments.actionRowMinimumRatio = 11
            #expect(action.actionRowInk(on: backdrop).contrastRatio(against: backdrop)
                > base.actionRowInk(on: backdrop).contrastRatio(against: backdrop))
        }
    }

    /// Each ratio reaches exactly one ink. Three separate fields that all moved
    /// together would be one field with three names, and the reason
    /// `DesignOverrides` keeps them apart is so the owner can tell which of the
    /// three a dial moved.
    @Test func eachRatioMovesOnlyItsOwnInk() {
        let backdrop = theme.barBackground

        var session = theme
        session.adjustments.sessionHeaderMinimumRatio = 11
        #expect(session.sessionHeaderInk(on: backdrop) != theme.sessionHeaderInk(on: backdrop))
        #expect(session.actionRowInk(on: backdrop) == theme.actionRowInk(on: backdrop))
        #expect(session.sectionHeaderInk(on: backdrop) == theme.sectionHeaderInk(on: backdrop))

        var action = theme
        action.adjustments.actionRowMinimumRatio = 11
        #expect(action.actionRowInk(on: backdrop) != theme.actionRowInk(on: backdrop))
        #expect(action.sessionHeaderInk(on: backdrop) == theme.sessionHeaderInk(on: backdrop))
        #expect(action.sectionHeaderInk(on: backdrop) == theme.sectionHeaderInk(on: backdrop))

        var section = theme
        section.adjustments.sectionHeaderMinimumRatio = 11
        #expect(section.sectionHeaderInk(on: backdrop) != theme.sectionHeaderInk(on: backdrop))
        #expect(section.sessionHeaderInk(on: backdrop) == theme.sessionHeaderInk(on: backdrop))
        #expect(section.actionRowInk(on: backdrop) == theme.actionRowInk(on: backdrop))
    }

    /// A hex bypasses the chain outright: it comes back as itself, on a backdrop
    /// it fails badly against. That is the documented hazard of the probe and
    /// this arm pins it, so nobody later "fixes" the hex into a candidate the
    /// chain then repairs away.
    @Test func aHexIsReturnedUnrepairedEvenWhereItIsIllegible() {
        let backdrop = theme.barBackground
        let illegible = RGB.eightBit(0x16, 0x16, 0x16)
        #expect(illegible.contrastRatio(against: backdrop) < PaneTheme.minimumTextContrast)

        var session = theme
        session.adjustments.sessionHeaderInk = illegible
        #expect(session.sessionHeaderInk(on: backdrop) == illegible)

        var action = theme
        action.adjustments.actionRowInk = illegible
        #expect(action.actionRowInk(on: backdrop) == illegible)
    }

    /// A hex beside a ratio: the colour wins, because a named colour has no
    /// ratio left to satisfy. `DesignOverrides.Chrome.Inks` states that
    /// precedence and this is where it is enforced.
    @Test func aHexWinsOverTheRatioBesideIt() {
        let backdrop = theme.barBackground
        let named = RGB.eightBit(0xFF, 0x00, 0x99)

        var session = theme
        session.adjustments.sessionHeaderInk = named
        session.adjustments.sessionHeaderMinimumRatio = 21
        #expect(session.sessionHeaderInk(on: backdrop) == named)

        var action = theme
        action.adjustments.actionRowInk = named
        action.adjustments.actionRowMinimumRatio = 21
        #expect(action.actionRowInk(on: backdrop) == named)
    }

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
