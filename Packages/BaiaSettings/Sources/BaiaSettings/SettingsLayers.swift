import Foundation

/// The two config layers a `Settings` becomes, kept apart because ghostty
/// resolves them in a fixed order.
///
/// `TerminalController` renders base, then the per-session configuration, then
/// the theme, joined in that order, and ghostty takes the *last* value it reads
/// for a scalar key. So the theme layer overrides the session layer, and which
/// layer a key goes in decides whether it survives at all. A key in the wrong
/// layer is not a style question: it is dropped in silence, and the only way to
/// notice is to compare two screenshots.
///
/// ``Settings/terminalOverrides`` remains the complete ordered list of settings
/// overrides. Palette data is supplied by the resolved terminal theme.
public extension Settings {
    /// Everything the theme does not touch, applied through
    /// `TerminalController.setTerminalConfiguration`.
    var sessionOverrides: [TerminalOverride] {
        terminalOverrides.filter { !Self.themeOwnedKeys.contains($0.key) }
    }

    /// The keys that have to be applied on top of the resolved theme, folded into
    /// the `TerminalTheme` before it is handed to `setTheme`.
    ///
    /// The configured background is applied last so an explicit background edit
    /// survives theme resolution. Selecting a built-in theme through Settings
    /// writes its own background as part of that transaction.
    var themeOverrides: [TerminalOverride] {
        terminalOverrides.filter { $0.key == "background" }
    }

    /// Keys the theme layer owns, plus the one key that is dropped entirely.
    ///
    /// `theme` is not sent to ghostty at all. The bundled libghostty is a trimmed
    /// build that ships no theme files, which is why the package carries a
    /// 485-theme Swift catalog instead, so `theme = Dark Pastel` would be parsed,
    /// unresolvable, and dropped without a diagnostic. Themes are looked up in
    /// that catalog and applied as a `TerminalTheme`.
    private static let themeOwnedKeys: Set<String> = ["background", "theme"]
}
