import Foundation

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
///
/// Neither spelling ever reaches ghostty, nor does ``FocusAccent``'s, so both
/// are baia's own. Renaming a case changes the config file baia reads and
/// nothing else, which is also why nothing outside baia can reject a rename.
public enum AttentionStyle: String, Sendable, Equatable, CaseIterable {
    /// The footer fills with the alert colour and a 2 pt alert frame is drawn
    /// around the whole pane.
    case loud

    /// A 2 pt alert line along the footer's top edge, and nothing else.
    ///
    /// The footer keeps its own background, which is what lets this be read
    /// beside the focus frame. Both want the same two points of the top edge and
    /// the frame is drawn above the text, so the line is pushed *inside* the
    /// frame instead of being left under it: 2 pt of alert immediately within
    /// 2 pt of focus, both readable. It has to be moved rather than covered,
    /// because this level has no arrival pulse behind it, so a covered line is
    /// an ask that is never announced at all.
    case quiet
}
