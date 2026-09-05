import Foundation
import Testing

@testable import BaiaSettings

@Suite struct SettingsCategoryTests {
    @Test func everyActiveKeyLandsInExactlyOneCategory() {
        // Both directions: a key placed twice would draw two controls for one
        // field, and an active key placed nowhere would be a setting Settings
        // cannot reach. Compatibility-only keys are deliberate absences.
        let placed = SettingsCategory.allCases.flatMap(\.keys)
        #expect(Set(placed).count == placed.count)
        #expect(Set(placed) == Set(SettingsKey.allCases.filter(\.isActive)))
        #expect(SettingsCategory.containing(.backgroundBlur) == nil)
        #expect(SettingsCategory.containing(.transparentTitlebar) == nil)
    }

    @Test func theToolbarOrderAndFieldMappingAreTheSpecsTable() {
        #expect(SettingsCategory.allCases == [
            .appearance, .typography, .window, .workspace, .behavior, .notifications, .advanced,
        ])
        #expect(SettingsCategory.appearance.keys == [
            .themeName, .backgroundHex, .backgroundOpacity, .chromeStyle,
            .sidebar, .focusAccent, .attentionStyle, .attentionAccent, .alertBehavior,
        ])
        #expect(SettingsCategory.typography.keys == [.fontFamily, .fontSize, .cursorStyle])
        #expect(SettingsCategory.window.keys == [.windowPadding, .windowPaddingBalance, .optionAsAlt, .restoreSession])
        #expect(SettingsCategory.workspace.keys == [.projectRoots, .discoveryMaxDepth])
        #expect(SettingsCategory.behavior.keys == [.gitPollSeconds, .activityPollSeconds])
        #expect(SettingsCategory.notifications.keys == [.notificationsEnabled])
        #expect(SettingsCategory.advanced.keys == [.controlChannelEnabled, .controlAllowRead, .controlAllowRun])
    }

    @Test func everyCategoryHasATitleAndASymbol() {
        for category in SettingsCategory.allCases {
            #expect(!category.title.isEmpty)
            #expect(!category.symbolName.isEmpty)
        }
        #expect(Set(SettingsCategory.allCases.map(\.title)).count == SettingsCategory.allCases.count)
    }
}
