import Foundation
import Testing

@testable import BaiaSettings

/// The sidebar key.
///
/// Most of these assert the same property from different directions: the region
/// stays shut unless the file says otherwise, in the exact spelling. Opening it
/// resizes every pane in the window and signals every process running in them, so a
/// typo must not be what does that, and neither must an upgrade.
@Suite struct SidebarContentTests {
    private func decode(_ text: String) -> SettingsDecodeResult {
        SettingsDecoder.decode(Data(text.utf8))
    }

    @Test func theSidebarIsOffByDefault() {
        #expect(Settings.defaultSettings.sidebar == .off)
    }

    @Test func anAbsentKeyLeavesTheDefaultAlone() {
        let result = decode("{}")
        #expect(result.settings.sidebar == .off)
        #expect(result.invalidKeys.isEmpty)
        #expect(result.unknownKeys.isEmpty)
    }

    @Test(arguments: SidebarContent.allCases)
    func everyContentDecodes(content: SidebarContent) {
        let result = decode(#"{"sidebar": "\#(content.rawValue)"}"#)
        #expect(result.settings.sidebar == content)
        #expect(result.invalidKeys.isEmpty)
    }

    /// The spellings a reasonable person tries first, plus the two housings this key
    /// used to name. All of them are rejected: `sidebar` says *what* the region
    /// shows, not whether it exists, so a value describing a housing belongs to the
    /// design this one replaced.
    @Test(arguments: ["on", "true", "sidebar", "panel", "git", "tree", "Files", ""])
    func anUnknownContentIsRejectedByNameAndLeavesTheSidebarOff(value: String) {
        let result = decode(#"{"sidebar": "\#(value)"}"#)
        #expect(result.settings.sidebar == .off)
        #expect(result.invalidKeys.contains("sidebar"))
    }

    /// The retired keys land in `unknownKeys` rather than being quietly accepted,
    /// which is what tells someone carrying the old config that his line stopped
    /// doing anything, instead of leaving him to notice on his own.
    @Test(arguments: ["gitPanel", "fileTree"])
    func aRetiredHousingKeyIsReportedAsUnknown(key: String) {
        let result = decode(#"{"\#(key)": "sidebar"}"#)
        #expect(result.unknownKeys.contains(key))
        #expect(result.settings.sidebar == .off)
    }

    /// A rejected sidebar must not take another key with it, the same per-field
    /// resilience every other key in this decoder has.
    @Test func aBadSidebarLeavesEveryOtherFieldApplied() {
        let result = decode(#"{"sidebar": "panel", "fontSize": 13}"#)
        #expect(result.settings.sidebar == .off)
        #expect(result.settings.fontSize == 13)
        #expect(result.invalidKeys == ["sidebar"])
    }

    /// `off` is spelled, not only implied. Closing the sidebar by hand should be a
    /// value you can write rather than a line you have to delete.
    @Test func offIsAValueAndNotOnlyAnAbsence() {
        let result = decode(#"{"sidebar": "off"}"#)
        #expect(result.settings.sidebar == .off)
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func theKeyDoesNotReadAsUnknown() {
        #expect(decode(#"{"sidebar": "changes"}"#).unknownKeys.isEmpty)
    }
}
