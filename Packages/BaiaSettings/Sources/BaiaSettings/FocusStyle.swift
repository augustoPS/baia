import Foundation

/// How a focused pane is told apart from the others.
///
/// Four treatments rather than one, because the right answer depends on how
/// many panes are open and on how much unfocused output the owner is reading.
/// The default is ``barFrame``, which encloses the focused pane's footer and
/// leaves every other pane untouched: enclosure is the fastest shape the visual
/// system resolves, and a rectangle 22 pt tall is small enough to be taken as
/// one object rather than scanned for as a line.
///
/// Unlike ``CursorStyle``, none of these spellings is ever sent to ghostty, so
/// they are baia's own. Renaming a case changes the config file baia reads and
/// nothing else.
public enum FocusStyle: String, Sendable, Equatable, CaseIterable {
    /// Every pane except the focused one is covered by a scrim of
    /// ``Settings/unfocusedScrim``. Nothing at all is added to the focused pane.
    ///
    /// Peripheral vision registers area rather than lines, so a treatment made of
    /// area grows more legible as panes are added. The cost is that it taxes
    /// exactly the panes the owner reads without typing in, which is why it lost
    /// the default to ``barFrame`` and why it stays reachable to be compared
    /// against it.
    case recede

    /// The focused pane's footer is filled with the focus colour and its text is
    /// drawn in the terminal background. The most findable of the four and the
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

    /// A 2 pt inset stroke around the *footer bar*, in the focus ink, with the
    /// bar's fill identical in both states. The default.
    ///
    /// Where ``frame`` strokes the whole pane and lands beside the split
    /// dividers, this one closes a rectangle small enough that the eye takes it
    /// as a single object rather than scanning for a line. It draws nothing over
    /// the terminal surface and asks no hit-testing question, because it is
    /// inside a view that already refuses first responder and returns nil from
    /// `hitTest`.
    ///
    /// The frame is drawn in whatever ink the anchor name is drawn in, so focus
    /// reads as one signal rather than two. That is a rule the frame follows
    /// into a filled bar and not a colour it holds fixed: on an asking pane both
    /// become the near-black the contrast repair picks for red, because the
    /// focus accent scores 2.08:1 there and would be a frame nobody can see.
    ///
    /// Against ``AttentionStyle/loud``, the default, the two compose by
    /// construction across three objects: focus takes the bar's edges, attention
    /// takes the bar's fill, and attention also takes a 2 pt stroke around the
    /// whole pane, which focus under this style never touches. So a pane can be
    /// both at once and still be read correctly, which is the state the owner is
    /// in every time he answers an agent. That is why
    /// ``Settings/resolvedAttentionStyle`` needs no rule for this case the way it
    /// does for ``invert``.
    ///
    /// Against ``AttentionStyle/quiet`` both want the same two points of the top
    /// edge, and the frame is drawn above the text, so the attention line is
    /// pushed inside it instead: 2 pt of alert immediately within 2 pt of focus,
    /// both readable. It has to be moved rather than left to be covered, because
    /// `quiet` is a static line with no arrival pulse behind it, so a covered
    /// line is an ask that is never announced at all.
    ///
    /// The frame is hidden while the window is not key, matching ``frame``. The
    /// anchor name stays in the focus ink there, also matching ``frame``.
    case barFrame
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
