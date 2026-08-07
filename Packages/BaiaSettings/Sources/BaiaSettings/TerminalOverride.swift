import Foundation

/// A key-value pair to hand to the terminal controller's config builder.
///
/// Kept here so the mapping from a baia setting to a ghostty config key lives
/// with the setting. A wrong key name is the worst bug this code can have:
/// ghostty drops a key it does not recognise without a diagnostic, so the
/// setting appears to work and does nothing, and the only way to notice is to
/// compare two screenshots.
public struct TerminalOverride: Sendable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public extension Settings {
    /// The ghostty config keys these settings imply, ready for
    /// `withCustom(key, value)`.
    ///
    /// An array rather than a dictionary, because the builder applies keys in the
    /// order it receives them and a stable order is what lets one test compare the
    /// whole list against the config file the owner already runs. A dictionary
    /// would also make that test flake on iteration order.
    var terminalOverrides: [TerminalOverride] {
        var overrides: [TerminalOverride] = [
            TerminalOverride(key: "theme", value: themeName),
            TerminalOverride(key: "background", value: backgroundHex),
            TerminalOverride(key: "background-opacity", value: Self.configText(backgroundOpacity)),
            TerminalOverride(key: "background-blur", value: Self.configText(backgroundBlur)),
            TerminalOverride(key: "font-size", value: Self.configText(fontSize)),
        ]

        // Omitted rather than sent empty when unset. ghostty reads an empty
        // `font-family` as a request for no font at all on some versions and as
        // its default on others, and neither is worth depending on.
        if let fontFamily, !fontFamily.isEmpty {
            overrides.append(TerminalOverride(key: "font-family", value: fontFamily))
        }

        // Rounded because `window-padding-x` and `window-padding-y` are integer
        // keys: ghostty rejects `8.6` for them and keeps its own default, which
        // presents as padding that silently did not apply.
        let padding = Self.configText(windowPadding.rounded())
        overrides.append(TerminalOverride(key: "window-padding-x", value: padding))
        overrides.append(TerminalOverride(key: "window-padding-y", value: padding))
        overrides.append(
            TerminalOverride(
                key: "window-padding-balance",
                value: Self.configText(windowPaddingBalance)
            )
        )

        // `macos-titlebar-style` is deliberately not emitted, and
        // ``Settings/transparentTitlebar`` deliberately still decodes. The key
        // only means something to a window ghostty created, and ghostty creates
        // no window here: baia owns the `NSWindow` and hands the engine a
        // surface to draw into, so this override was read by nothing for as long
        // as it was sent.
        //
        // The honest treatment is now the platform's. The workspace window
        // carries an `NSToolbar` (see
        // ``WorkspaceWindowController``), which is what supplies the titlebar
        // material on macOS 26; a titlebar the content shows through is the
        // thing that toolbar exists to fix, so there is no setting left to point
        // at. Mapping it to `titlebarAppearsTransparent` was the alternative and
        // it was measured to undo the fix exactly: with that flag set, the strip
        // goes back to reading the content behind it.
        //
        // The field stays for file compatibility. A config that sets
        // `transparentTitlebar` keeps decoding, keeps round-tripping through the
        // writer, and now simply changes nothing.
        overrides.append(
            TerminalOverride(key: "macos-option-as-alt", value: Self.configText(optionAsAlt))
        )
        overrides.append(TerminalOverride(key: "cursor-style", value: cursorStyle.rawValue))
        return overrides
    }

    /// Renders a number the way ghostty's config parser wants it, dropping the
    /// decimal point from a whole value so an integer key accepts it.
    ///
    /// `String(Int(value))` is the obvious spelling and it traps for a value
    /// outside `Int`'s range. Every field here is a public `var`, so the decoder's
    /// clamping is a fact about the file and not a guarantee at this point.
    private static func configText(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(value)
    }

    /// ghostty spells its booleans `true` and `false`. It also accepts `1` and
    /// `0`, which are not used here: the config file baia writes is meant to be
    /// read next to the owner's own ghostty config.
    private static func configText(_ flag: Bool) -> String {
        flag ? "true" : "false"
    }
}
