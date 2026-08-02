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
    /// them.
    ///
    /// Called `midnight` until the name was measured against the value. A footer
    /// ink has to clear 4.5:1 on the bar, so the repair chain sets a floor under
    /// how dark this is allowed to be, and what it lands on is a lit blue-violet
    /// rather than anything anyone would call midnight. The old spelling still
    /// decodes, to this case and so to this colour: see ``named(_:)``.
    case twilight
}

public extension FocusAccent {
    /// The case a config file's spelling names, including spellings this type no
    /// longer uses.
    ///
    /// `SettingsDecoder` reads `focusAccent` through here rather than through
    /// `init(rawValue:)`, so a file written before a rename keeps applying instead
    /// of falling back to the default and reporting itself invalid.
    static func named(_ spelling: String) -> FocusAccent? {
        FocusAccent(rawValue: spelling) ?? retiredSpellings[spelling]
    }

    /// Spellings that were once a case's `rawValue` and still have to decode.
    ///
    /// Every entry has to name the case that resolves to **the colour the old
    /// spelling always resolved to**, and that is the whole rule rather than a
    /// detail. `midnight` meant the `ansi[4]`→`ansi[5]` blend, ``twilight`` is
    /// that same blend renamed, so an existing config renders identically and says
    /// nothing, which is correct. Pointing a retired spelling at a *different*
    /// derivation would be the failure this table cannot detect for itself: the
    /// value stays legal, ``SettingsDecoder`` only reports spellings it does not
    /// recognise, and the owner's chrome changes colour with nothing anywhere
    /// saying why.
    ///
    /// A new spelling never belongs here. Only a name that has already shipped.
    private static let retiredSpellings: [String: FocusAccent] = [
        "midnight": .twilight,
    ]
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

/// Which derivation the attention signal is drawn from.
///
/// This is ``AttentionStyle``'s question asked in hue rather than in volume, and
/// it sits beside that key for the same reason: how a waiting pane should look is
/// a preference, unlike the window's corner radius, which is a fact about the
/// window with nothing for anyone to prefer.
///
/// It moves the attention signal only. ``PaneTheme/alert`` is also the
/// conflicted-tree marker and the `!` glyph in the git segments, and neither
/// follows this: red still means conflict, and an attention colour that took the
/// conflict marker with it would leave a pane unable to say both things at once.
public enum AttentionAccent: String, Sendable, Equatable, CaseIterable {
    /// `ansiColor(1)`, what ships today. The default, so a config written before
    /// this key existed renders identically.
    ///
    /// Spelled `alert` rather than `red` deliberately. `PaneTheme.alert` is
    /// `ansi[1]`, so on a theme whose `ansi[1]` is orange or maroon the value
    /// `red` would be a promise the theme does not keep. The standing rule is that
    /// a config names a derivation and lets the theme decide what it resolves to,
    /// which is the same argument ``FocusAccent`` makes against a settable hex.
    case alert

    /// The resolved focus accent, the value ``FocusAccent`` selected.
    ///
    /// Under this value the attention colour and the focus colour are the same by
    /// construction, so ``AlertBehavior`` is what decides whether that matters.
    case accent
}

/// What happens when the attention colour cannot be told apart from something
/// else on the pane.
///
/// Deliberately not special-cased to ``AttentionAccent/accent``. A theme whose
/// `ansi[1]` equals its selection colour collides under ``AttentionAccent/alert``
/// too, and a rule that fires for only one value is a rule that will be wrong for
/// someone.
///
/// "Cannot be told apart" is measured rather than compared, and it covers two
/// things rather than one. The focus colour is the obvious one. The other is the
/// footer itself: the loud treatment is a wash across the bar and a frame around
/// the pane, and a wash the colour of the bar it washes leaves the pane asking
/// with nothing on screen to say so. 124 of the 463 shipped ghostty themes do
/// exactly that under `accent`, because a selection colour is usually the theme's
/// own background lifted a step and so is the bar. Both repair values measure
/// both.
public enum AlertBehavior: String, Sendable, Equatable, CaseIterable {
    /// Nothing. Whatever ``AttentionAccent`` names is used, collision and all.
    ///
    /// The default, and not only for the upgrade promise: shape already carries
    /// the distinction, since focus takes an edge and attention takes a fill, so
    /// two signals in one colour are still two signals.
    ///
    /// It means it. On the themes whose selection colour is their own bar, `accent`
    /// plus this value paints the footer in the colour the footer already was.
    /// That is the value doing what it says; the other two are what to set when it
    /// is not what you want.
    case stock

    /// Where attention would be indistinguishable from focus or from the bar,
    /// attention falls back to the theme's alert.
    ///
    /// Degenerate on a theme whose alert is *itself* the focus colour: the
    /// fallback names the colour that is already there. That is what the setting
    /// says rather than an oversight, "fall back to what shipped", and ``derive``
    /// is the value for that theme.
    case noCollision

    /// Where attention would be indistinguishable from focus or from the bar, it is
    /// blended away until it is visibly distinct while staying recognisably related.
    ///
    /// The blend, the directions it searches and the perceptual separation it is
    /// measured to clear are on `PaneTheme.attentionColour(_:behavior:)`.
    case derive
}
