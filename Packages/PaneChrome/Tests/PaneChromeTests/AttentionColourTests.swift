import BaiaSettings
import Foundation
import Testing

@testable import PaneChrome

/// The attention colour, and what happens when it lands on the focus colour.
///
/// Every case here is a way the resolution goes wrong: a default that is not
/// today's colour, an accent that reads the theme's raw selection colour rather
/// than the one `focusAccent` selected, a collision rule that only fires for one
/// of the two accents, and a `derive` that separates by an amount no one measured.
@Suite struct AttentionColourTests {
    /// Light in ghostty's own terms, so nothing here passes only on a dark bar.
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

    /// A theme that has spent one colour on two jobs: its `ansi[1]` *is* its
    /// selection colour.
    ///
    /// Not synthetic in kind. A palette whose red is also its selection highlight
    /// is a legal ghostty theme, and it is the case that proves the collision rule
    /// is a rule about two colours rather than a special case bolted onto
    /// `attentionAccent: accent`.
    private let collided = PaneTheme(
        background: RGB.eightBit(0x14, 0x14, 0x14),
        foreground: RGB.eightBit(0xBB, 0xBB, 0xBB),
        focusedAccent: RGB.eightBit(0xFF, 0x55, 0x55),
        ansi: [
            RGB.eightBit(0x00, 0x00, 0x00),
            RGB.eightBit(0xFF, 0x55, 0x55),
            RGB.eightBit(0x55, 0xFF, 0x55),
            RGB.eightBit(0xFF, 0xFF, 0x55),
        ]
    )

    /// The same collision one 8-bit step off exact: `ansi[1]` is `#b5d5fe` and the
    /// selection colour is `#b5d5ff`.
    ///
    /// ΔE00 0.23 apart, which is 44 times under the floor the module itself calls
    /// "visibly distinct", and byte-wise unequal. The catalog has sixteen rows of
    /// this shape and two of them sit on the default `focusAccent`, Glacier's
    /// `#bd0f2f` against `#bd2523` at 5.44 the clearest of them.
    private let nearlyCollided = PaneTheme(
        background: RGB.eightBit(0x14, 0x14, 0x14),
        foreground: RGB.eightBit(0xBB, 0xBB, 0xBB),
        focusedAccent: RGB.eightBit(0xB5, 0xD5, 0xFF),
        ansi: [
            RGB.eightBit(0x00, 0x00, 0x00),
            RGB.eightBit(0xB5, 0xD5, 0xFE),
            RGB.eightBit(0x55, 0xFF, 0x55),
            RGB.eightBit(0xFF, 0xFF, 0x55),
            RGB.eightBit(0x55, 0x55, 0xFF),
            RGB.eightBit(0xFF, 0x55, 0xFF),
            RGB.eightBit(0x55, 0xFF, 0xFF),
            RGB.eightBit(0xBB, 0xBB, 0xBB),
        ]
    )

    /// A theme whose selection colour is its own background lifted a step, which
    /// is what ``PaneTheme/barBackground`` is too.
    ///
    /// The commonest shape in the catalog by a distance: 124 of the 463 shipped
    /// themes put `accent`/`stock` within ΔE00 10 of the bar it fills, Afterglow's
    /// `#303030` on a `#2f2f2f` bar at 0.32 the tightest. The fill, the 510 ms
    /// arrival pulse and the pane frame all land in the colour of the footer that
    /// was already there, so the pane stops asking with nothing on screen to say
    /// why.
    private let fillIsTheBar = PaneTheme(
        background: "#212121",
        foreground: "#d0d0d0",
        selectionBackground: "#303030",
        palette: [
            0: "#151515", 1: "#ac4142", 2: "#7e8e50", 3: "#e5b567",
            4: "#6c99bb", 5: "#9f4e85", 6: "#7dd6cf", 7: "#d0d0d0",
            8: "#505050", 9: "#ac4142", 10: "#7e8e50", 11: "#e5b567",
            12: "#6c99bb", 13: "#9f4e85", 14: "#7dd6cf", 15: "#f5f5f5",
        ]
    )

