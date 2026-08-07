import Foundation
import Testing

@testable import BaiaSettings

@Suite struct TerminalOverrideTests {
    @Test func defaultsEmitTheGhosttyConfigTheOwnerAlreadyRuns() {
        // Key names and value spellings are both transcribed from
        // vault/projects/ghostty/config.ghostty. ghostty ignores a key it does not
        // recognise and gives no diagnostic for it, so a misspelled key here is a
        // setting that appears to work and does nothing, invisible in every other
        // test in this package. Comparing the whole list also pins the order the
        // builder receives them in.
        #expect(Settings.defaultSettings.terminalOverrides == [
            TerminalOverride(key: "theme", value: "Dark Pastel"),
            TerminalOverride(key: "background", value: "#141414"),
            TerminalOverride(key: "background-opacity", value: "0.42"),
            TerminalOverride(key: "background-blur", value: "true"),
            TerminalOverride(key: "font-size", value: "11.5"),
            TerminalOverride(key: "window-padding-x", value: "8"),
            TerminalOverride(key: "window-padding-y", value: "8"),
            TerminalOverride(key: "window-padding-balance", value: "true"),
            TerminalOverride(key: "macos-option-as-alt", value: "true"),
            TerminalOverride(key: "cursor-style", value: "block"),
        ])
    }

    @Test func aWholeNumberLosesItsDecimalPoint() {
        // `window-padding-x` is an integer key: ghostty rejects `8.0` for it and
        // keeps its own default, which presents as padding that silently did not
        // apply. `Double`'s own description would produce exactly that.
        var settings = Settings.defaultSettings
        settings.fontSize = 12
        settings.windowPadding = 16
        let overrides = settings.terminalOverrides
        #expect(overrides.contains(TerminalOverride(key: "font-size", value: "12")))
        #expect(overrides.contains(TerminalOverride(key: "window-padding-x", value: "16")))
        #expect(overrides.contains(TerminalOverride(key: "window-padding-y", value: "16")))
    }

    @Test func fractionalPaddingIsRoundedToAWholeNumber() {
        // The padding keys take integers, so an 8.6 read from a config file has to
        // arrive as 9 rather than as text ghostty will refuse.
        var settings = Settings.defaultSettings
        settings.windowPadding = 8.6
        #expect(settings.terminalOverrides
            .contains(TerminalOverride(key: "window-padding-x", value: "9")))
    }

    @Test func aFractionalFontSizeKeepsItsDecimal() {
        // The mirror of the two tests above: rounding everything would quietly turn
        // the owner's 11.5 into 12 and change how many columns fit a pane.
        #expect(Settings.defaultSettings.terminalOverrides
            .contains(TerminalOverride(key: "font-size", value: "11.5")))
    }

    @Test func fontFamilyIsEmittedOnlyWhenItIsSet() {
        var settings = Settings.defaultSettings
        #expect(!settings.terminalOverrides.contains { $0.key == "font-family" })

        settings.fontFamily = "SF Mono"
        #expect(settings.terminalOverrides
            .contains(TerminalOverride(key: "font-family", value: "SF Mono")))
    }

    @Test func anEmptyFontFamilyIsOmittedRatherThanSentEmpty() {
        // The decoder rejects an empty family, so this is only reachable by a caller
        // that built a `Settings` by hand. An empty `font-family` means different
        // things across ghostty versions and neither is worth depending on.
        var settings = Settings.defaultSettings
        settings.fontFamily = ""
        #expect(!settings.terminalOverrides.contains { $0.key == "font-family" })
    }

    @Test func theTitlebarStyleReachesGhosttyInNeitherDirection() {
        // Retired rather than remapped. `macos-titlebar-style` configures a
        // window ghostty created and baia gives it none, so the key was read by
        // nothing; the platform titlebar (an `NSToolbar` on the workspace
        // window) is the treatment now. The setting still decodes, so both
        // spellings are checked here: neither may reach the engine.
        for flag in [true, false] {
            var settings = Settings.defaultSettings
            settings.transparentTitlebar = flag
            #expect(!settings.terminalOverrides.contains { $0.key == "macos-titlebar-style" })
        }
    }

    @Test func everyBooleanHasAFalseSpellingToo() {
        // The defaults are all true, so the whole-list test above never exercises the
        // false branch of the boolean renderer. A `0` here would be dropped by
        // ghostty's parser on the keys that take a real boolean.
        var settings = Settings.defaultSettings
        settings.backgroundBlur = false
        settings.windowPaddingBalance = false
        settings.optionAsAlt = false
        let overrides = settings.terminalOverrides
        #expect(overrides.contains(TerminalOverride(key: "background-blur", value: "false")))
        #expect(overrides.contains(TerminalOverride(key: "window-padding-balance", value: "false")))
        #expect(overrides.contains(TerminalOverride(key: "macos-option-as-alt", value: "false")))
    }

    @Test func theCursorStyleIsSentUnderGhosttysKeyName() {
        var settings = Settings.defaultSettings
        settings.cursorStyle = .underline
        #expect(settings.terminalOverrides
            .contains(TerminalOverride(key: "cursor-style", value: "underline")))
    }
}
