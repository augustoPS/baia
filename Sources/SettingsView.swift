import AppKit
import BaiaSettings
import GhosttyTheme
import SwiftUI

/// The settings window's own copy of the settings.
///
/// The real panes stay on the committed values until accept, so this is the only
/// thing an edit moves. `committed` is kept beside `draft` because the left-hand
/// sample renders from it: the comparison is the point of the window.
@MainActor
@Observable
final class SettingsDraft {
    let committed: BaiaSettings.Settings
    var draft: BaiaSettings.Settings

    /// True when there is something to accept.
    var isDirty: Bool { draft != committed }

    init(committed: BaiaSettings.Settings) {
        self.committed = committed
        draft = committed
    }

    /// Every theme name the catalog can resolve, for the theme picker.
    ///
    /// From `GhosttyThemeCatalog` rather than a list written here, because
    /// `ConfigurationCenter` resolves through the catalog and a name this window
    /// offered but the catalog could not resolve would fall back to the default
    /// while looking applied.
    ///
    /// `search("")` and not `allThemes`, which is declared without `public` in
    /// the generated catalog and is unreachable from here. The empty query
    /// matches everything, because `search` filters on
    /// `name.lowercased().contains(query.lowercased())` and every string contains
    /// the empty string.
    static let themeNames: [String] = GhosttyThemeCatalog.search("")
        .map(\.name)
        .sorted()
}

/// The appearance form.
///
/// Deliberately plain. The glass treatment is a separate pass against this window
/// once there is something to look at, and a visual choice made here would be a
/// choice made before the comparison it is supposed to come from.
struct SettingsView: View {
    @Bindable var model: SettingsDraft
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $model.draft.themeName) {
                        ForEach(SettingsDraft.themeNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    TextField("Background", text: $model.draft.backgroundHex)
                    // Opacity and blur are shown and cannot be judged here. Both
                    // act on the window against the desktop, and the sample has
                    // the settings window behind it, so both will flatter.
                    LabeledContent("Opacity") {
                        HStack {
                            Slider(value: $model.draft.backgroundOpacity, in: 0 ... 1)
                            Text(model.draft.backgroundOpacity, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Toggle("Blur behind window", isOn: $model.draft.backgroundBlur)
                }

                Section("Text") {
                    TextField(
                        "Font",
                        text: Binding(
                            get: { model.draft.fontFamily ?? "" },
                            // Empty means unset, which the decoder reads from
                            // null. Writing "" would name a font nobody has.
                            set: { model.draft.fontFamily = $0.isEmpty ? nil : $0 }
                        ),
                        prompt: Text("System default")
                    )
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: $model.draft.fontSize, in: 8 ... 24, step: 0.5)
                            Text(model.draft.fontSize, format: .number.precision(.fractionLength(1)))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Picker("Cursor", selection: $model.draft.cursorStyle) {
                        ForEach(CursorStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                }

                Section("Window") {
                    LabeledContent("Padding") {
                        HStack {
                            Slider(value: $model.draft.windowPadding, in: 0 ... 32, step: 1)
                            Text(model.draft.windowPadding, format: .number.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Toggle("Balance padding", isOn: $model.draft.windowPaddingBalance)
                    Toggle("Transparent titlebar", isOn: $model.draft.transparentTitlebar)
                }

                Section("Signals") {
                    Picker("Focus accent", selection: $model.draft.focusAccent) {
                        ForEach(FocusAccent.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    Picker("Attention style", selection: $model.draft.attentionStyle) {
                        ForEach(AttentionStyle.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    Picker("Attention accent", selection: $model.draft.attentionAccent) {
                        ForEach(AttentionAccent.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    Picker("Alert", selection: $model.draft.alertBehavior) {
                        ForEach(AlertBehavior.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Accept", action: onAccept)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isDirty)
            }
            .padding(12)
        }
        .frame(minWidth: 400, minHeight: 520)
    }
}
