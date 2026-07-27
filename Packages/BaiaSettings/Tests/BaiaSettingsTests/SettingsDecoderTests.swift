import Foundation
import Testing

@testable import BaiaSettings

@Suite struct SettingsDecoderTests {
    private func decode(_ text: String) -> SettingsDecodeResult {
        SettingsDecoder.decode(Data(text.utf8))
    }

    @Test func emptyDataYieldsTheDefaultsAndReportsNothing() {
        let result = SettingsDecoder.decode(Data())
        #expect(result.settings == .defaultSettings)
        #expect(result.unknownKeys.isEmpty)
        #expect(result.invalidKeys.isEmpty)
        #expect(!result.documentIsUnreadable)
    }

    @Test func aFileOfNothingButWhitespaceIsNotReportedAsBroken() {
        // What `touch` and an emptied editor buffer leave behind. It configures
        // nothing, which is different from being malformed, and an error in front of
        // the owner for a file that says nothing at all is noise he cannot act on.
        let result = decode("\n\n\t ")
        #expect(result.settings == .defaultSettings)
        #expect(!result.documentIsUnreadable)
    }

    @Test func anEmptyObjectYieldsTheDefaults() {
        let result = decode("{}")
        #expect(result.settings == .defaultSettings)
        #expect(result.unknownKeys.isEmpty)
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func aFullyValidFileAppliesEveryFieldAndReportsNothing() {
        // Every value differs from its default, so a field the decoder forgets to
        // read fails on the value comparison. And because the unknown-key list is
        // built from the keys the decoder never asked for, a field read under a
        // misspelled name fails on `unknownKeys` instead. Between them, this is the
        // test that keeps the key spellings honest.
        let result = decode(#"""
        {
          "fontFamily": "SF Mono",
          "fontSize": 13,
          "themeName": "Solarized Light",
          "backgroundHex": "#fdf6e3",
          "backgroundOpacity": 1,
          "backgroundBlur": false,
          "windowPadding": 0,
          "windowPaddingBalance": false,
          "transparentTitlebar": false,
          "optionAsAlt": false,
          "cursorStyle": "bar",
          "projectRoots": ["~/Code", "/opt/src"],
          "discoveryMaxDepth": 2,
          "notificationsEnabled": false,
          "gitPollSeconds": 5,
          "activityPollSeconds": 0.5,
          "restoreSession": false,
          "focusAccent": "bone",
          "attentionStyle": "quiet"
        }
        """#)
        #expect(result.settings == Settings(
            fontFamily: "SF Mono",
            fontSize: 13,
            themeName: "Solarized Light",
            backgroundHex: "#fdf6e3",
            backgroundOpacity: 1,
            backgroundBlur: false,
            windowPadding: 0,
            windowPaddingBalance: false,
            transparentTitlebar: false,
            optionAsAlt: false,
            cursorStyle: .bar,
            projectRoots: [NSHomeDirectory() + "/Code", "/opt/src"],
            discoveryMaxDepth: 2,
            notificationsEnabled: false,
            gitPollSeconds: 5,
            activityPollSeconds: 0.5,
            restoreSession: false,
            focusAccent: .bone,
            attentionStyle: .quiet
        ))
        #expect(result.unknownKeys.isEmpty)
        #expect(result.invalidKeys.isEmpty)
        #expect(!result.documentIsUnreadable)
    }

    @Test func oneBadFieldLeavesEveryOtherFieldApplied() {
        // The whole reason this file format is decoded by hand. A synthesized
        // `Decodable` fails the entire object on the first bad value, which would
        // send all four of these settings back to their defaults over one typo.
        let result = decode(#"""
        {
          "fontSize": "thirteen",
          "themeName": "Solarized Light",
          "backgroundHex": "#abc",
          "cursorStyle": "bar",
          "restoreSession": false
        }
        """#)
        #expect(result.settings.fontSize == Settings.defaultSettings.fontSize)
        #expect(result.settings.themeName == "Solarized Light")
        #expect(result.settings.backgroundHex == "#abc")
        #expect(result.settings.cursorStyle == .bar)
        #expect(!result.settings.restoreSession)
        #expect(result.invalidKeys == ["fontSize"])
    }

    @Test func unknownKeysAreReportedAndHarmless() {
        // A setting renamed between versions shows up here rather than as a value
        // that quietly stopped applying. The valid field alongside it must still
        // apply, since an unknown key is the file being ahead of the app rather than
        // wrong.
        let result = decode(#"{"fontSize": 13, "windowPaddingX": 4, "theme": "Nord"}"#)
        #expect(result.settings.fontSize == 13)
        #expect(result.unknownKeys == ["theme", "windowPaddingX"])
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func nullReadsAsUnsetRatherThanAsABadValue() {
        // The file baia writes itself carries `"fontFamily": null`, so reading a null
        // as a wrong type would make a first load report an invalid key in a file the
        // owner never touched. It must not read as unknown either.
        let result = decode(#"{"fontFamily": null, "fontSize": null}"#)
        #expect(result.settings == .defaultSettings)
        #expect(result.invalidKeys.isEmpty)
        #expect(result.unknownKeys.isEmpty)
    }

    @Test func aWrongJSONTypeForAnyFieldFallsBackAndIsReported() {
        // Every field in turn, with a value of a type it can never hold. The sweep is
        // what makes this non vacuous: a field read with the wrong accessor, a flag
        // read as a number say, would take the bad value instead of reporting it, and
        // a single hand-picked field would not catch it.
        let wrongValues = [
            "fontFamily": "12",
            "fontSize": #""13""#,
            "themeName": "true",
            "backgroundHex": "6",
            "backgroundOpacity": #""0.5""#,
            "backgroundBlur": "1",
            "windowPadding": #""8""#,
            "windowPaddingBalance": "0",
            "transparentTitlebar": #""yes""#,
            "optionAsAlt": "1",
            "cursorStyle": "true",
            "projectRoots": #""~/Projects""#,
            "discoveryMaxDepth": #""3""#,
            "notificationsEnabled": #""on""#,
            "gitPollSeconds": "false",
            "activityPollSeconds": "[1]",
            "restoreSession": "1",
        ]
        for (key, value) in wrongValues {
            let result = decode("{\"\(key)\": \(value)}")
            #expect(result.settings == .defaultSettings)
            #expect(result.invalidKeys == [key])
            #expect(result.unknownKeys.isEmpty)
            #expect(!result.documentIsUnreadable)
        }
    }

    @Test func aNestedObjectWhereAScalarWasExpectedIsReported() {
        // The shape a config gets when someone groups keys under a heading the way a
        // TOML file would. It must be reported rather than crashing on a cast.
        let result = decode(#"{"fontSize": {"value": 13}, "themeName": "Nord"}"#)
        #expect(result.settings.fontSize == Settings.defaultSettings.fontSize)
        #expect(result.settings.themeName == "Nord")
        #expect(result.invalidKeys == ["fontSize"])
    }

    @Test func aTopLevelArrayIsReportedAsUnreadable() {
        // No key can be blamed for it, so the flag is the only channel that can tell
        // the owner why nothing he wrote applied.
        let result = decode(#"[{"fontSize": 13}]"#)
        #expect(result.settings == .defaultSettings)
        #expect(result.documentIsUnreadable)
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func malformedJSONIsReportedAsUnreadable() {
        #expect(decode(#"{"fontSize": 13,}"#).documentIsUnreadable)
        #expect(decode(#"{"fontSize" 13}"#).documentIsUnreadable)
        #expect(decode("13").documentIsUnreadable)
    }

    @Test func invalidUTF8IsReportedAsUnreadable() {
        // A file saved in Latin-1 with an accented project path in it. The decoder
        // cannot see a single key, so the defaults apply and the flag carries the
        // reason.
        var data = Data(#"{"themeName": "caf"#.utf8)
        data.append(0xE9)
        data.append(contentsOf: Data(#""}"#.utf8))
        let result = SettingsDecoder.decode(data)
        #expect(result.settings == .defaultSettings)
        #expect(result.documentIsUnreadable)
    }

    @Test func fontSizeOfZeroOrNegativeFallsBackToTheDefault() {
        // Clamping to the 4 point floor would leave a terminal as unusable as a 0
        // point one, so the default is the only value known to work.
        #expect(decode(#"{"fontSize": 0}"#).settings.fontSize == Settings.defaultSettings.fontSize)
        #expect(decode(#"{"fontSize": -11.5}"#).settings.fontSize == Settings.defaultSettings.fontSize)
        #expect(decode(#"{"fontSize": 0}"#).invalidKeys == ["fontSize"])
    }

    @Test func anUnbelievablyLargeFontSizeFallsBackToTheDefault() {
        let result = decode(#"{"fontSize": 400}"#)
        #expect(result.settings.fontSize == Settings.defaultSettings.fontSize)
        #expect(result.invalidKeys == ["fontSize"])
    }

    @Test func aFontSizeThatParsedAsInfinityFallsBackToTheDefault() {
        // JSON has no NaN or infinity token, so this is how a non finite number gets
        // in: an exponent too large for a `Double`. It would satisfy every range
        // check written with `min` and `max`, which is why the check is `isFinite`.
        let result = decode(#"{"fontSize": 1e999}"#)
        #expect(result.settings.fontSize == Settings.defaultSettings.fontSize)
        #expect(result.invalidKeys == ["fontSize"])
    }

    @Test func aBelievableFontSizeAtTheEdgeOfTheRangeIsKept() {
        // The mirror of the three tests above. Without it they would all still pass
        // with a decoder that rejected every font size there is.
        #expect(decode(#"{"fontSize": 4}"#).settings.fontSize == 4)
        #expect(decode(#"{"fontSize": 72}"#).settings.fontSize == 72)
        #expect(decode(#"{"fontSize": 4}"#).invalidKeys.isEmpty)
    }

    @Test func opacityAboveOneOrBelowZeroIsClampedAndReported() {
        // Clamped rather than defaulted, because the intent survives it: 1.5 says
        // opaque and -0.2 says transparent. Reported anyway, since a silently
        // corrected value is indistinguishable from a key that does nothing.
        let high = decode(#"{"backgroundOpacity": 1.5}"#)
        #expect(high.settings.backgroundOpacity == 1)
        #expect(high.invalidKeys == ["backgroundOpacity"])

        let low = decode(#"{"backgroundOpacity": -0.2}"#)
        #expect(low.settings.backgroundOpacity == 0)
        #expect(low.invalidKeys == ["backgroundOpacity"])
    }

    @Test func anOpacityInsideTheRangeIsKeptAndNotReported() {
        let result = decode(#"{"backgroundOpacity": 0.5}"#)
        #expect(result.settings.backgroundOpacity == 0.5)
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func negativeWindowPaddingIsClampedToZero() {
        // Zero padding is a real preference, so the floor is 0 rather than the
        // default of 8: a negative value asks for no padding and gets it.
        let result = decode(#"{"windowPadding": -4}"#)
        #expect(result.settings.windowPadding == 0)
        #expect(result.invalidKeys == ["windowPadding"])
    }

    @Test func absurdWindowPaddingIsCappedRatherThanLeavingNoGrid() {
        let result = decode(#"{"windowPadding": 100000}"#)
        #expect(result.settings.windowPadding == 128)
        #expect(result.invalidKeys == ["windowPadding"])
    }

    @Test func discoveryDepthBelowOneIsClampedToOne() {
        // A depth of 0 walks nothing, so project discovery would find no projects and
        // report no reason for it.
        let result = decode(#"{"discoveryMaxDepth": 0}"#)
        #expect(result.settings.discoveryMaxDepth == 1)
        #expect(result.invalidKeys == ["discoveryMaxDepth"])
    }

    @Test func anAbsurdDiscoveryDepthIsCapped() {
        // The cost of a walk grows with the fan out of each level, so a stray 40
        // would stat the whole home directory on every launch.
        let result = decode(#"{"discoveryMaxDepth": 40}"#)
        #expect(result.settings.discoveryMaxDepth == 8)
        #expect(result.invalidKeys == ["discoveryMaxDepth"])
    }

    @Test func aFractionalDiscoveryDepthFallsBackRatherThanRounding() {
        // Rounding would apply a depth the file never asked for, and 2.5 is a typo
        // rather than a request for half a level.
        let result = decode(#"{"discoveryMaxDepth": 2.5}"#)
        #expect(result.settings.discoveryMaxDepth == Settings.defaultSettings.discoveryMaxDepth)
        #expect(result.invalidKeys == ["discoveryMaxDepth"])
    }

    @Test func aPollIntervalOfZeroIsClampedToTheFloor() {
        // A typo of 0 would otherwise spin a poll timer at whatever rate the run loop
        // grants, which presents as a hot fan and no error anywhere.
        let result = decode(#"{"gitPollSeconds": 0, "activityPollSeconds": -1}"#)
        #expect(result.settings.gitPollSeconds == 0.25)
        #expect(result.settings.activityPollSeconds == 0.25)
        #expect(result.invalidKeys == ["activityPollSeconds", "gitPollSeconds"])
    }

    @Test func aPollIntervalLongerThanAnHourIsCapped() {
        // An hour is already indistinguishable from disabled, and a stray exponent
        // would otherwise leave a feature reading as enabled while nothing fires.
        let result = decode(#"{"activityPollSeconds": 1e9}"#)
        #expect(result.settings.activityPollSeconds == 3600)
        #expect(result.invalidKeys == ["activityPollSeconds"])
    }

    @Test func aPollIntervalInsideTheRangeIsKept() {
        let result = decode(#"{"gitPollSeconds": 0.25, "activityPollSeconds": 30}"#)
        #expect(result.settings.gitPollSeconds == 0.25)
        #expect(result.settings.activityPollSeconds == 30)
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func backgroundHexTakesBothTheLongAndTheShortForm() {
        #expect(decode(##"{"backgroundHex": "#1F2A3b"}"##).settings.backgroundHex == "#1F2A3b")
        #expect(decode(##"{"backgroundHex": "#abc"}"##).settings.backgroundHex == "#abc")
        #expect(decode(##"{"backgroundHex": "#abc"}"##).invalidKeys.isEmpty)
    }

    @Test func aMalformedBackgroundHexFallsBackAndIsReported() {
        // ghostty would drop each of these without a diagnostic, so the pane would
        // keep the theme's own pure black and nothing would say why.
        for hex in ["141414", "#12345", "#GGGGGG", "#", "#abcd", "#１２３"] {
            let result = decode(#"{"backgroundHex": "\#(hex)"}"#)
            #expect(result.settings.backgroundHex == Settings.defaultSettings.backgroundHex)
            #expect(result.invalidKeys == ["backgroundHex"])
        }
    }

    @Test func anUnknownCursorStyleFallsBackAndIsReported() {
        // `block_hollow` is a real ghostty style that baia does not offer, so it is
        // the case that proves the check is against baia's list rather than a guess
        // at what the terminal might accept.
        let result = decode(#"{"cursorStyle": "block_hollow"}"#)
        #expect(result.settings.cursorStyle == .block)
        #expect(result.invalidKeys == ["cursorStyle"])
    }

    @Test func projectRootsAreTildeExpanded() {
        // A literal `~` directory exists nowhere, so an unexpanded root would make
        // discovery find nothing and report no error at all.
        let result = decode(#"{"projectRoots": ["~/Projects", "/opt/src"]}"#)
        #expect(result.settings.projectRoots == [NSHomeDirectory() + "/Projects", "/opt/src"])
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func anEmptyProjectRootsListIsARealChoice() {
        // Not the same as an absent key: an empty list turns discovery off, and
        // falling back to the default here would keep scanning a workspace the owner
        // asked baia to leave alone.
        let result = decode(#"{"projectRoots": []}"#)
        #expect(result.settings.projectRoots == [])
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func projectRootsContainingANonStringDegradeToTheDefault() {
        // Skipping the bad element instead would leave a workspace with a missing
        // project and no explanation for it.
        let result = decode(#"{"projectRoots": ["~/Projects", 7]}"#)
        #expect(result.settings.projectRoots == Settings.defaultSettings.projectRoots)
        #expect(result.invalidKeys == ["projectRoots"])
    }

    @Test func anEmptyStringAmongTheProjectRootsIsDroppedAndReported() {
        let result = decode(#"{"projectRoots": ["~/Projects", ""]}"#)
        #expect(result.settings.projectRoots == [NSHomeDirectory() + "/Projects"])
        #expect(result.invalidKeys == ["projectRoots"])
    }

    @Test func anEmptyThemeNameOrFontFamilyIsReported() {
        // Both would send ghostty back to its own default while the file names a
        // value, which reads as the key having no effect.
        let theme = decode(#"{"themeName": ""}"#)
        #expect(theme.settings.themeName == Settings.defaultSettings.themeName)
        #expect(theme.invalidKeys == ["themeName"])

        let font = decode(#"{"fontFamily": ""}"#)
        #expect(font.settings.fontFamily == nil)
        #expect(font.invalidKeys == ["fontFamily"])
    }

    @Test func reportedKeysAreSortedAndEachAppearsOnce() {
        // A `Dictionary`'s key order is not stable between runs, and the app renders
        // these lists: an order that reshuffles on every launch reads as the file
        // having changed when it did not. Sorting is the only thing that makes an
        // equality assertion on either list possible at all.
        let result = decode(#"""
        {
          "zzz": 1,
          "aaa": 2,
          "themeName": 3,
          "fontSize": "x",
          "windowPadding": -1e999
        }
        """#)
        #expect(result.unknownKeys == ["aaa", "zzz"])
        #expect(result.invalidKeys == ["fontSize", "themeName", "windowPadding"])
    }

    @Test func anUnspellableDesignValueFallsBackWithoutTakingTheOthersWithIt() {
        // Two bad spellings at once, each reported by name and each falling back on
        // its own. The valid key in the same document still applies, which is the
        // property that matters: a file with one typo in it must not revert the
        // keys around the typo.
        let result = decode(#"""
        {
          "focusAccent": "#B5D5FF",
          "attentionStyle": "LOUD",
          "themeName": "Nord"
        }
        """#)
        #expect(result.settings.focusAccent == .accent)
        #expect(result.settings.attentionStyle == .loud)
        #expect(result.settings.themeName == "Nord")
        #expect(result.invalidKeys == ["attentionStyle", "focusAccent"])
    }

    @Test func aHexInTheFocusAccentIsRejectedRatherThanHonoured() {
        // The one wrong answer a reasonable person will try, since every other
        // colour in the config file is a hex. Honouring it would break the rule the
        // whole derivation scheme exists for: a literal survives a theme switch that
        // moves everything around it, and no contrast figure in `PaneTheme` would
        // still hold.
        // Doubled delimiters: a `#` inside a single-hashed raw string closes it at
        // the `"#` of the hex, which is a fine demonstration of why the config
        // takes a name.
        #expect(decode(##"{"focusAccent": "#e0e0e0"}"##).invalidKeys == ["focusAccent"])
        #expect(decode(#"{"focusAccent": "bone"}"#).settings.focusAccent == .bone)
    }

    @Test func theRetiredFocusKeysAreReportedRatherThanQuietlySwallowed() {
        // The owner's own file carries both of these, so this is the migration
        // decision written down. They are reported as unknown, which costs a line on
        // stderr at every launch until he deletes them, and that is the point: the
        // alternative is accepting a key that does nothing, which is precisely the
        // failure `focusAccent` spent nine days in. Nothing about the deletion is
        // recoverable by keeping the value, since there is no longer a treatment for
        // it to select.
        let result = decode(#"""
        {
          "focusStyle": "recede",
          "unfocusedScrim": 0.28,
          "attentionStyle": "quiet"
        }
        """#)
        #expect(result.unknownKeys == ["focusStyle", "unfocusedScrim"])
        // Reported, not fatal: every key beside them still applies, the same way an
        // unknown key from a newer baia would.
        #expect(result.settings.attentionStyle == .quiet)
        #expect(result.invalidKeys.isEmpty)
        #expect(!result.documentIsUnreadable)
    }
}
