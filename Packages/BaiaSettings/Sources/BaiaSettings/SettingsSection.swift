import Foundation

/// One band of the settings window, and the fields it owns.
///
/// **Here rather than beside the view, under the standing rule.** Which fields a
/// section covers and what restoring one means is answerable with no `NSWindow`
/// and no descriptor, so it belongs where there is a test bundle. Five rules have
/// already been found living in the app target where nothing could exercise them,
/// and three of the five were wrong when they moved.
///
/// The order of ``allCases`` and of ``fields`` is the order the window draws, so
/// the pinned inventory in the tests reads down the form.
public enum SettingsSection: String, CaseIterable, Sendable {
    case theme
    case text
    case window
    case signals

    /// The heading the window draws, and the only place this string lives.
    public var title: String {
        switch self {
        case .theme: "Theme"
        case .text: "Text"
        case .window: "Window"
        case .signals: "Signals"
        }
    }

    public var fields: [SettingsField] {
        switch self {
        case .theme: [
                .init(\.themeName, "themeName"),
                .init(\.backgroundHex, "backgroundHex"),
                .init(\.backgroundOpacity, "backgroundOpacity"),
                .init(\.backgroundBlur, "backgroundBlur"),
            ]
        case .text: [
                .init(\.fontFamily, "fontFamily"),
                .init(\.fontSize, "fontSize"),
                .init(\.cursorStyle, "cursorStyle"),
            ]
        case .window: [
                .init(\.windowPadding, "windowPadding"),
                .init(\.windowPaddingBalance, "windowPaddingBalance"),
                .init(\.transparentTitlebar, "transparentTitlebar"),
            ]
        case .signals: [
                .init(\.focusAccent, "focusAccent"),
                .init(\.attentionStyle, "attentionStyle"),
                .init(\.attentionAccent, "attentionAccent"),
                .init(\.alertBehavior, "alertBehavior"),
            ]
        }
    }
}

/// One editable field, erased to what a restore needs of it: copy it between two
/// values, and say whether two values agree about it.
///
/// A struct holding closures rather than a generic over the field's type, because
/// a section's fields are `String`, `Double`, `Bool` and four different enums, and
/// they have to sit in one array. The key path is captured once at construction
/// and neither closure can be written to disagree with it.
///
/// The name is carried for the tests and for a failure message that says which
/// field was missed. Passed in rather than derived, since a `KeyPath` has no
/// portable name at runtime.
public struct SettingsField {
    public let name: String
    private let copy: (inout Settings, Settings) -> Void
    private let same: (Settings, Settings) -> Bool

    init<Value: Equatable>(
        _ keyPath: WritableKeyPath<Settings, Value>,
        _ name: String
    ) {
        self.name = name
        copy = { target, source in target[keyPath: keyPath] = source[keyPath: keyPath] }
        same = { one, other in one[keyPath: keyPath] == other[keyPath: keyPath] }
    }

    /// Whether two settings agree about this one field.
    public func equals(_ one: Settings, _ other: Settings) -> Bool {
        same(one, other)
    }

    /// Takes this field's value from `source`.
    public func take(into target: inout Settings, from source: Settings) {
        copy(&target, source)
    }
}

public extension Settings {
    /// A copy with one section's fields back at the shipped default, and
    /// everything else untouched.
    ///
    /// Field by field rather than section by section, so a key the window cannot
    /// edit is never rewritten by a control that never showed it. `projectRoots`,
    /// the poll intervals, the sidebar and the three control-channel keys live in
    /// the file alone and stay exactly as the file left them.
    func restoring(_ section: SettingsSection) -> Settings {
        var restored = self
        for field in section.fields {
            field.take(into: &restored, from: Settings.defaultSettings)
        }
        return restored
    }

    /// Whether a section is already at the shipped default, which is what greys
    /// its control out. A button offering an action that does nothing is the fault
    /// the command palette's hint row still has.
    func isDefault(_ section: SettingsSection) -> Bool {
        section.fields.allSatisfy { $0.equals(self, Settings.defaultSettings) }
    }
}
