import BaiaSettings
import Foundation

public extension PaneTheme {
    /// Builds a chrome palette from a terminal theme's own colours, as hex
    /// strings.
    ///
    /// Hex strings rather than a theme type, because `PaneChrome` imports neither
    /// AppKit nor libghostty and the theme catalog lives inside the latter. The
    /// app looks a theme up by name and hands the strings across, which keeps the
    /// terminal and its chrome derived from one lookup instead of two sources
    /// that can disagree. The standing rule is that chrome matches the theme, so
    /// a theme change that moved the surface and left the footer behind would be
    /// the failure this initializer exists to prevent.
    ///
    /// Every argument is tolerated rather than trusted. The catalog spells its
    /// palette without a leading `#` while `background` and `foreground` carry
    /// one, several hundred of its themes declare no selection colour, and a
    /// hand-edited config file can name anything at all.
    ///
    /// `focusAccent` is a parameter rather than something the app applies
    /// afterwards, so there is no assignment for a caller to forget. Forgetting
    /// it is not hypothetical: the key was decoded, stored and tested for a week
    /// while this initializer resolved the accent from the selection colour and
    /// nothing ever read the setting.
    init(
        background: String,
        foreground: String,
        selectionBackground: String?,
        palette: [Int: String],
        focusAccent: FocusAccent = .accent
    ) {
        // A rejected hex falls back to the known-good default rather than to
        // black or to zero. Black is a legitimate background, so a failed parse
        // that produced it would look like a deliberate choice and leave nothing
        // to notice.
        let backgroundRGB = RGB(hex: background) ?? PaneTheme.darkPastel.background
        let foregroundRGB = RGB(hex: foreground) ?? PaneTheme.darkPastel.foreground

        // Sixteen slots always, holes filled with the foreground. `ansi` tolerates
        // a short array by falling back per read, but filling here means the
        // fallback is decided once, in daylight, rather than inside a draw call.
        let ansi = (0 ..< 16).map { index in
            palette[index].flatMap(RGB.init(hex:)) ?? foregroundRGB
        }

        self.init(
            background: backgroundRGB,
            foreground: foregroundRGB,
            focusedAccent: Self.accent(
                declared: selectionBackground,
                ansi: ansi,
                foreground: foregroundRGB
            ),
            ansi: ansi
        )
        // After delegation rather than in the argument above, because the
        // derivations are expressed in terms of the palette this initializer is
        // what builds: `bone` needs `ansi[15]` and `midnight` needs `ansi[4]`
        // and `ansi[5]`, none of which exist until the holes are filled.
        focusedAccent = accent(for: focusAccent)
    }

    /// The focus colour, from the theme's selection colour where it has one.
    ///
    /// Most catalog themes do not, so the derivation is the ordinary path. Blue
    /// blended halfway towards the foreground, which is what Dark Pastel's own
    /// pale blue is next to its `ansi[4]`, and which keeps the accent a named
    /// derivation of the theme rather than a colour baia picked. `FocusAccent`
    /// documents why a settable hex is not offered: it would survive a theme
    /// switch that moved everything around it.
    private static func accent(declared: String?, ansi: [RGB], foreground: RGB) -> RGB {
        if let declared, let parsed = RGB(hex: declared) { return parsed }
        guard ansi.indices.contains(4) else { return foreground }
        return ansi[4].blended(with: foreground, fraction: 0.5)
    }
}
