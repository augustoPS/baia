import BaiaSettings
import Testing

@testable import PaneChrome

@Suite struct PaneThemePaletteTests {
    /// Dark Pastel as the theme catalog spells it: no `#`, and a full palette.
    private static let darkPastelPalette: [Int: String] = [
        0: "000000", 1: "ff5555", 2: "55ff55", 3: "ffff55",
        4: "5555ff", 5: "ff55ff", 6: "55ffff", 7: "bbbbbb",
        8: "555555", 9: "ff5555", 10: "55ff55", 11: "ffff55",
        12: "5555ff", 13: "ff55ff", 14: "55ffff", 15: "ffffff",
    ]

    @Test func afullPaletteMapsIndexForIndex() {
        let theme = PaneTheme(
            background: "#141414",
            foreground: "#bbbbbb",
            selectionBackground: "#b5d5ff",
            palette: Self.darkPastelPalette
        )
        #expect(theme.background == RGB.eightBit(0x14, 0x14, 0x14))
        #expect(theme.foreground == RGB.eightBit(0xBB, 0xBB, 0xBB))
        #expect(theme.focusedAccent == RGB.eightBit(0xB5, 0xD5, 0xFF))
        #expect(theme.ansi.count == 16)
        #expect(theme.ansi[1] == RGB.eightBit(0xFF, 0x55, 0x55))
        #expect(theme.ansi[15] == RGB.eightBit(0xFF, 0xFF, 0xFF))
    }

    /// The catalog writes its palette without a leading `#` while `background`
    /// and `foreground` carry one, so both spellings have to work or half a theme
    /// comes back grey.
    @Test func bothHexSpellingsAreAccepted() {
        let withHash = PaneTheme(
            background: "#141414", foreground: "#bbbbbb",
            selectionBackground: nil, palette: [1: "#ff5555"]
        )
        let without = PaneTheme(
            background: "141414", foreground: "bbbbbb",
            selectionBackground: nil, palette: [1: "ff5555"]
        )
        #expect(withHash.background == without.background)
        #expect(withHash.ansi[1] == without.ansi[1])
    }

    /// A theme declaring only a handful of slots is tolerated rather than
    /// trapping, which is the promise `PaneTheme.ansi` already makes. The missing
    /// slots take the foreground, so a segment coloured from one of them is dull
    /// rather than invisible.
    @Test func missingPaletteSlotsFallBackToTheForeground() {
        let theme = PaneTheme(
            background: "#141414", foreground: "#bbbbbb",
            selectionBackground: nil, palette: [1: "ff5555", 2: "55ff55"]
        )
        #expect(theme.ansi.count == 16)
        #expect(theme.ansi[1] == RGB.eightBit(0xFF, 0x55, 0x55))
        #expect(theme.ansi[9] == theme.foreground)
        #expect(theme.ansi[15] == theme.foreground)
    }

    /// A hex the parser rejects must not become black. Black is a legitimate
    /// colour, so a failed parse that produced it would read as a deliberate
    /// choice and there would be nothing to notice.
    @Test func aMalformedBackgroundKeepsTheKnownGoodDefault() {
        let theme = PaneTheme(
            background: "not-a-colour", foreground: "#zzzzzz",
            selectionBackground: nil, palette: [:]
        )
        #expect(theme.background == PaneTheme.darkPastel.background)
        #expect(theme.foreground == PaneTheme.darkPastel.foreground)
    }

    /// Most catalog themes declare no selection background at all, so the
    /// fallback is the ordinary path rather than the exceptional one. It has to
    /// clear the contrast floor against the bar it will be drawn on, since the
    /// focused pane's name is the one place the accent still appears.
    @Test func aMissingSelectionBackgroundDerivesAReadableAccent() {
        let theme = PaneTheme(
            background: "#141414", foreground: "#bbbbbb",
            selectionBackground: nil, palette: Self.darkPastelPalette
        )
        #expect(theme.focusedAccent != theme.background)
        #expect(theme.color(for: .strong, focused: true, on: theme.barBackground)
            .contrastRatio(against: theme.barBackground) >= PaneTheme.minimumTextContrast)
    }

    /// The bug this initializer's `focusAccent` parameter exists to make
    /// impossible. The key was decoded, stored and covered by its own tests
    /// while this construction resolved the accent from the selection colour and
    /// never consulted the setting, so `"focusAccent": "bone"` was a no-op in a
    /// config file that reported no error. Every earlier test here passes with
    /// the setting ignored; this is the one that does not.
    @Test func theConfiguredFocusAccentReachesTheTheme() {
        let bone = PaneTheme(
            background: "#141414", foreground: "#bbbbbb",
            selectionBackground: "#b5d5ff", palette: Self.darkPastelPalette,
            focusAccent: .bone
        )
        #expect(bone.focusedAccent.hexString == "#e0e0e0")

        // `accent` keeps the theme's declared selection colour, which is what
        // makes the default a no-op and this release not a colour change.
        let declared = PaneTheme(
            background: "#141414", foreground: "#bbbbbb",
            selectionBackground: "#b5d5ff", palette: Self.darkPastelPalette,
            focusAccent: .accent
        )
        #expect(declared.focusedAccent.hexString == "#b5d5ff")
        // And the parameter's default is that same choice, so a caller written
        // before the key existed renders identically.
        #expect(PaneTheme(
            background: "#141414", foreground: "#bbbbbb",
            selectionBackground: "#b5d5ff", palette: Self.darkPastelPalette
        ) == declared)
    }

    /// A light theme has to survive the same path, because every contrast repair
    /// downstream is measured against a bar this decides the colour of.
    @Test func alightThemeStaysReadableThroughTheSameConstruction() {
        let theme = PaneTheme(
            background: "#fdf6e3", foreground: "#657b83",
            selectionBackground: nil, palette: [4: "268bd2"]
        )
        #expect(theme.background.isDark == false)
        for emphasis in [PaneStatusEmphasis.strong, .normal, .alert, .warn] {
            #expect(theme.color(for: emphasis, focused: true, on: theme.barBackground)
                .contrastRatio(against: theme.barBackground) >= PaneTheme.minimumTextContrast)
        }
    }
}
