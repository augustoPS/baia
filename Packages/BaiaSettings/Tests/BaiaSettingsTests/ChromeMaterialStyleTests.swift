import Foundation
import Testing

@testable import BaiaSettings

/// The `chromeStyle` key: how much of the desktop the chrome lets through, on
/// the three-way `solid` / `liquidGlass` / `sheer` split of 2026-08-15.
///
/// Modelled on `SidebarContentTests` rather than `CursorStyleTests`, because this
/// key never reaches ghostty and an unknown spelling has a specific fallback to
/// pin rather than a value chosen by enum declaration order.
///
/// Carries the rename's own guard: `flat` and `glass` were this key's spellings
/// until 2026-08-15 and still decode, which is what keeps an existing config
/// file rendering as it did.
@Suite struct ChromeMaterialStyleTests {
    private func decode(_ text: String) -> SettingsDecodeResult {
        SettingsDecoder.decode(Data(text.utf8))
    }

    @Test func rawValuesAreTheSpellingsTheConfigFileUses() {
        #expect(ChromeStyle.allCases.map(\.rawValue) == ["solid", "liquidGlass", "sheer"])
    }

    /// Every style has a display name, and none of them is the raw value
    /// capitalized.
    ///
    /// The reason the property exists: `rawValue.capitalized` renders
    /// `liquidGlass` as "Liquidglass", which shipped in no picker but was one
    /// line away from it. Pinned per case rather than as "not equal to
    /// capitalized", so a future case gets an entry rather than a passing test.
    @Test func everyStyleHasAPickerName() {
        #expect(ChromeStyle.solid.displayName == "Solid")
        #expect(ChromeStyle.liquidGlass.displayName == "Liquid Glass")
        #expect(ChromeStyle.sheer.displayName == "Sheer")
    }

    /// Only `solid` ignores the opacity slider.
    ///
    /// The predicate the settings surface hides the Opacity and Blur rows on. It
    /// has to agree with `PaneChrome.windowIsTransparent`, which is what
    /// actually makes solid opaque; a disagreement shows up as a slider that is
    /// on screen and inert, or one that is hidden while still doing something.
    @Test func onlySolidIgnoresTheOpacitySlider() {
        #expect(!ChromeStyle.solid.usesBackgroundOpacity)
        #expect(ChromeStyle.liquidGlass.usesBackgroundOpacity)
        #expect(ChromeStyle.sheer.usesBackgroundOpacity)
    }

    /// The 2026-08-15 rename does not strand a config file written before it.
    ///
    /// Pinned here rather than left to ``ChromeStyle/named(_:)``'s own doc
    /// comment, because the failure it guards is silent: an unrecognised
    /// spelling falls back to the default and the owner's chrome changes with
    /// nothing on screen saying why. Each old spelling must resolve to the case
    /// that renders what it always rendered — `flat` was opaque fills with no
    /// material, `glass` was the native material, and neither was `sheer`.
    @Test func theSpellingsFromBeforeTheRenameStillDecode() {
        #expect(ChromeStyle.named("flat") == .solid)
        #expect(ChromeStyle.named("glass") == .liquidGlass)
        #expect(ChromeStyle.named("sheer") == .sheer)
        #expect(ChromeStyle.named("nonsense") == nil)
    }

    /// A config file holding a pre-rename spelling decodes and applies rather
    /// than reporting itself invalid.
    ///
    /// The end-to-end half of the test above: `named(_:)` resolving correctly is
    /// worth nothing if `SettingsDecoder` still reaches for `init(rawValue:)`.
    @Test func aConfigWrittenBeforeTheRenameStillApplies() {
        let result = decode(#"{"chromeStyle": "glass"}"#)
        #expect(result.settings.chromeStyle == .liquidGlass)
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func glassIsTheDefault() {
        // Glass since 2026-08-06, the owner's call once the wells audit and
        // the glass live pass both came back clean. Flat remains the Reduce
        // Transparency rendering and `resolvedStyle` forces it there, so the
        // default never costs legibility.
        #expect(Settings.defaultSettings.chromeStyle == .liquidGlass)
    }

    @Test func anAbsentKeyLeavesTheDefaultAlone() {
        let result = decode("{}")
        #expect(result.settings.chromeStyle == .liquidGlass)
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
        #expect(result.settings.chromeStyle == .liquidGlass)
        #expect(result.invalidKeys.contains("chromeStyle"))
    }

    @Test func aBadChromeStyleLeavesEveryOtherFieldApplied() {
        let result = decode(#"{"chromeStyle": "liquid", "fontSize": 13}"#)
        #expect(result.settings.chromeStyle == .liquidGlass)
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
