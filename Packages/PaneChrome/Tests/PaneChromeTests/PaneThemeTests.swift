import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneThemeTests {
    /// Every emphasis, so the sweeping assertions cannot miss one that was added
    /// to the enum later. ``PaneStatusEmphasis`` is not `CaseIterable` in the
    /// public API, since nothing outside a test wants to enumerate it.
    private let emphases: [PaneStatusEmphasis] = [.normal, .strong, .muted, .alert]

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
        // would answer identically for both. The bar is a lifted blend of the
        // terminal background, and a focused bar is lifted further, so judging
        // against the theme background is off by a whole ratio point where it
        // matters.
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

    @Test func theFocusedBarBackgroundDiffersFromTheUnfocusedOne() {
        // Focus has to be visible somewhere, and colour is the only place it is
        // allowed to be: the height is a constant precisely so that focus
        // cannot be shown by growing the bar.
        let theme = PaneTheme.darkPastel
        #expect(theme.focusedBarBackground != theme.barBackground)
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
        #expect(theme.focusedBarBackground.isDark)
    }

    @Test func everyEmphasisClearsTheMinimumContrastOnBothBars() {
        // The invariant the whole colour chain exists for. It is checked on the
        // focused bar as well, which is the harder one: the accent tint lifts
        // it, and a tint chosen for looks rather than for this would put the
        // alert red under the threshold there while it still passed unfocused.
        let theme = PaneTheme.darkPastel
        for emphasis in emphases {
            let focused = theme.color(for: emphasis, focused: true)
            let unfocused = theme.color(for: emphasis, focused: false)
            #expect(focused.contrastRatio(against: theme.focusedBarBackground)
                >= PaneTheme.minimumTextContrast)
            #expect(unfocused.contrastRatio(against: theme.barBackground)
                >= PaneTheme.minimumTextContrast)
        }
    }

    @Test func everyEmphasisClearsTheMinimumContrastOnALightTheme() {
        for emphasis in emphases {
            #expect(paper.color(for: emphasis, focused: true)
                .contrastRatio(against: paper.focusedBarBackground)
                >= PaneTheme.minimumTextContrast)
            #expect(paper.color(for: emphasis, focused: false)
                .contrastRatio(against: paper.barBackground)
                >= PaneTheme.minimumTextContrast)
        }
    }

    @Test func anUnfocusedPaneDimsItsTextButNeverItsAlerts() {
        // The pane that needs the owner is by definition not the one he is
        // looking at. The signal this replaces is a single `afplay Blow.aiff`
        // on the Stop hook, identical for every session, and dimming its
        // replacement in exactly the panes it is meant for would put baia back
        // where it started.
        let theme = PaneTheme.darkPastel
        #expect(theme.color(for: .normal, focused: false) != theme.color(for: .normal, focused: true))
        #expect(theme.color(for: .alert, focused: false) == theme.color(for: .alert, focused: true))
    }

    @Test func onlyTheFocusedPaneSpendsTheAccent() {
        // What makes one bar out of five identifiable at a glance, with none of
        // them changing size.
        let theme = PaneTheme.darkPastel
        #expect(theme.color(for: .strong, focused: true) == theme.focusedAccent)
        #expect(theme.color(for: .strong, focused: false) != theme.focusedAccent)
    }

    @Test func theProjectNameStaysFullStrengthInAnUnfocusedPane() {
        // Scanning a wall of unfocused panes for a project name is the thing
        // the bar exists for, so strong does not dim while normal does. Without
        // this the two emphases collapse to one colour in every pane the owner
        // is not typing in.
        let theme = PaneTheme.darkPastel
        #expect(theme.color(for: .strong, focused: false) != theme.color(for: .normal, focused: false))
    }

    @Test func mutedIsDimmerThanNormalWithoutBeingRepairedBackUp() {
        // The muted fade and the minimum ratio pull against each other: fade
        // harder and readable() repairs the result straight back to something
        // brighter, which quietly makes muted mean nothing.
        let theme = PaneTheme.darkPastel
        let muted = theme.color(for: .muted, focused: true)
        let normal = theme.color(for: .normal, focused: true)
        #expect(muted != normal)
        #expect(muted.relativeLuminance < normal.relativeLuminance)
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
