import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneThemeTests {
    /// A theme that is light in ghostty's own terms, for the tests that pin the
    /// chrome to the theme rather than to a dark palette.
    private let paper = PaneTheme(
        background: RGB.eightBit(0xFF, 0xFF, 0xFF),
        foreground: RGB.eightBit(0x20, 0x20, 0x20),
        focusedAccent: RGB.eightBit(0x1E, 0x5A, 0xA8),
        ansi: [RGB.eightBit(0x00, 0x00, 0x00), RGB.eightBit(0xB4, 0x11, 0x11)]
    )

    @Test func readableJudgesAColourAsComposited() {
        // The same candidate, kept on one background and replaced on another. A
        // function that scored the candidate on its own luminance, or always
        // against the theme's own background rather than the one it was handed,
        // would answer identically for both. It matters more now than it did:
        // an inverted focused pane and an asking pane both fill the bar with a
        // colour that is nothing like `barBackground`.
        let theme = PaneTheme.darkPastel
        let dim = RGB.eightBit(0x3A, 0x3A, 0x3A)
        #expect(theme.readable(dim, on: RGB.eightBit(0xFF, 0xFF, 0xFF), minimumRatio: 4.5) == dim)
        #expect(theme.readable(dim, on: theme.barBackground, minimumRatio: 4.5) != dim)
    }

    @Test func readableRepairsTowardsTheEndFurthestFromTheBackground() {
        // On a dark bar the repair has to brighten. Pushing towards black
        // instead would take a failing candidate further from passing and the
        // chain would walk all the way to the foreground for a colour that only
        // needed a nudge.
        let theme = PaneTheme.darkPastel
        let dim = RGB.eightBit(0x3A, 0x3A, 0x3A)
        let repaired = theme.readable(dim, on: theme.barBackground, minimumRatio: 4.5)
        #expect(repaired.relativeLuminance > dim.relativeLuminance)
        #expect(repaired.contrastRatio(against: theme.barBackground) >= 4.5)
    }

    @Test func readableRepairsDownwardsOnALightBackground() {
        // The mirror of readableRepairsTowardsTheEndFurthestFromTheBackground,
        // and the reason the direction is chosen by RGB.isDark rather than
        // fixed. Either test on its own passes with the direction hard-coded
        // the way it suits that test.
        let pale = RGB.eightBit(0xC8, 0xC8, 0xC8)
        let repaired = paper.readable(pale, on: paper.barBackground, minimumRatio: 4.5)
        #expect(repaired.relativeLuminance < pale.relativeLuminance)
        #expect(repaired.contrastRatio(against: paper.barBackground) >= 4.5)
    }

    @Test func readableKeepsACandidateThatAlreadyClearsTheRatio() {
        let theme = PaneTheme.darkPastel
        #expect(theme.readable(theme.foreground, on: theme.barBackground, minimumRatio: 4.5)
            == theme.foreground)
    }

    @Test func readableFallsBackToTheThemeForegroundWhenNothingClears() {
        // 21 is the top of the WCAG scale and only black against white reaches
        // it, so no step of the chain can clear it here. Returning the
        // foreground rather than the last failing step keeps the bar in the
        // theme's own colours instead of drifting to white as the ratio gets
        // harder.
        let theme = PaneTheme.darkPastel
        let dim = RGB.eightBit(0x3A, 0x3A, 0x3A)
        #expect(theme.readable(dim, on: theme.barBackground, minimumRatio: 21) == theme.foreground)
    }

    @Test func theBarBackgroundIsDerivedFromTheThemeRatherThanFixed() {
        // A light theme gets a light bar. The standing rule here is to match
        // chrome to the theme and never the reverse, and a hard-coded bar
        // colour would fail exactly one of these two assertions.
        #expect(PaneTheme.darkPastel.barBackground.isDark)
        #expect(!paper.barBackground.isDark)
    }

    @Test func theBarBackgroundStaysCloseToTheTerminalBackground() {
        // Chrome, not a bright band across a dark pane. The lift also must not
        // be enough to flip ghostty's own theme test, since every text colour
        // on the bar is chosen from that verdict.
        let theme = PaneTheme.darkPastel
        #expect(theme.barBackground.contrastRatio(against: theme.background) < 1.5)
        #expect(theme.barBackground.isDark)
    }

    @Test func everyEmphasisClearsTheMinimumContrastOnTheOrdinaryBar() {
        // The invariant the whole colour chain exists for.
        let theme = PaneTheme.darkPastel
        for emphasis in PaneStatusEmphasis.allCases {
            for focused in [true, false] {
                let colour = theme.color(for: emphasis, focused: focused)
                #expect(colour.contrastRatio(against: theme.barBackground)
                    >= PaneTheme.minimumTextContrast)
            }
        }
    }

    @Test func everyEmphasisClearsTheMinimumContrastOnALightTheme() {
        // A light theme needs no branch anywhere in the derivations. This is what
        // says so: the same formulas, judged the same way, on a palette whose
        // foreground is the dark end.
        for emphasis in PaneStatusEmphasis.allCases {
            #expect(paper.color(for: emphasis, focused: true)
                .contrastRatio(against: paper.barBackground) >= PaneTheme.minimumTextContrast)
        }
    }

    @Test func aFilledBarTakesItsInkFromTheBackgroundRatherThanTheForeground() {
        // The case an emphasis colour cannot serve. Both fills are bright enough
        // to flip `isDark`, so the repair chain turns around and pushes towards
        // black: a foreground-derived candidate starts at the wrong end, runs out
        // of steps around 4.3:1 on the alert fill, and then falls back to the
        // foreground itself at about 1.4:1, which is unreadable. Starting from the
        // background lands on the first try.
        for theme in [PaneTheme.darkPastel, paper] {
            for fill in [theme.focusedAccent, theme.alert] {
                #expect(theme.ink(on: fill).contrastRatio(against: fill)
                    >= PaneTheme.minimumTextContrast)
                #expect(theme.mutedInk(on: fill).contrastRatio(against: fill)
                    >= PaneTheme.minimumTextContrast)
            }
        }
    }

    @Test func theMutedInkOnAFilledBarIsQuieterThanTheInkBesideIt() {
        // Tier 4 has to keep receding when the bar is filled, or an inverted
        // footer flattens every tier it worked to separate.
        let theme = PaneTheme.darkPastel
        let fill = theme.focusedAccent
        #expect(theme.mutedInk(on: fill).contrastRatio(against: fill)
            < theme.ink(on: fill).contrastRatio(against: fill))
    }

    @Test func focusChangesTheProjectNameAndNothingElse() {
        // Every other emphasis is focus-independent now. Unfocused panes recede
        // behind a scrim over the whole pane rather than by fading their own
        // text, which is what removed `unfocusedDim`: text faded into its own bar
        // gets repaired straight back up the moment it drops under the minimum,
        // so the old mechanism had a ceiling built into it and the scrim has none.
        let theme = PaneTheme.darkPastel
        for emphasis in PaneStatusEmphasis.allCases where emphasis != .strong {
            #expect(theme.color(for: emphasis, focused: true)
                == theme.color(for: emphasis, focused: false))
        }
        #expect(theme.color(for: .strong, focused: true)
            != theme.color(for: .strong, focused: false))
    }

    @Test func onlyTheFocusedPaneSpendsTheAccent() {
        // What makes one bar out of five identifiable at a glance, with none of
        // them changing size.
        let theme = PaneTheme.darkPastel
        #expect(theme.color(for: .strong, focused: true) == theme.focusedAccent)
        #expect(theme.color(for: .strong, focused: false) != theme.focusedAccent)
    }

    @Test func theFourTiersAreOrderedAndNoneIsRepairedIntoAnother() {
        // The tiers pull against the minimum ratio: fade a tier harder and
        // `readable` repairs it back towards the foreground, at which point two
        // tiers collapse into one colour and the hierarchy silently stops
        // existing. This is the test that catches that, and it is why
        // `inkFaint` sits at 0.30 rather than anywhere past it.
        let theme = PaneTheme.darkPastel
        let normal = theme.color(for: .normal, focused: false)
        let context = theme.color(for: .context, focused: false)
        let faint = theme.color(for: .faint, focused: false)
        #expect(normal.relativeLuminance > context.relativeLuminance)
        #expect(context.relativeLuminance > faint.relativeLuminance)
    }

    @Test func aFainterTierWouldBeRepairedBackUpWhichIsWhyThirtyIsTheFloor() {
        // The specific collision, pinned. At 0.32 the blend lands under the
        // minimum on the bar it is drawn on, `readable` moves it, and the value
        // that comes back is no longer the one the derivation asked for.
        let theme = PaneTheme.darkPastel
        let tooFaint = theme.foreground.blended(with: theme.background, fraction: 0.32)
        #expect(tooFaint.contrastRatio(against: theme.barBackground) < PaneTheme.minimumTextContrast)
        #expect(theme.inkFaint.contrastRatio(against: theme.barBackground)
            >= PaneTheme.minimumTextContrast)
    }

    @Test func theDerivationsResolveToTheValuesTheDesignPassQuotes() {
        // The hexes the handoff prints for Dark Pastel on #141414. They are not
        // the spec, the formulas are, but they are what someone reads the design
        // document against, so a formula edited without meaning to shows up here
        // rather than as a colour nobody recognises.
        let theme = PaneTheme.darkPastel
        #expect(theme.barBackground.hexString == "#212121")
        #expect(theme.hairline.hexString == "#323232")
        #expect(theme.inkContext.hexString == "#9d9d9d")
        #expect(theme.inkFaint.hexString == "#898989")
        #expect(theme.warn.hexString == "#c4c445")
        #expect(theme.edgeFocus.hexString == "#6d7e95")
        #expect(theme.boneAccent.hexString == "#e0e0e0")
        #expect(theme.alert.hexString == "#ff5555")
        #expect(theme.ok.hexString == "#55ff55")
    }

    @Test func theDividerSitsBelowTheFooterHairline() {
        // The plank between two stalls must never outrank the plank under one.
        // Both are blends towards the foreground, so this is an ordering on the
        // fractions and it is the only thing keeping the split lines from
        // becoming the loudest geometry in a four-pane window.
        let theme = PaneTheme.darkPastel
        #expect(theme.divider.relativeLuminance < theme.hairline.relativeLuminance)
        #expect(theme.divider.relativeLuminance > theme.background.relativeLuminance)
    }

    @Test func infoIsRepairedAtThePointOfUseRatherThanPreBrightened() {
        // Raw ansi[4] on Dark Pastel is #5555ff, which scores about 3.3:1 on the
        // bar and would be unreadable if it were used as-is. It is left raw in
        // the derivation so a theme whose blue already passes keeps its own blue,
        // and the repair happens where the background is known.
        let theme = PaneTheme.darkPastel
        #expect(theme.info.contrastRatio(against: theme.barBackground)
            < PaneTheme.minimumTextContrast)
        #expect(theme.color(for: .info, focused: false).contrastRatio(against: theme.barBackground)
            >= PaneTheme.minimumTextContrast)
    }

    @Test func theScrimIsHeavierThanTheInactiveOneAndBothStayReadable() {
        // Two different statements. An unfocused pane inside the key window
        // recedes further than every pane does when the window itself is not
        // key, because the first is a comparison the eye makes inside one window
        // and the second is one it makes between windows.
        #expect(PaneTheme.unfocusedScrim > PaneTheme.inactiveScrim)
        #expect(PaneTheme.unfocusedScrim <= 0.34)
    }

    @Test func aThemeWithAShortAnsiPaletteFallsBackToTheForeground() {
        // A theme parsed out of a config file that declares only a few palette
        // entries must not index past the end inside a draw call. There is no
        // throwing channel here, so the fallible read answers with something
        // drawable, the way a failed working-directory read keeps the last
        // known directory.
        let sparse = PaneTheme(
            background: RGB.eightBit(0x00, 0x00, 0x00),
            foreground: RGB.eightBit(0xFF, 0xFF, 0xFF),
            focusedAccent: RGB.eightBit(0xB5, 0xD5, 0xFF),
            ansi: []
        )
        #expect(sparse.color(for: .alert, focused: true) == sparse.foreground)
        // And the newer roles take the same route rather than trapping.
        #expect(sparse.ok == sparse.foreground)
        #expect(sparse.info == sparse.foreground)
    }

    @Test func darkPastelReproducesTheOwnersGhosttyConfig() {
        // `theme Dark Pastel` with `background #141414` from
        // `vault/projects/ghostty/config.ghostty`. baia looking like his
        // terminal on first launch is the point; a default palette of its own
        // would make the first pane look like a different app.
        let theme = PaneTheme.darkPastel
        #expect(theme.background.hexString == "#141414")
        #expect(theme.foreground.hexString == "#bbbbbb")
        #expect(theme.focusedAccent.hexString == "#b5d5ff")
        #expect(theme.ansi.count == 16)
        #expect(theme.ansi[1].hexString == "#ff5555")
    }
}
