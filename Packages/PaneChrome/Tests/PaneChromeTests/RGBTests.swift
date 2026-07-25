import Foundation
import Testing

@testable import PaneChrome

@Suite struct RGBTests {
    @Test func hexParsesBothThreeAndSixDigitForms() {
        // `#RGB` doubles each digit rather than padding it, which is the CSS
        // rule. Padding would turn `#fff` into `#f0f0f0`, a colour nobody
        // wrote.
        #expect(RGB(hex: "#ffffff") == RGB(hex: "#fff"))
        #expect(RGB(hex: "#141414")?.hexString == "#141414")
        #expect(RGB(hex: "#f0a")?.hexString == "#ff00aa")
    }

    @Test func hexParsesWithOrWithoutTheLeadingHashAndInEitherCase() {
        // The values that reach this come from the owner's ghostty config,
        // which writes the hash, and from pasted palette tables, which often do
        // not and are often uppercase.
        #expect(RGB(hex: "141414") == RGB(hex: "#141414"))
        #expect(RGB(hex: "#B5D5FF") == RGB(hex: "#b5d5ff"))
    }

    @Test func anInvalidHexReturnsNil() {
        #expect(RGB(hex: "") == nil)
        #expect(RGB(hex: "#") == nil)
        #expect(RGB(hex: "#12") == nil)
        #expect(RGB(hex: "#12345") == nil)
        #expect(RGB(hex: "#1234567") == nil)
        #expect(RGB(hex: "#gggggg") == nil)
        // Eight digits is a real spelling elsewhere, `#rrggbbaa`, and this type
        // has no alpha to put the last pair in. Silently dropping it would
        // return a colour at full opacity that the author asked to be
        // transparent.
        #expect(RGB(hex: "#ffffff80") == nil)
    }

    @Test func hexStringRoundTripsThroughTheParser() {
        // Round trips through the parser rather than comparing to a literal, so
        // the test covers the rounding in both directions. The owner pastes
        // these values back into `config.ghostty`, where a colour one step off
        // is a colour that does not match his terminal.
        let colour = RGB.eightBit(0x21, 0x9A, 0x03)
        #expect(RGB(hex: colour.hexString) == colour)
    }

    @Test func isDarkUsesGhosttysLuminanceThresholdRatherThanWcagLuminance() {
        // The one grey band where the two formulas disagree. `#999999` weighs
        // 153 of 255 on ghostty's average, above its 128 threshold, so the
        // terminal treats it as a light background; its WCAG relative luminance
        // is about 0.32, below the 0.5 a WCAG-based test would split on.
        // Asserting this on black or white would pass under either formula and
        // notice nothing.
        let grey = RGB(hex: "#999999")
        #expect(grey?.isDark == false)
        #expect((grey?.relativeLuminance ?? 1) < 0.5)
    }

    @Test func theOwnersTerminalBackgroundReadsAsDark() {
        // `background #141414`, lifted off pure black deliberately. The lift
        // must not be enough to flip the theme test, since every chrome colour
        // is chosen from it.
        #expect(RGB(hex: "#141414")?.isDark == true)
    }

    @Test func blendingHalfwayLandsBetweenTheEnds() {
        let black = RGB(red: 0, green: 0, blue: 0)
        let white = RGB(red: 1, green: 1, blue: 1)
        #expect(black.blended(with: white, fraction: 0.5) == RGB(red: 0.5, green: 0.5, blue: 0.5))
        #expect(black.blended(with: white, fraction: 0) == black)
        #expect(black.blended(with: white, fraction: 1) == white)
    }

    @Test func aBlendFractionOutsideZeroToOneCannotOvershoot() {
        // An overshoot comes back as a colour on the far side of the target,
        // which reads as the blend running backwards: a bar asked to lift 20%
        // towards the foreground would end up darker than the background it
        // started from.
        let black = RGB(red: 0, green: 0, blue: 0)
        let white = RGB(red: 1, green: 1, blue: 1)
        #expect(white.blended(with: black, fraction: 2) == black)
        #expect(white.blended(with: black, fraction: -1) == white)
    }

    @Test func componentsOutsideZeroToOneAreClamped() {
        // Clamped on the way in for the same reason `Anchor.init` canonicalizes
        // its URL: two colours the app cannot tell apart must not compare
        // unequal. A component above 1 also pushes relativeLuminance above 1,
        // which drives contrastRatio below 1 and makes every candidate fail
        // every threshold.
        #expect(RGB(red: 2, green: -1, blue: 0.5) == RGB(red: 1, green: 0, blue: 0.5))
        #expect(abs(RGB(red: 2, green: 2, blue: 2).relativeLuminance - 1) < 0.000001)
    }

    @Test func contrastRatioIsSymmetricAndBottomsOutAtOne() {
        let dark = RGB.eightBit(0x14, 0x14, 0x14)
        let pale = RGB.eightBit(0xBB, 0xBB, 0xBB)
        #expect(dark.contrastRatio(against: pale) == pale.contrastRatio(against: dark))
        #expect(dark.contrastRatio(against: dark) == 1)
    }

    @Test func blackAgainstWhiteIsTheTopOfTheScale() {
        // 21:1 is the maximum the WCAG ratio can produce, and hitting it
        // exactly is what says the transfer function and the 0.05 offsets are
        // both right. A linearization that skipped the gamma curve lands near
        // 20.
        let ratio = RGB(red: 0, green: 0, blue: 0)
            .contrastRatio(against: RGB(red: 1, green: 1, blue: 1))
        #expect(abs(ratio - 21) < 0.001)
    }

    @Test func eightBitComponentsMatchTheirHexSpelling() {
        // The palette in PaneTheme.darkPastel is written in 8-bit components to
        // keep a force unwrap of init(hex:) out of a static let, so the two
        // spellings have to agree or the theme is a different theme.
        #expect(RGB.eightBit(0xB5, 0xD5, 0xFF) == RGB(hex: "#b5d5ff"))
    }
}
