import AppKit
import BaiaSettings
import GhosttyTheme
import PaneChrome
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
    /// `allThemes` and not `search("")`. The catalog declares it inside a
    /// `public extension`, so the member is public even though the line itself
    /// does not say so, and it is reachable from here.
    ///
    /// `search("")` looks like the same thing and returns nothing. It filters on
    /// `name.lowercased().contains(lowered)`, and with Foundation imported that
    /// is the range-based overload, where `range(of: "")` is nil. So the empty
    /// query matches no name at all rather than every one. Measured against the
    /// running app: `allThemes` is 485, `search("")` is 0, `search("dark")` is 67.
    static let themeNames: [String] = GhosttyThemeCatalog.allThemes
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

    /// The chrome palette a draft would produce, which decides whether the Alert
    /// picker is worth showing.
    ///
    /// A closure through `ConfigurationCenter` rather than a derivation written
    /// here, for the reason that file already records: a second mapping inside the
    /// window is how a preview comes to show what the panes will not, and this one
    /// would decide what the owner is even offered.
    let chrome: (BaiaSettings.Settings) -> PaneTheme

    /// A section heading with its restore control.
    ///
    /// Per section rather than one button for the window, which is the shape the
    /// owner chose: judging a shipped default means putting one band back to stock
    /// without losing the other three. The draft is what moves, so Cancel still
    /// backs the restore out and Accept still commits it, and a restore is an edit
    /// like any other rather than a fifth way to write the file.
    ///
    /// Disabled when the section is already at the default, because a control that
    /// does nothing when pressed is the fault the command palette's hint row still
    /// carries. `title` comes off ``SettingsSection`` so the heading and the help
    /// string cannot drift from the section they restore.
    private func heading(_ section: SettingsSection) -> some View {
        HStack {
            Text(section.title)
            Spacer()
            Button {
                model.draft = model.draft.restoring(section)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.draft.isDefault(section))
            .help("Restore \(section.title) to its default")
            .accessibilityLabel("Restore \(section.title) to its default")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
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
                            // Stepped, like padding and size. Without it a drag
                            // writes the full Double into a file meant to be read
                            // and edited by hand, and the writer round-trips it
                            // faithfully: a real config came back carrying
                            // `"backgroundOpacity": 0.6008831521739131`.
                            Slider(value: $model.draft.backgroundOpacity, in: 0 ... 1, step: 0.01)
                            Text(model.draft.backgroundOpacity, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Toggle("Blur behind window", isOn: $model.draft.backgroundBlur)
                } header: {
                    heading(.theme)
                }

                Section {
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
                } header: {
                    heading(.text)
                }

                Section {
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
                } header: {
                    heading(.window)
                }

                Section {
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
                    // Shown only where it changes something. Under `accent` that
                    // is every theme, since the attention colour is the focus
                    // colour by construction and the three behaviours always
                    // differ. Under `alert` it is the themes whose own `ansi[1]`
                    // lands on their focus colour or their bar, which is 141 of
                    // the 485 in the catalog, the count `themeNames` above has
                    // always given and `Diagnostics/theme-catalog/` now checks.
                    // The remaining case is the shipped
                    // default, where all three answer the same thing and the
                    // picker would be a control that does nothing.
                    if chrome(model.draft).alertBehaviorMatters(for: model.draft.attentionAccent) {
                        Picker("Alert", selection: $model.draft.alertBehavior) {
                            ForEach(AlertBehavior.allCases, id: \.self) { value in
                                Text(value.rawValue.capitalized).tag(value)
                            }
                        }
                    }
                } header: {
                    heading(.signals)
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
