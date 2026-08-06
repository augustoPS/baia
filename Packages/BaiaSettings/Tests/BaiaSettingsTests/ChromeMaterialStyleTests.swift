import Foundation
import Testing

@testable import BaiaSettings

/// The `chromeStyle` key: whether the chrome renders flat (the shipped spec) or
/// asks for the v5 glass materials.
///
/// Modelled on `SidebarContentTests` rather than `CursorStyleTests`, because this
/// key never reaches ghostty and an unknown spelling has a specific fallback to
/// pin: `flat`, not a value chosen by enum declaration order.
@Suite struct ChromeMaterialStyleTests {
    private func decode(_ text: String) -> SettingsDecodeResult {
        SettingsDecoder.decode(Data(text.utf8))
    }

    @Test func rawValuesAreTheSpellingsTheConfigFileUses() {
        #expect(ChromeStyle.allCases.map(\.rawValue) == ["flat", "glass"])
    }

    @Test func glassIsTheDefault() {
        // Glass since 2026-08-06, the owner's call once the wells audit and
        // the glass live pass both came back clean. Flat remains the Reduce
        // Transparency rendering and `resolvedStyle` forces it there, so the
        // default never costs legibility.
        #expect(Settings.defaultSettings.chromeStyle == .glass)
    }

    @Test func anAbsentKeyLeavesTheDefaultAlone() {
        let result = decode("{}")
        #expect(result.settings.chromeStyle == .glass)
        #expect(result.invalidKeys.isEmpty)
        #expect(result.unknownKeys.isEmpty)
    }

    @Test(arguments: ChromeStyle.allCases)
    func everyStyleDecodes(style: ChromeStyle) {
        let result = decode(#"{"chromeStyle": "\#(style.rawValue)"}"#)
        #expect(result.settings.chromeStyle == style)
        #expect(result.invalidKeys.isEmpty)
    }

    /// An unknown spelling falls back to the default rather than to whatever
    /// `init(rawValue:)` would leave the value at, and it reports itself
    /// invalid instead of failing silently the way `focusAccent` did for nine
    /// days.
    @Test(arguments: ["Flat ", "FLAT!", "liquid", "translucent", ""])
    func anUnknownSpellingFallsBackToTheDefaultAndReportsItself(value: String) {
        let result = decode(#"{"chromeStyle": "\#(value)"}"#)
        #expect(result.settings.chromeStyle == .glass)
        #expect(result.invalidKeys.contains("chromeStyle"))
    }

    @Test func aBadChromeStyleLeavesEveryOtherFieldApplied() {
        let result = decode(#"{"chromeStyle": "liquid", "fontSize": 13}"#)
        #expect(result.settings.chromeStyle == .glass)
        #expect(result.settings.fontSize == 13)
        #expect(result.invalidKeys == ["chromeStyle"])
    }

    @Test func theKeyDoesNotReadAsUnknown() {
        #expect(decode(#"{"chromeStyle": "glass"}"#).unknownKeys.isEmpty)
    }

    @Test func theKeyIsPresentInAFirstLaunchConfig() {
        // The acceptance criterion: a key nobody wrote yet is still readable in
        // the file the app writes on first launch, the same guard
        // `SettingsStoreTests` runs for every other key.
        #expect(SettingsDecoder.knownKeys.contains("chromeStyle"))
        #expect(SettingsWriter.keyOrder.contains("chromeStyle"))
    }
}