    /// Zenburn, verbatim from the shipped catalog.
    ///
    /// The theme where blending towards `alert` alone lands *in* the bar. Its
    /// selection colour `#21322f` is the accent, its `alert` is a muted `#7d5d5d`,
    /// and 35% of the way between them is `#41413f` against a bar of `#4c4c4a`:
    /// ΔE00 10.67 from the accent, which clears a floor measured against focus
    /// alone, and 3.56 from the footer it is supposed to wash. Four catalog rows
    /// end up there.
    private let zenburn = PaneTheme(
        background: "#3f3f3f",
        foreground: "#dcdccc",
        selectionBackground: "#21322f",
        palette: [
            0: "#4d4d4d", 1: "#7d5d5d", 2: "#60b48a", 3: "#f0dfaf",
            4: "#5d6d7d", 5: "#dc8cc3", 6: "#8cd0d3", 7: "#dcdccc",
            8: "#709080", 9: "#dca3a3", 10: "#c3bf9f", 11: "#e0cf9f",
            12: "#94bff3", 13: "#ec93d3", 14: "#93e0e3", 15: "#ffffff",
        ]
    )

    /// Every theme above, for the checks that have to hold on all of them.
    private var everyTheme: [PaneTheme] {
        [.darkPastel, paper, collided, nearlyCollided, fillIsTheBar, zenburn]
    }

    // MARK: - Defaults

    @Test func theDefaultsResolveToTheColourThatShipsToday() {
        // The upgrade promise. `attentionAccent: alert` with `alertBehavior: stock`
        // has to be `theme.alert` and nothing else, on every theme, or installing a
        // release is a colour change nobody asked for.
        for theme in everyTheme {
            #expect(theme.attentionColour(.alert, behavior: .stock) == theme.alert)
        }
        #expect(Settings.defaultSettings.attentionAccent == .alert)
        #expect(Settings.defaultSettings.alertBehavior == .stock)
    }

    @Test func aThemeWithNoCollisionIsLeftAloneByEveryBehaviour() {
        // Dark Pastel's `ansi[1]` is `#ff5555` and its selection blue is `#b5d5ff`,
        // so nothing collides and all three behaviours must answer the same thing.
        // This is the half of `noCollision` and `derive` that says they are guarded
        // rather than unconditional: if either fired here it would be repainting a
        // theme that had no problem.
        let theme = PaneTheme.darkPastel
        for behavior in AlertBehavior.allCases {
            #expect(theme.attentionColour(.alert, behavior: behavior) == theme.alert)
        }
    }

    // MARK: - The accent arm

    @Test func accentResolvesToTheAccentTheFocusSettingSelected() {
        // Not the theme's raw selection colour. `focusAccent: bone` moves
        // `focusedAccent` off the declared selection blue, and an attention colour
        // that read the declared value instead would be a second answer to a
        // question `PaneTheme.accent(for:)` already answers, drifting the moment
        // either is edited.
        let theme = PaneTheme(
            background: "#141414",
            foreground: "#bbbbbb",
            selectionBackground: "#b5d5ff",
            palette: Dictionary(uniqueKeysWithValues: (0 ..< 16).map { ($0, "#404040") }),
            focusAccent: .bone
        )
        let declaredSelection = RGB(hex: "#b5d5ff")!
        #expect(theme.focusedAccent != declaredSelection)
        #expect(theme.attentionColour(.accent, behavior: .stock) == theme.focusedAccent)
        #expect(theme.attentionColour(.accent, behavior: .stock) != declaredSelection)
    }

    @Test func stockLeavesTheCollidingColourExactlyWhereItIs() {
        // `stock` is the shipped answer to the collision question: nothing. Shape
        // carries the distinction, focus taking an edge and attention taking a
        // fill. Spelled as equality with `focusedAccent` rather than as "not
        // alert", so a `stock` that quietly nudged the colour away from the focus
        // accent fails here instead of passing for the wrong reason.
        for theme in everyTheme {
            #expect(theme.attentionColour(.accent, behavior: .stock) == theme.focusedAccent)
        }
    }

