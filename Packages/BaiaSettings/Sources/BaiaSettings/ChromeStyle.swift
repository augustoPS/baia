import Foundation

/// Whether the chrome renders flat or asks for the v5 glass materials.
///
/// **Flat is the spec.** It is what Plan 1 shipped, and every frame `chromeStyle:
/// "flat"` draws must stay byte-identical to that, which is also why it is the
/// default: installing a release that reads this key must not move a pixel for a
/// config file that predates it. `glass` is additive and reversible per frame, and
/// Reduce Transparency forces flat regardless of what this says.
///
/// Never reaches ghostty, so a rename here costs nothing outside baia's own config
/// file: unlike ``CursorStyle``, nothing downstream can reject a spelling this type
/// stops using.
public enum ChromeStyle: String, Sendable, Equatable, CaseIterable {
    /// The shipped rendering: solid fills, the drawn hairline and capsule, no
    /// backing material anywhere in the chrome.
    case flat

    /// The v5 material lift: translucent backing views under the footer and
    /// sidebar, the focus lift's ring and shadow. Resolved against Reduce
    /// Transparency and the system appearance by `PaneChrome`'s
    /// `resolvedStyle(setting:materialIsDark:appearance:)`, not read directly by anything that
    /// draws state ink.
    case glass
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
    /// them.
    ///
    /// Called `midnight` until the name was measured against the value. A footer
    /// ink has to clear 4.5:1 on the bar, so the repair chain sets a floor under
    /// how dark this is allowed to be, and what it lands on is a lit blue-violet
    /// rather than anything anyone would call midnight. The old spelling still
    /// decodes, to this case and so to this colour: see ``named(_:)``.
    case twilight

    /// `ansi[5]` blended halfway into the terminal's own background: magenta
    /// smoked down into the theme it sits in, `#8a358a` on Dark Pastel before
    /// repair.
    ///
    /// **The darkest of the seven, and the only one repaired on every theme in
    /// the catalog.** Its raw value clears 4.5:1 on the bar for none of the 485,
    /// against 204 for ``twilight``, 252 for ``sea`` and 421 for ``bone``. So it
    /// is dark where it is composed and never dark where it is drawn: on Dark
    /// Pastel the derivation is `#8a358a` at 2.24:1 and the ink is `#b37bb3` at
    /// 4.89:1. That is said here rather than left for the name to imply, which is
    /// the whole reason ``twilight`` is not called midnight.
    ///
    /// What it buys over raw ``ansi5`` is therefore the background in the blend
    /// rather than the darkness. It is the only derivation composed with a colour
    /// the theme owns outright, so it carries that theme's own cast instead of
    /// the palette's magenta unchanged.
    case nightshade

    /// `ansi[6]` blended halfway to `ansi[4]`: cyan towards info blue, `#55aaff`
    /// on Dark Pastel.
    ///
    /// ``twilight``'s construction on the other side of blue, offered for the same
    /// argument: it borrows two slots rather than spending one, and four brights
    /// already carry meaning as alert, warn, info and ok, so a mixture cannot be
    /// misread as one of them.
    ///
    /// Halfway rather than nearer the cyan, and the catalog says the cost. At 0.35
    /// it costs four fewer degenerate rows; it also lands close enough to raw
    /// ``ansi6`` to be a second spelling of a case that already exists. Half is
    /// what makes it its own colour.
    case sea
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
/// Both volumes draw the footer's attention capsule (design v5 §3): tinted
/// while asking, clear once acknowledged, a bare ✓ when done. This chooses
/// only whether the ask also leaves the footer, because how much interruption
/// is right depends on whether the owner is watching the panes or working in
/// one.
///
/// Neither spelling ever reaches ghostty, nor does ``FocusAccent``'s, so both
/// are baia's own. Renaming a case changes the config file baia reads and
/// nothing else, which is also why nothing outside baia can reject a rename.
public enum AttentionStyle: String, Sendable, Equatable, CaseIterable {
    /// The capsule, plus a 2 pt alert frame around the whole pane while the
    /// ask is unacknowledged. The frame is the cross-window carrier: findable
    /// across four panes without reading a single footer.
    case loud

    /// The capsule alone. The pane says it is asking; nothing outside the
    /// footer moves.
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
/// with nothing on screen to say so. 141 of the 485 shipped ghostty themes do
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
