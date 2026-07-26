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
/// ``Settings/terminalOverrides`` stays as it is. It remains the value the
/// "reproduces the owner's ghostty config" test compares against, and it is the
/// single list a reader should look at to see what baia asks the terminal for.
public extension Settings {
    /// Everything the theme does not touch, applied through
    /// `TerminalController.setTerminalConfiguration`.
    var sessionOverrides: [TerminalOverride] {
        terminalOverrides.filter { !Self.themeOwnedKeys.contains($0.key) }
    }

    /// The keys that have to be applied on top of the resolved theme, folded into
    /// the `TerminalTheme` before it is handed to `setTheme`.
    ///
    /// One key today. The background is here because the owner's `#141414` is
    /// deliberately lifted off pure black, and every theme carries a background
    /// of its own that would otherwise replace it. The config comment records the
    /// reason: pure black amplifies wallpaper bleed through a translucent window,
    /// which widens the perceived gap between a focused and an unfocused window
    /// rather than narrowing it.
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
