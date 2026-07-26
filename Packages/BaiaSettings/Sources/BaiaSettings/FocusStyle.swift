import Foundation

/// How a focused pane is told apart from the others.
///
/// Three treatments rather than one, because the right answer depends on how
/// many panes are open and on how much unfocused output the owner is reading.
/// The default is ``recede``, which draws nothing on the focused pane and dims
/// every other one instead: peripheral vision registers area rather than lines,
/// so a treatment made of area grows more legible as panes are added, where the
/// accent stripe it replaces grew less.
///
/// Unlike ``CursorStyle``, none of these spellings is ever sent to ghostty, so
/// they are baia's own. Renaming a case changes the config file baia reads and
/// nothing else.
public enum FocusStyle: String, Sendable, Equatable, CaseIterable {
    /// Every pane except the focused one is covered by a scrim of
    /// ``Settings/unfocusedScrim``. Nothing at all is added to the focused pane,
    /// which is what keeps the footer's height out of the question: there is no
    /// focused branch left in the bar for a later edit to make taller.
    case recede

    /// The focused pane's footer is filled with the focus colour and its text is
    /// drawn in the terminal background. The most findable of the three and the
    /// brightest object on screen at all times. It also fills the bar, which is
    /// how an asking pane marks itself, so ``Settings/resolvedAttentionStyle``
    /// quietens attention whenever this is chosen.
    case invert

    /// A 2 pt inset stroke around the focused pane, drawn in an overlay above
    /// the surface. Enclosure is the fastest shape to resolve and it is the
    /// product's own metaphor, but the stroke sits beside the split dividers, so
    /// at four panes it can read as one divider being a different colour before
    /// it reads as a box.
    case frame
}

/// Which derivation the focus colour is resolved from.
///
/// A name, never a hex. A user-settable colour would break the standing rule
/// that chrome follows the terminal theme and never the reverse: a hex would
/// survive a theme switch that moved everything around it, and every contrast
/// figure in `PaneTheme.readable(_:on:minimumRatio:)` is measured against a bar
/// whose colour the theme decides. Naming a derivation leaves the theme in
/// charge of what it resolves to and the repair chain with the last word.
public enum FocusAccent: String, Sendable, Equatable, CaseIterable {
    /// The theme's own `focusedAccent`, which for the owner's Dark Pastel is the
    /// selection blue his statusline already uses for the directory. The
    /// default, so a config written before this key existed renders identically.
    case accent

    /// `foreground` blended towards the brightest ANSI slot. The design pass
    /// recommends it: alert, warn, info and ok have already claimed four bright
    /// hues, and focus is a location rather than a state, so it reads more
    /// clearly as the absence of hue than as a fifth one.
    case bone

    /// Raw `ansi[5]`, magenta on most palettes.
    case ansi5

    /// Raw `ansi[6]`, cyan on most palettes.
    case ansi6

    /// `ansi[4]` blended halfway to `ansi[5]`: info blue towards magenta, which
    /// on Dark Pastel is `#aa55ff` before repair.
    ///
    /// It borrows two slots rather than spending one, which is the argument for
    /// it over raw `ansi5` or `ansi6`: four brights already carry meaning as
    /// alert, warn, info and ok, and a mixture can never be misread as one of
    /// them. Midnight names the hue, not the value. A footer ink has to clear
    /// 4.5:1 on the bar, so the repair chain decides how dark it is allowed to
    /// be and it lands lighter than the name suggests.
    case midnight
}

/// How hard an unacknowledged pane asks.
///
/// Both levels of the attention model exist either way. This chooses only what
/// the unacknowledged level looks like, because how much interruption is right
/// depends on whether the owner is watching the panes or working in one.
public enum AttentionStyle: String, Sendable, Equatable, CaseIterable {
    /// The footer fills with the alert colour and a 2 pt alert frame is drawn
    /// around the whole pane.
    case loud

    /// A 2 pt alert line along the footer's top edge, and nothing else. The
    /// footer keeps its own background, which is what lets this coexist with
    /// ``FocusStyle/invert``.
    case quiet
}
