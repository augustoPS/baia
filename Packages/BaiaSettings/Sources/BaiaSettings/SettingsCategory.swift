import Foundation

/// One toolbar category of the Settings window, and the keys it edits.
///
/// Here rather than beside the window, under the standing rule: which fields a
/// category owns is answerable with no `NSWindow` and no descriptor, so it
/// belongs where there is a test bundle. The test pins that every active key
/// lands in exactly one category and that the inert compatibility key lands in
/// none, so a key added to ``SettingsKey`` fails a test until it has a home.
///
/// The order of ``allCases`` is the toolbar's order and the order of ``keys``
/// is the order a category draws its controls, both from the spec's table.
public enum SettingsCategory: String, CaseIterable, Sendable {
    case appearance
    case typography
    case window
    case workspace
    case behavior
    case notifications
    case advanced

    /// The toolbar label, and the only place this string lives.
    public var title: String {
        switch self {
        case .appearance: "Appearance"
        case .typography: "Typography"
        case .window: "Window"
        case .workspace: "Workspace"
        case .behavior: "Behavior"
        case .notifications: "Notifications"
        case .advanced: "Advanced"
        }
    }

    /// The SF Symbol the toolbar item shows.
    public var symbolName: String {
        switch self {
        case .appearance: "paintpalette"
        case .typography: "textformat"
        case .window: "macwindow"
        case .workspace: "folder"
        case .behavior: "clock.arrow.2.circlepath"
        case .notifications: "bell"
        case .advanced: "gearshape.2"
        }
    }

    public var keys: [SettingsKey] {
        switch self {
        case .appearance: [
                .themeName, .backgroundHex, .backgroundOpacity, .backgroundBlur, .chromeStyle,
                .sidebar, .focusAccent, .attentionStyle, .attentionAccent, .alertBehavior,
            ]
        case .typography: [.fontFamily, .fontSize, .cursorStyle]
        case .window: [.windowPadding, .windowPaddingBalance, .optionAsAlt, .restoreSession]
        case .workspace: [.projectRoots, .discoveryMaxDepth]
        case .behavior: [.gitPollSeconds, .activityPollSeconds]
        case .notifications: [.notificationsEnabled]
        case .advanced: [.controlChannelEnabled, .controlAllowRead, .controlAllowRun]
        }
    }

    /// The category that edits `key`, or nil for a key no category shows.
    public static func containing(_ key: SettingsKey) -> SettingsCategory? {
        allCases.first { $0.keys.contains(key) }
    }
}