    @Test func noCollisionFallsBackToAlertOnlyWhereTheTwoWouldMeet() {
        // The two directions of the same guard, on one theme. Under `accent` the
        // attention colour *is* the focus colour by construction, so the fallback
        // has to fire and move the answer off the accent; under `alert` nothing
        // collides on this theme, so the answer has to be what `stock` gives.
        let theme = PaneTheme.darkPastel
        #expect(theme.attentionColour(.accent, behavior: .noCollision) == theme.alert)
        #expect(theme.attentionColour(.accent, behavior: .noCollision)
            != theme.attentionColour(.accent, behavior: .stock))
        #expect(theme.attentionColour(.alert, behavior: .noCollision)
            == theme.attentionColour(.alert, behavior: .stock))
    }

    // MARK: - The collision the accent value does not own

    @Test func theCollisionRuleFiresUnderAlertToo() {
        // The case the whole design note turns on. `collided` spends one colour on
        // both its red and its selection highlight, so `attentionAccent: alert`
        // collides with focus without anyone choosing `accent`. A rule that only
        // fired for `accent` would leave this theme with a fill and a frame that
        // are the same colour and no setting that could part them.
        #expect(collided.alert == collided.focusedAccent)

        // `stock`: unchanged, collision and all.
        #expect(collided.attentionColour(.alert, behavior: .stock) == collided.alert)

        // `noCollision`: fires, and the fallback it names is `alert`, which on this
        // theme is where it already was. Degenerate rather than wrong: the setting
        // says "fall back to what shipped", and what shipped is the colliding
        // colour. `derive` is the answer for this theme, which is why it exists.
        #expect(collided.attentionColour(.alert, behavior: .noCollision) == collided.alert)

        // `derive`: fires and separates, measured rather than asserted.
        let derived = collided.attentionColour(.alert, behavior: .derive)
        #expect(derived != collided.focusedAccent)
        #expect(derived.perceptualDistance(to: collided.focusedAccent)
            >= PaneTheme.minimumAttentionSeparation)
    }

    @Test func theCollisionRuleIsAMeasurementRatherThanEquality() {
        // The guard that decides whether to repair, and the repair that follows it,
        // have to hold one definition of "the same colour". They used to hold two,
        // four lines apart: the guard was `==`, which is ΔE00 0, while the repair
        // stopped at ΔE00 10. A theme one 8-bit step off a collision therefore got
        // no repair from either behaviour, and the owner who turned `derive` on to
        // part the two signals got the colliding colour handed back, unchanged and
        // undiagnosed.
        //
        // Sixteen catalog rows have this shape and two of them are on the default
        // `focusAccent`. Glacier is the one to read: `alert` `#bd0f2f` against an
        // accent of `#bd2523`, unequal, ΔE00 5.44 apart, and `derive` was a no-op
        // on it.
        let theme = nearlyCollided
        #expect(theme.alert != theme.focusedAccent)
        let gap = theme.alert.perceptualDistance(to: theme.focusedAccent)
        #expect(gap < 1)
        #expect(gap < PaneTheme.minimumAttentionSeparation)

        // `derive` has to fire on a gap an equality guard cannot see.
        let derived = theme.attentionColour(.alert, behavior: .derive)
        #expect(derived != theme.alert)
        #expect(derived.perceptualDistance(to: theme.focusedAccent)
            >= PaneTheme.minimumAttentionSeparation)

        // `stock` still does nothing, because doing nothing is what it is.
        #expect(theme.attentionColour(.alert, behavior: .stock) == theme.alert)
    }

    // MARK: - The other collision: the bar underneath

    @Test func aFillThatIsTheBarItFillsIsACollisionToo() {
        // The rule only ever asked whether attention was the focus colour. It never
        // asked whether attention was the *surface*, and 124 of the 463 catalog
        // themes fail that second question under `accent`: a selection colour is
        // usually the theme's own background lifted a step, which is exactly what
        // `barBackground` is. The 22 pt wash, the 510 ms arrival pulse and the 2 pt
        // pane frame then all render as the footer that was already there.
        let theme = fillIsTheBar
        let stock = theme.attentionColour(.accent, behavior: .stock)
        #expect(stock.perceptualDistance(to: theme.barBackground)
            < PaneTheme.minimumAttentionSeparation)

        // `stock` keeps it, and that is the spec rather than an oversight: the
        // shipped answer to the collision question is "nothing". Pinned so that a
        // later helpful nudge has to argue with a test rather than slip in.
        #expect(stock == theme.focusedAccent)

        // Both repair behaviours have to clear the bar as well as the accent.
        for behavior in [AlertBehavior.noCollision, .derive] {
            let fill = theme.attentionColour(.accent, behavior: behavior)
            #expect(fill.perceptualDistance(to: theme.barBackground)
                >= PaneTheme.minimumAttentionSeparation)
            #expect(fill.perceptualDistance(to: theme.focusedAccent)
                >= PaneTheme.minimumAttentionSeparation)
        }
    }

    @Test func deriveWillNotSeparateByGoingDarkIntoTheBar() {
        // A floor measured against the accent alone is satisfied by walking into
        // the terminal, which is the one direction that must never win: it trades a
        // wash nobody can tell from the focus edge for a wash nobody can tell from
        // the footer. Zenburn does exactly that on the shipped catalog. Spelled as
        // an explicit distance to the bar rather than through
        // `attentionSeparation(of:)`, so a measure that quietly stopped counting the
        // bar fails here rather than agreeing with itself.
        let derived = zenburn.attentionColour(.accent, behavior: .derive)
        #expect(derived.perceptualDistance(to: zenburn.barBackground)
            >= PaneTheme.minimumAttentionSeparation)
        #expect(derived.perceptualDistance(to: zenburn.background)
            >= PaneTheme.minimumAttentionSeparation)
        #expect(derived.perceptualDistance(to: zenburn.focusedAccent)
            >= PaneTheme.minimumAttentionSeparation)

        // The answer the focus-only walk gave, pinned as the thing this must not
        // be: `#41413f`, 10.67 from the accent and 3.56 from the bar.
        let focusOnly = zenburn.focusedAccent.blended(with: zenburn.alert, fraction: 0.35)
        #expect(focusOnly.hexString == "#41413f")
        #expect(focusOnly.perceptualDistance(to: zenburn.focusedAccent)
            >= PaneTheme.minimumAttentionSeparation)
        #expect(focusOnly.perceptualDistance(to: zenburn.barBackground)
            < PaneTheme.minimumAttentionSeparation)
        #expect(derived != focusOnly)
    }

    // MARK: - derive

    @Test func deriveSeparatesByAMeasuredAmountRatherThanByBeingUnequal() {
        // Two colours one 8-bit step apart are unequal and indistinguishable, so
        // inequality proves nothing. The floor is CIEDE2000, the standard
        // perceptual metric, at `minimumAttentionSeparation`, and it is owed against
        // the bar as well as the accent.
        //
        // Scoped to themes with something in the palette to blend towards, which is
        // the honest scope: `derived(from:)` searches a palette and a palette can be
        // empty of alternatives. `deriveOnAThemeWithNothingToBlendTowardsStillAnswers`
        // is the other side of that, and reading the two together is what stops this
        // from being an invariant the function does not have.
        for theme in everyTheme {
            for accent in AttentionAccent.allCases {
                let derived = theme.attentionColour(accent, behavior: .derive)
                #expect(theme.attentionSeparation(of: derived)
                    >= PaneTheme.minimumAttentionSeparation)
            }
        }
    }

    @Test func deriveLooksPastADirectionThatIsNoUse() {
        // The reachable failure, which is not the flat palette the old comment
        // named. This theme has fifteen perfectly distinct ANSI slots; what it does
        // not have is a *useful first direction*, because `alert` is the accent and
        // `ansi[3]` sits three steps off it. Walking that one direction and
        // returning the last step gave `#b7d7ff` at ΔE00 0.73 against a floor of 10,
        // silently, with nothing for the caller to inspect.
        //
        // 83 of the 2315 catalog rows had this shape, HaX0R Blue the worst of them:
        // `ansi[1]`, `ansi[3]` and `ansi[5]` are one colour there, and `derive`
        // returned the colliding colour bit for bit at ΔE00 0.00. All 83 had a
        // palette slot that would have cleared the floor.
        let trap = PaneTheme(
            background: RGB.eightBit(0x14, 0x14, 0x14),
            foreground: RGB.eightBit(0xBB, 0xBB, 0xBB),
            focusedAccent: RGB.eightBit(0xB5, 0xD5, 0xFF),
            ansi: [
                RGB.eightBit(0x00, 0x00, 0x00),
                RGB.eightBit(0xB5, 0xD5, 0xFF),
                RGB.eightBit(0x55, 0xFF, 0x55),
                RGB.eightBit(0xB8, 0xD8, 0xFF),
                RGB.eightBit(0x55, 0x55, 0xFF),
                RGB.eightBit(0xFF, 0x55, 0xFF),
                RGB.eightBit(0x55, 0xFF, 0xFF),
                RGB.eightBit(0xBB, 0xBB, 0xBB),
                RGB.eightBit(0x55, 0x55, 0x55),
                RGB.eightBit(0xFF, 0x55, 0x55),
                RGB.eightBit(0x55, 0xFF, 0x55),
                RGB.eightBit(0xFF, 0xFF, 0x55),
                RGB.eightBit(0x55, 0x55, 0xFF),
                RGB.eightBit(0xFF, 0x55, 0xFF),
                RGB.eightBit(0x55, 0xFF, 0xFF),
                RGB.eightBit(0xFF, 0xFF, 0xFF),
            ]
        )
        #expect(trap.alert == trap.focusedAccent)
        #expect(trap.ansiColor(3).perceptualDistance(to: trap.focusedAccent)
            < PaneTheme.minimumAttentionSeparation)
        for accent in AttentionAccent.allCases {
            let derived = trap.attentionColour(accent, behavior: .derive)
            #expect(derived.perceptualDistance(to: trap.focusedAccent)
                >= PaneTheme.minimumAttentionSeparation)
            #expect(derived.perceptualDistance(to: trap.barBackground)
                >= PaneTheme.minimumAttentionSeparation)
        }
    }

    @Test func deriveMovesTowardsAlertRatherThanAnywhereConvenient() {
        // The direction is the semantic claim: the thing is still an alert, so the
        // colour it is pushed towards is the theme's alert. Measured as getting
        // closer to `alert` than the accent it started from, which a blend towards
        // the background or towards a hue picked for contrast alone would fail.
        let theme = PaneTheme.darkPastel
        let derived = theme.attentionColour(.accent, behavior: .derive)
        #expect(derived.perceptualDistance(to: theme.alert)
            < theme.focusedAccent.perceptualDistance(to: theme.alert))
    }

    @Test func deriveStopsAtTheFirstStepThatClearsTheFloor() {
        // The reported measurement, pinned. On Dark Pastel with `attentionAccent:
        // accent` the first step of the walk clears the floor, so the answer is the
        // accent 35% of the way to `alert` and nothing further. Pinning the value
        // is what makes the number in the comment on `derived(_:awayFrom:)` a fact
        // rather than a claim: change the fractions and this says so.
        let theme = PaneTheme.darkPastel
        let firstStep = theme.focusedAccent.blended(with: theme.alert, fraction: 0.35)
        #expect(theme.attentionColour(.accent, behavior: .derive) == firstStep)
        #expect(firstStep.hexString == "#cfa8c3")
        // The number quoted in the comment, to two decimals. A range rather than a
        // floor, because a change that made the separation *larger* is still a
        // change to a value that is written down as measured.
        let separation = firstStep.perceptualDistance(to: theme.focusedAccent)
        #expect(abs(separation - 25.53) < 0.01)
    }

    @Test func deriveOnAThemeWithNothingToBlendTowardsStillAnswers() {
        // A palette of one colour: `alert`, `focusedAccent` and the warn hue are
        // all the same, so no step of the search can separate anything. It has to
        // run out and hand back a colour rather than spin looking for one, and the
        // caller has to get a drawable value rather than a trap inside a draw call,
        // which is the same contract `ansiColor(_:)` keeps for a short palette.
        let flat = PaneTheme(
            background: RGB.eightBit(0x80, 0x80, 0x80),
            foreground: RGB.eightBit(0x80, 0x80, 0x80),
            focusedAccent: RGB.eightBit(0x80, 0x80, 0x80),
            ansi: Array(repeating: RGB.eightBit(0x80, 0x80, 0x80), count: 16)
        )
        #expect(flat.attentionColour(.alert, behavior: .derive) == flat.alert)

        // The shipped instance of it, so the escape hatch is scoped by a real theme
        // rather than by a constructed one. `Retro` spends all sixteen slots and its
        // foreground on two greens over a black background, and it is the only theme
        // in the catalog of 463 where `derive` cannot reach the floor: 8 of the 2315
        // theme-by-`focusAccent` rows, all of them Retro, and none of them has a
        // palette colour that would have cleared it. Everything green is the accent;
        // everything else is the bar.
        let retro = PaneTheme(
            background: "#000000",
            foreground: "#13a10e",
            selectionBackground: "#ffffff",
            palette: Dictionary(uniqueKeysWithValues: (0 ..< 8).map { ($0, "#13a10e") })
                .merging(Dictionary(uniqueKeysWithValues: (8 ..< 16).map { ($0, "#16ba10") })) { a, _ in a },
            focusAccent: .bone
        )
        let derived = retro.attentionColour(.alert, behavior: .derive)
        #expect(retro.attentionSeparation(of: derived)
            < PaneTheme.minimumAttentionSeparation)
        // Best-effort rather than arbitrary. The answer has to be at least as far
        // from the things it must not be mistaken for as the colour it started
        // from, which is the promise a palette with nothing in it can still keep
        // and the one the old code broke by returning whichever step it happened
        // to stop on.
        #expect(retro.attentionSeparation(of: derived)
            >= retro.attentionSeparation(of: retro.alert))
    }

    @Test func aDeriveThatCannotClearTheFloorStillHandsBackItsBestCandidate() {
        // "Best it measured" rather than "last it tried", which is what the walk
        // used to return. The distinction is invisible on a palette of one colour,
        // where every candidate is the same colour, and it is the whole answer on a
        // palette that is *nearly* flat: one slot three steps off the accent moves
        // the needle a little, every other slot moves it less, and the search
        // finishes on one of the latter.
        //
        // Returning the last step there means the outcome depends on the order the
        // targets happen to be listed in, which is not a property anyone chose.
        let nearlyFlat = PaneTheme(
            background: RGB.eightBit(0x00, 0x00, 0x00),
            foreground: RGB.eightBit(0x80, 0x80, 0x80),
            focusedAccent: RGB.eightBit(0x80, 0x80, 0x80),
            ansi: [
                RGB.eightBit(0x82, 0x82, 0x82),
                RGB.eightBit(0x80, 0x80, 0x80),
                RGB.eightBit(0x82, 0x82, 0x82),
                RGB.eightBit(0x8A, 0x8A, 0x8A),
            ] + Array(repeating: RGB.eightBit(0x82, 0x82, 0x82), count: 12)
        )
        #expect(nearlyFlat.alert == nearlyFlat.focusedAccent)
        let derived = nearlyFlat.attentionColour(.alert, behavior: .derive)
        // Under the floor, as this palette must be, and still the furthest the
        // palette could get rather than whichever blend the loop ended on.
        #expect(nearlyFlat.attentionSeparation(of: derived)
            < PaneTheme.minimumAttentionSeparation)
        #expect(derived != nearlyFlat.alert)
        #expect(nearlyFlat.attentionSeparation(of: derived)
            > nearlyFlat.attentionSeparation(of: nearlyFlat.alert))
        // The warn hue is the only slot far enough to be worth anything here, and
        // the furthest step along it is the answer.
        #expect(derived == nearlyFlat.alert.blended(with: nearlyFlat.ansiColor(3), fraction: 0.75))
    }

    // MARK: - The ink on whatever it resolves to

    @Test func everyResolvedAttentionColourCarriesReadableInk() {
        // Six combinations on a dark theme and a light one. The fill owes nothing
        // to itself; the ink drawn on it owes 4.5:1, and the repair chain is what
        // guarantees that. Asserted rather than assumed, because `derive` and
        // `noCollision` can both hand `ink(on:)` a fill no previous test ever
        // passed it: an accent blended towards red is neither of the two fills
        // `aFilledBarTakesItsInkFromTheBackgroundRatherThanTheForeground` covers.
        for theme in everyTheme {
            for accent in AttentionAccent.allCases {
                for behavior in AlertBehavior.allCases {
                    let fill = theme.attentionColour(accent, behavior: behavior)
                    #expect(theme.ink(on: fill).contrastRatio(against: fill)
                        >= PaneTheme.minimumTextContrast)
                    #expect(theme.mutedInk(on: fill).contrastRatio(against: fill)
                        >= PaneTheme.minimumTextContrast)
                    // The tier ordering, which the muted candidate can invert on a
                    // mid-luminance fill. A derived accent lands squarely in that
                    // band, so a filled footer would otherwise read with its
                    // quietest tier shouting.
                    #expect(theme.mutedInk(on: fill).contrastRatio(against: fill)
                        <= theme.ink(on: fill).contrastRatio(against: fill))
                }
            }
        }
    }

    @Test func theFocusFrameOnAFilledBarIsStillReadableOnAnAccentFill() {
        // `PaneStatusBarView.drawBarFrame` swaps `inkFocus` for `ink(on:)` when the
        // bar is filled, because `inkFocus` is repaired against `barBackground` and
        // scores 2.08:1 on the alert fill. The swap has to keep holding for the new
        // fills: an accent fill is the pane that is both focused and asking under
        // `attentionAccent: accent`, which is the state the owner is in every time
        // he answers an agent.
        for theme in everyTheme {
            for accent in AttentionAccent.allCases {
                for behavior in AlertBehavior.allCases {
                    let fill = theme.attentionColour(accent, behavior: behavior)
                    #expect(theme.ink(on: fill).contrastRatio(against: fill)
                        > theme.inkFocus.contrastRatio(against: fill)
                        || theme.inkFocus.contrastRatio(against: fill)
                        >= PaneTheme.minimumTextContrast)
                }
            }
        }
    }
}
