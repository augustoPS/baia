import BaiaSettings
import Foundation

/// The colours a pane's chrome is drawn from, derived from the terminal's own
/// palette.
///
/// Every colour the bar shows is computed from ``background``, ``foreground``,
/// ``focusedAccent`` and ``ansi`` rather than declared. The standing rule in this
/// workspace is to match chrome to the theme and never the reverse, so a theme
/// change has to move the bar with it. Nothing here reads the system appearance:
/// ghostty's colour scheme is per-controller and can disagree with macOS, and
/// chrome that follows macOS while the surface follows ghostty is the mismatch
/// this type exists to prevent.
public struct PaneTheme: Sendable, Equatable {
    public var background: RGB
    public var foreground: RGB
    public var focusedAccent: RGB

    /// The 16 ANSI colours, normal then bright. A shorter array is tolerated: a
    /// theme parsed out of a config file that only declares a handful falls back
    /// to ``foreground`` for the rest, since the alternative is trapping on an
    /// index inside a draw call.
    public var ansi: [RGB]

    public init(background: RGB, foreground: RGB, focusedAccent: RGB, ansi: [RGB]) {
        self.background = background
        self.foreground = foreground
        self.focusedAccent = focusedAccent
        self.ansi = ansi
    }

    /// The owner's terminal, reproduced: `theme Dark Pastel` with
    /// `background #141414` from `vault/projects/ghostty/config.ghostty`, so baia
    /// looks like his ghostty on first launch rather than like a new app.
    ///
    /// The background is lifted off pure black deliberately, and the accent is
    /// the selection blue his statusline already uses for the directory, so the
    /// focused pane and his prompt agree on which colour means "here".
    public static let darkPastel = PaneTheme(
        background: .eightBit(0x14, 0x14, 0x14),
        foreground: .eightBit(0xBB, 0xBB, 0xBB),
        focusedAccent: .eightBit(0xB5, 0xD5, 0xFF),
        ansi: [
            .eightBit(0x00, 0x00, 0x00),
            .eightBit(0xFF, 0x55, 0x55),
            .eightBit(0x55, 0xFF, 0x55),
            .eightBit(0xFF, 0xFF, 0x55),
            .eightBit(0x55, 0x55, 0xFF),
            .eightBit(0xFF, 0x55, 0xFF),
            .eightBit(0x55, 0xFF, 0xFF),
            .eightBit(0xBB, 0xBB, 0xBB),
            .eightBit(0x55, 0x55, 0x55),
            .eightBit(0xFF, 0x55, 0x55),
            .eightBit(0x55, 0xFF, 0x55),
            .eightBit(0xFF, 0xFF, 0x55),
            .eightBit(0x55, 0x55, 0xFF),
            .eightBit(0xFF, 0x55, 0xFF),
            .eightBit(0x55, 0xFF, 0xFF),
            .eightBit(0xFF, 0xFF, 0xFF),
        ]
    )

    /// WCAG AA for body text. The bar's text is small, so the 3:1 allowed for
    /// large text is not enough, and this is the floor every colour
    /// ``color(for:focused:)`` returns has already cleared.
    public static let minimumTextContrast: Double = 4.5

    /// Lifted off the terminal background so the bar reads as chrome rather than
    /// as the last line of output, which is what a pane running a build log looks
    /// like when the two match exactly.
    public var barBackground: RGB {
        background.blended(with: foreground, fraction: Self.barLift)
    }

    /// The line between two panes.
    ///
    /// Two steps below ``hairline`` on purpose, so the plank *between* stalls
    /// never outranks the plank *under* one. It is also why the split view must
    /// not use AppKit's `.thin` divider style: that separator follows the system
    /// appearance, which is the one thing this whole type exists to avoid.
    ///
    /// **Blended towards the accent rather than the foreground.** Design v3 §1:
    /// the lines carry the accent and the surfaces stay neutral, so the planks are
    /// tinted and the compartments they divide are not. The rule that document
    /// states is that the line changes hue and never weight, which is what
    /// ``tinted(matching:)`` holds to.
    public var divider: RGB {
        tinted(matching: 0.12)
    }

    /// The line between the terminal and its own footer.
    ///
    /// Tinted like ``divider`` and for the same reason, holding the weight of the
    /// 0.18 towards the foreground it replaces.
    public var hairline: RGB {
        tinted(matching: 0.18)
    }

    /// The accent blended into the background as far as it takes to match the
    /// luminance of `fraction` towards the foreground, and no further.
    ///
    /// **The fraction is solved rather than written down, and that is a
    /// correction to the design pass.** v3 §1 quotes 0.14 and 0.20 as the
    /// fractions that hold the weight of the neutrals they replace. They do, for
    /// `focusAccent: "midnight"`, which is what that document was written
    /// against. Under the default accent the same fractions land 31 percent
    /// brighter, and under `bone` 42 percent, because how far a fixed fraction
    /// carries depends entirely on how light the accent is. A line that gains a
    /// third of its weight when the accent changes is the thing the rule forbids.
    ///
    /// Solving also delivers the document's other claim about these two, that a
    /// hueless accent resolves them back to greys. `bone` at a fixed 0.14 is a
    /// *brighter* grey than the neutral; solved, it is the neutral.
    ///
    /// Bisection rather than algebra: relative luminance is piecewise over the
    /// sRGB transfer function, and 24 halvings settle it well inside a step of
    /// eight-bit colour.
    private func tinted(matching fraction: Double) -> RGB {
        let neutral = background.blended(with: foreground, fraction: fraction)
        let target = neutral.relativeLuminance
        let tint = inkFocus
        // An accent too dark to reach the neutral's weight cannot be dimmed into
        // it, so it goes as far as it can rather than overshooting the hue.
        guard tint.relativeLuminance > target else { return tint }

        var low = 0.0
        var high = 1.0
        for _ in 0 ..< 24 {
            let middle = (low + high) / 2
            if background.blended(with: tint, fraction: middle).relativeLuminance < target {
                low = middle
            } else {
                high = middle
            }
        }
        return background.blended(with: tint, fraction: (low + high) / 2)
    }

    /// The planks: the icon's dividers, and the PIN chip's border on an ordinary
    /// bar.
    ///
    /// One derivation rather than two computed at their sites, because the two
    /// are the same object at two scales and the icon is drawn by a standalone
    /// script that cannot import this package. The script hardcodes the Dark
    /// Pastel resolution of this formula, and `plankIsOneDerivationDoingTwoJobs`
    /// is what keeps the two in step.
    ///
    /// Not used for the chip on a *filled* bar. That stroke is judged against
    /// whatever the bar actually is, because a flat derivation off the theme
    /// scored 1.85:1 over ``alert`` on exactly the pane that most wanted reading.
    public var plank: RGB {
        foreground.blended(with: background, fraction: 0.46)
    }

    /// An alternative focus colour: the foreground pushed towards the brightest
    /// ANSI slot.
    ///
    /// Offered because the four bright hues are already spoken for by ``alert``,
    /// ``warn``, ``info`` and ``ok``. Focus is a location rather than a state, so
    /// there is an argument that it should read as the absence of hue instead of
    /// competing with four that carry meaning. Not the default: switching to it
    /// is a visible change, and it belongs to whoever is looking at the app.
    public var boneAccent: RGB {
        foreground.blended(with: ansiColor(15), fraction: 0.55)
    }

    /// `ansi[4]` blended halfway to `ansi[5]`. See ``BaiaSettings/FocusAccent/midnight``.
    public var midnightAccent: RGB {
        ansiColor(4).blended(with: ansiColor(5), fraction: 0.5)
    }

    /// The raw derivation a `focusAccent` choice names, before repair.
    ///
    /// A name rather than a hex, and this is where that promise is kept: the
    /// theme decides what each name resolves to, so switching ghostty themes
    /// moves the accent with everything around it. A settable hex would survive
    /// the switch and void every contrast figure measured against a bar whose
    /// colour the theme owns.
    public func accent(for choice: FocusAccent) -> RGB {
        switch choice {
        case .accent: focusedAccent
        case .bone: boneAccent
        case .ansi5: ansiColor(5)
        case .ansi6: ansiColor(6)
        case .midnight: midnightAccent
        }
    }

    /// The colour the attention signal is drawn in: the wash under an asking
    /// footer, the quiet line along its top edge, the acknowledged square, and the
    /// frame around the whole pane.
    ///
    /// Not the git segments. ``alert`` is also the conflicted-tree marker and the
    /// `!` glyph, and those stay red however this resolves, so a pane can say
    /// "an agent is waiting" and "this tree is conflicted" at the same time.
    ///
    /// The collision guard is a measurement, not a test on `accent`. Under
    /// ``BaiaSettings/AttentionAccent/accent`` the two are the same colour by
    /// construction, but a theme whose `ansi[1]` *is* its selection colour collides
    /// under ``BaiaSettings/AttentionAccent/alert`` as well, and a rule written
    /// against the enum case would leave that theme with a fill and a frame in one
    /// colour and no setting able to part them.
    ///
    /// A measurement rather than equality, for the reason ``derived(from:)`` is
    /// measured: two colours one 8-bit step apart are unequal and
    /// indistinguishable, so inequality proves nothing in either direction. An
    /// equality guard never fired on 16 of the 2315 theme-by-`focusAccent` rows the
    /// catalog produces, two of them on the default `focusAccent`, and Glacier is
    /// the clearest: its `alert` `#bd0f2f` and its accent `#bd2523` are unequal,
    /// measure ΔE00 5.44 apart, and under the old guard `derive` handed the
    /// colliding colour straight back unchanged. The predicate that decides whether
    /// to repair and the repair that follows it now use one definition of "the same
    /// colour" rather than two that disagree by a factor of infinity.
    ///
    /// The fill is returned raw. A fill owes no contrast to itself; the ink drawn
    /// on it owes 4.5:1, and ``ink(on:)`` and ``mutedInk(on:)`` are what guarantee
    /// that, for whatever this hands back.
    ///
    /// ``BaiaSettings/AlertBehavior/stock`` is unguarded on purpose, because the
    /// shipped answer to the collision question is "nothing" and shape carries the
    /// distinction. It follows that `accent`/`stock` can resolve to a colour that
    /// *is* the bar it fills: a selection colour is very often the theme's own
    /// background lifted a step, which is exactly what ``barBackground`` is, and
    /// 124 of the 463 catalog themes land within ΔE00 10 of their own bar that way.
    /// The two repair behaviours are the answer to that, and both of them measure
    /// against the bar as well as against focus.
    public func attentionColour(_ accent: AttentionAccent, behavior: AlertBehavior) -> RGB {
        let resolved = switch accent {
        case .alert: alert
        case .accent: focusedAccent
        }
        switch behavior {
        case .stock: return resolved
        case .noCollision: return collides(resolved) ? alert : resolved
        case .derive: return collides(resolved) ? derived(from: resolved) : resolved
        }
    }

    /// Whether ``AlertBehavior`` changes anything on this theme under `accent`.
    ///
    /// **Derived from ``attentionColour(_:behavior:)`` rather than from the
    /// collision test it uses**, so it cannot come to disagree with the thing it
    /// describes. The rule already has one home and a predicate that re-tested
    /// `collides` would be a second copy of it, which is the failure this file
    /// warns about two doc comments above: a floor met in one place and missed in
    /// the other.
    ///
    /// Written for the settings window, which hides the Alert picker when this is
    /// false. It answers true in two places and the second is easy to miss.
    ///
    /// Under ``AttentionAccent/accent`` it is true on *every* theme, because the
    /// attention colour is the focus colour by construction, so its distance to
    /// focus is zero and it always collides. Under ``AttentionAccent/alert`` it is
    /// true only where the theme's own `ansi[1]` lands on its focus colour or its
    /// bar, which 124 of the 463 catalog themes do.
    ///
    /// So this is a **superset** of the rule it replaces, not a narrower one. The
    /// first draft was to hide the picker unless `attentionAccent` is `accent`;
    /// that agrees here on the `accent` half and hides a live control on the 124.
    /// The one place the key is inert is `alert` on a theme with room, which is
    /// exactly `Settings.defaultSettings` and so is what most people open the
    /// window on.
    public func alertBehaviorMatters(for accent: AttentionAccent) -> Bool {
        let answers = AlertBehavior.allCases.map { attentionColour(accent, behavior: $0) }
        return answers.contains { $0 != answers[0] }
    }

    /// Whether `colour` would be read as something other than the attention signal.
    ///
    /// Two ways for that to happen, and only the first was checked at first. The
    /// obvious one is the focus colour: focus and attention drawn in one hue is two
    /// signals nobody can separate.
    ///
    /// The other is the surface underneath. The loud treatment is a 22 pt wash
    /// across the footer plus a 2 pt frame around the pane, and a wash the colour
    /// of the footer it washes is not a wash. The pane stops asking with nothing on
    /// screen to explain it, which is a worse failure than the collision with focus
    /// this key was written for, because at least a colliding focus is *a* colour.
    /// Measured against ``barBackground`` and ``background`` both, since the wash
    /// and the line land on the first while the pane frame lands mostly on the
    /// second.
    private func collides(_ colour: RGB) -> Bool {
        attentionSeparation(of: colour) < Self.minimumAttentionSeparation
    }

    /// How far `colour` sits from the nearest thing it must not be mistaken for.
    ///
    /// Internal rather than private so the tests can grade a candidate by the same
    /// measure the search grades it by. A test that spelled the `min` out again
    /// would be asserting its own copy of the rule, which is how a floor comes to
    /// be met in one file and missed in the other.
    func attentionSeparation(of colour: RGB) -> Double {
        min(
            colour.perceptualDistance(to: focusedAccent),
            colour.perceptualDistance(to: barBackground),
            colour.perceptualDistance(to: background)
        )
    }

    /// How far apart, in CIEDE2000, the attention colour has to be from the focus
    /// colour and from the bar it is drawn on before
    /// ``BaiaSettings/AlertBehavior/derive`` stops pushing it, and the distance
    /// under which ``BaiaSettings/AlertBehavior/noCollision`` calls the two one
    /// colour.
    ///
    /// Not a just-noticeable difference, which is around 1 and would be met by a
    /// pair nobody could tell apart here. A JND is measured on two large patches
    /// abutting each other under controlled light, and none of that holds: the
    /// attention fill is 22 pt of one pane's footer and the focus edge is 2 pt of
    /// another's, both over live terminal output, and the question is not whether
    /// someone staring at the pair can separate them but whether a glance across
    /// six panes reads two signals rather than one. 10 is where colours stop
    /// sharing a name.
    public static let minimumAttentionSeparation: Double = 10

    /// The colliding attention colour, pushed until it clears
    /// ``minimumAttentionSeparation`` from the focus colour and from the bar.
    ///
    /// Towards ``alert`` first, because the thing is still an alert: the pane is
    /// asking, and a colour chosen for separation alone would say something the
    /// pane does not mean. On Dark Pastel under `attentionAccent: accent` the first
    /// step of the first direction is enough: `#b5d5ff` 35% of the way to `#ff5555`
    /// is `#cfa8c3`, which measures **ΔE00 25.53** from the accent against a floor
    /// of 10. On the light theme in the tests it is 18.23, and on a theme whose red
    /// is its own selection colour the second direction gives 18.44. The first
    /// fraction that clears the floor on the owner's theme clears it three times
    /// over, which is why the search below almost never takes a second step.
    ///
    /// A walk rather than one fraction, for the same reason
    /// ``readable(_:on:minimumRatio:)`` is one: the number that is enough for the
    /// owner's theme is not a number that is enough for every theme, and a fixed
    /// fraction that silently under-separates on someone else's palette is the
    /// failure this whole key exists to fix. It stops at 0.75 because 1.0 towards
    /// ``alert`` is ``BaiaSettings/AlertBehavior/noCollision`` under another name,
    /// and two settings that resolve to one colour is a menu with a lie in it.
    ///
    /// Several directions rather than one, and ordered rather than optimised,
    /// because the order is the semantic claim: ``alert``, then the theme's own
    /// warn hue, then the rest of the palette, then the foreground. The first
    /// candidate that clears the floor wins, so wherever the honest direction works
    /// the answer *is* the honest direction and nothing further is tried.
    ///
    /// One direction was not enough, and the old code could not say so. It walked
    /// towards ``alert`` alone, fell through to `ansi[3]` only when the colour was
    /// already ``alert``, and returned its last step when nothing cleared, silently,
    /// under a comment that scoped that escape to "a theme with no distinct colours
    /// at all". That case does not occur in the shipped catalog. The case that does
    /// is a theme whose one blend direction happens to sit near the colour being
    /// blended, while fourteen other palette slots are far away: HaX0R Blue spends
    /// `ansi[1]`, `ansi[3]` and `ansi[5]` on one colour, and `derive` returned the
    /// colliding colour bit for bit at ΔE00 **0.00**. 83 of the 2315
    /// theme-by-`focusAccent` rows landed under the floor that way, across 33
    /// themes, and every one of them had a palette slot that would have cleared it.
    ///
    /// Towards ``background`` is not offered as a direction: a fill that is nearly
    /// the bar it fills is not a fill. That is now enforced rather than avoided,
    /// since ``attentionSeparation(of:)`` measures against the bar, so a candidate
    /// that separates from focus by going dark cannot be accepted.
    ///
    /// It can still fail to clear the floor, and now only where the palette has
    /// nothing to offer at all, which is what
    /// `deriveOnAThemeWithNothingToBlendTowardsStillAnswers` pins. There it hands
    /// back the best candidate it measured rather than the last one it happened to
    /// try. A weaker promise than the floor, and the strongest one a palette of a
    /// single colour can keep. Same contract as ``ansiColor(_:)``: answer with
    /// something drawable rather than trap inside a draw call.
    private func derived(from colour: RGB) -> RGB {
        var best = colour
        var bestSeparation = attentionSeparation(of: colour)
        for target in derivationTargets {
            for fraction in Self.attentionDerivation {
                let candidate = colour.blended(with: target, fraction: fraction)
                let separation = attentionSeparation(of: candidate)
                if separation >= Self.minimumAttentionSeparation { return candidate }
                if separation > bestSeparation {
                    best = candidate
                    bestSeparation = separation
                }
            }
        }
        return best
    }

    /// The colours ``derived(from:)`` blends towards, in the order it tries them.
    ///
    /// ``alert`` and the warn hue lead because they are the two hues that still
    /// mean alarm. `ansi[1]` and `ansi[3]` appear twice, once at the front and
    /// again inside the palette sweep, which costs three redundant blends on a
    /// theme that has already failed both; deduplicating would buy nothing and
    /// would put the ordering in two places.
    ///
    /// Blending towards a target that *is* the source is a no-op, which is what
    /// makes the `alert`-first order safe on the theme that spends one slot on both
    /// its red and its selection highlight: the first direction cannot move it, and
    /// the search falls through to the warn hue exactly as it used to.
    private var derivationTargets: [RGB] {
        [alert, ansiColor(3)] + (0 ..< 16).map(ansiColor) + [foreground]
    }

    /// The steps ``derived(from:)`` walks along each direction.
    private static let attentionDerivation: [Double] = [0.35, 0.55, 0.75]

    /// The focus colour as it is actually drawn: the accent, repaired for the
    /// bar.
    ///
    /// Spelled as the focused anchor name's own colour rather than as a separate
    /// call to ``readable(_:on:minimumRatio:)``, so an edit to `.strong` cannot
    /// leave the two disagreeing. Its other two consumers are the footer's focus
    /// frame and the colour a divider takes while it is dragged: neither is text
    /// and the 4.5:1 is not owed to them, but an unrepaired accent drawn beside a
    /// repaired name is two blues arguing.
    ///
    /// Unlike ``inkContext`` and ``inkFaint``, which are candidates the repair
    /// chain still has the last word on, this is post-repair.
    public var inkFocus: RGB {
        color(for: .strong, focused: true)
    }

    /// A half-finished operation, and the dirty marker. Blended a long way
    /// towards the background because raw yellow on a dark bar is louder than
    /// anything that is not an emergency should be.
    public var warn: RGB {
        background.blended(with: ansiColor(3), fraction: 0.75)
    }

    /// Ahead and behind counts. Raw `ansi[4]` scores badly on most dark themes
    /// and is repaired by ``readable(_:on:minimumRatio:)`` at the point of use
    /// rather than pre-brightened here, so a theme whose blue already passes
    /// keeps its own blue.
    public var info: RGB { ansiColor(4) }

    /// A working agent's dot. Never used for text.
    public var ok: RGB { ansiColor(2) }

    /// A staged change: in the index, and what a commit right now would contain.
    ///
    /// Built like ``warn``, from the adjacent ANSI slot at the same fraction, so
    /// the pair reads as a pair. The sidebar's changed-file rows colour the two
    /// `XY` columns independently, and the two colours have to look like one
    /// vocabulary or the distinction reads as decoration.
    ///
    /// Not raw ``ok``, which the row used before design v3 §2: `ansi[2]` at full
    /// strength is a signal light, and its own documentation says it is never used
    /// for text.
    public var staged: RGB {
        background.blended(with: ansiColor(2), fraction: 0.75)
    }

    /// A conflicted tree, and an agent asking for input. Nothing else.
    public var alert: RGB { ansiColor(1) }

    /// The colour ``colour(for:)`` resolves a file's change state to.
    ///
    /// One policy shared by the changes list's two-column marker and the file
    /// tree's single glyph, which colour a `staged`/`unstaged` pair and a
    /// rolled-up worst-case respectively but agree on what each state means.
    public enum ChangeMark: Sendable, Equatable, CaseIterable {
        case staged, unstaged, untracked, conflict
    }

    /// The colour a file's change state is drawn in, wherever it appears.
    ///
    /// Borrowed from the footer's own vocabulary rather than invented: the same
    /// colours already mean the same things one line below.
    public func colour(for mark: ChangeMark) -> RGB {
        switch mark {
        // Not `ok`, whose own documentation says it is never used for text.
        // `staged` is that green given `warn`'s construction, so the pair a
        // reader has to tell apart is one vocabulary rather than two.
        case .staged: staged
        case .unstaged: warn
        case .untracked: inkFaint
        case .conflict: alert
        }
    }

    /// A floating panel over the workspace, for example the command palette.
    ///
    /// Below ``barBackground`` rather than above it. The panel is a large surface
    /// and the footer is a thin one, so lifting the panel as far as the bar would
    /// make it the brightest object on screen by area. It separates from the
    /// terminal by its border and its shadow instead.
    public var panelBackground: RGB {
        background.blended(with: foreground, fraction: 0.05)
    }

    /// The selected row of a list inside a panel.
    ///
    /// One step of lift, the same fraction as ``divider``, so the row reads as
    /// raised without the palette growing a second accent surface. The accent
    /// itself is spent on the 2 pt leading edge, which is what actually says
    /// "this one": a list is scanned rather than inhabited, so the mark has to
    /// survive the eye moving down the rows rather than resting on one.
    public var selectedRowBackground: RGB {
        background.blended(with: foreground, fraction: 0.12)
    }

    /// Tier 4 text: the pin chip and the agent label.
    public var inkContext: RGB {
        foreground.blended(with: background, fraction: 0.18)
    }

    /// Tier 4 text, quieter: the working directory.
    ///
    /// 0.30 is the floor rather than a preference. At 0.32 the result lands under
    /// ``minimumTextContrast`` on the bar it is drawn on, ``readable`` repairs it
    /// back up, and "faint" stops meaning anything at all.
    public var inkFaint: RGB {
        foreground.blended(with: background, fraction: 0.30)
    }

    /// The colour to draw a segment of this emphasis in, on a given bar.
    ///
    /// The bar is passed in rather than assumed, because it is not always
    /// ``barBackground``: an asking pane fills it with ``alert``. Judging
    /// contrast against the wrong surface is precisely the mistake
    /// ``readable(_:on:minimumRatio:)`` was written to prevent, so the caller
    /// that decided the fill is the one that has to name it.
    ///
    /// Nothing dims here. An unfocused pane is left alone entirely and the
    /// focused one is enclosed instead, which is what removed `unfocusedDim`:
    /// text faded into its own bar is repaired straight back up the moment it
    /// drops under ``minimumTextContrast``, so a treatment made of dimming had a
    /// ceiling built into it.
    public func color(for emphasis: PaneStatusEmphasis, focused: Bool, on bar: RGB) -> RGB {
        readable(
            baseColor(for: emphasis, focused: focused),
            on: bar,
            minimumRatio: Self.minimumTextContrast
        )
    }

    /// The colour on this pane's ordinary, unfilled bar.
    public func color(for emphasis: PaneStatusEmphasis, focused: Bool) -> RGB {
        color(for: emphasis, focused: focused, on: barBackground)
    }

    /// The colour a run is drawn in, honouring the attention-fill collapse.
    ///
    /// A distinct function rather than a branch inside ``color(for:focused:on:)``:
    /// that one is the palette's own per-tier policy, exercised by every ordinary
    /// bar, and a fill parameter folded into it would make every caller's meaning
    /// depend on an argument most of them never vary. Unfilled, this delegates to
    /// it unchanged.
    ///
    /// Filled, every tier collapses onto two inks derived from the fill, because
    /// a fill bright enough to be worth filling a bar with reverses the direction
    /// the repair chain pushes in, and the tier colours are all derived from the
    /// foreground, which is the wrong end.
    public func color(for emphasis: PaneStatusEmphasis, focused: Bool, filled: Bool, on bar: RGB) -> RGB {
        guard filled else { return color(for: emphasis, focused: focused, on: bar) }
        switch emphasis {
        case .context, .faint: return mutedInk(on: bar)
        default: return ink(on: bar)
        }
    }

    /// The text colour for a bar that has been filled with `fill`, which today
    /// means an asking footer.
    ///
    /// The candidate is ``background`` rather than the emphasis colour, and that
    /// is the whole point. A fill loud enough to be worth filling a bar with is
    /// bright, so ``RGB/isDark`` flips on it and the repair chain turns around
    /// and pushes towards black. Handing it a foreground-derived candidate means
    /// starting at the wrong end and walking away from the answer: on the alert
    /// fill the chain runs out of steps at about 4.3:1 and then falls back to
    /// ``foreground``, which scores 1.4:1 and is genuinely unreadable.
    /// ``background`` starts at the far end and lands around 6:1 on the first
    /// try, with no hand-written branch for the alert red.
    ///
    /// It is also what the focused pane's frame is drawn in on a bar that is
    /// filled, so focus and attention stay one signal on the pane that is both.
    public func ink(on fill: RGB) -> RGB {
        readable(background, on: fill, minimumRatio: Self.minimumTextContrast)
    }

    /// The quieter text colour on a filled bar, for tier 4 on an asking footer.
    ///
    /// Pulled towards the fill rather than towards the foreground, so it recedes
    /// into the bar it sits on the way ``inkContext`` recedes into an ordinary
    /// one. Bounded by the same collision as every other tier: blend further and
    /// the repair chain hands back something brighter than the tier above it.
    public func mutedInk(on fill: RGB) -> RGB {
        let muted = readable(
            background.blended(with: fill, fraction: 0.35),
            on: fill,
            minimumRatio: Self.minimumTextContrast
        )
        let ink = ink(on: fill)
        // On a mid-luminance fill the muted candidate starts *closer* to the
        // fill than the ink does, fails the floor, and is then repaired away from
        // it. The repair overshoots: tier 4 comes back louder than tier 3, so a
        // filled footer reads with the quiet tier shouting. Where that happens
        // the two tiers collapse into one. Flattening loses a distinction;
        // inverting states a false one.
        guard muted.contrastRatio(against: fill) <= ink.contrastRatio(against: fill) else {
            return ink
        }
        return muted
    }

    /// Judges `candidate` as it will be seen, composited on `background`, and
    /// walks a fallback chain until one clears `minimumRatio`.
    ///
    /// The ratio is taken against the `background` passed in, not against the
    /// theme's own ``background``. The bar is a lifted blend of the terminal
    /// background and a focused bar is lifted further, so a colour judged against
    /// the theme background can be a whole ratio point off what it scores where it
    /// is actually drawn.
    ///
    /// The chain pushes the candidate away from the background, by a third, by
    /// two thirds, and finally the whole way, towards white or black.
    ///
    /// The direction is chosen by ``RGB/relativeLuminance``, the same measure the
    /// ratio is graded with, rather than by ``RGB/isDark``. Those two disagree:
    /// `isDark` is a YIQ test kept deliberately in step with ghostty's own theme
    /// classification, and on a mid-luminance fill it can call a background dark
    /// while WCAG puts it above the midpoint. The repair then walked the
    /// candidate *towards* the background it was trying to escape, every link of
    /// the chain failed, and the function fell through to a last resort that was
    /// never contrast-checked at all. On an alert fill that returned the theme
    /// foreground at about 1.4:1, which is unreadable, from a function whose whole
    /// job is to guarantee 4.5:1. `isDark` keeps its place elsewhere; it is only
    /// wrong as the direction for a WCAG-graded repair.
    ///
    /// The last resort is now the best of the two ends and the theme foreground,
    /// measured. It can still be below `minimumRatio` for a fill no colour clears,
    /// which is a broken theme rather than a broken bar, but it can no longer be
    /// worse than the alternatives that were available.
    public func readable(_ candidate: RGB, on background: RGB, minimumRatio: Double) -> RGB {
        let away = background.relativeLuminance < 0.5 ? Self.paleEnd : Self.darkEnd
        let chain = [
            candidate,
            candidate.blended(with: away, fraction: Self.firstRepair),
            candidate.blended(with: away, fraction: Self.secondRepair),
            away,
        ]
        for colour in chain where colour.contrastRatio(against: background) >= minimumRatio {
            return colour
        }
        return [foreground, Self.paleEnd, Self.darkEnd]
            .max { $0.contrastRatio(against: background) < $1.contrastRatio(against: background) }
            ?? foreground
    }

    /// The colour an emphasis starts from, before the repair chain judges it
    /// against the bar it lands on.
    private func baseColor(for emphasis: PaneStatusEmphasis, focused: Bool) -> RGB {
        switch emphasis {
        // The accent only appears on the focused pane's name. It is the one place
        // focus touches the bar's *text*, the other being the frame around the
        // bar, and it is a colour swap on text that was going to be drawn anyway,
        // so it cannot change the bar's height.
        case .strong: return focused ? focusedAccent : foreground
        case .normal: return foreground
        case .warn: return warn
        case .alert: return alert
        case .info: return info
        case .context: return inkContext
        case .faint: return inkFaint
        }
    }

    /// The ANSI colour at `index`, or ``foreground`` when the palette is too
    /// short. A missing palette entry is a fallible read, so it answers with
    /// something drawable rather than trapping inside a draw call, in the same way
    /// a failed working-directory read leaves the last known directory in place.
    ///
    /// Every derivation that names a palette slot goes through here rather than
    /// subscripting ``ansi``, ``accent(for:)`` included. A theme is allowed to
    /// declare fewer than sixteen colours, so a direct index is a trap waiting
    /// for the first sparse theme somebody configures.
    public func ansiColor(_ index: Int) -> RGB {
        ansi.indices.contains(index) ? ansi[index] : foreground
    }

    /// How far ``barBackground`` moves off the terminal background. Small enough
    /// that the bar is not a bright band across a dark pane, large enough that
    /// the boundary is visible without the hairline.
    private static let barLift: Double = 0.08

    /// How far *every* pane is covered when the window is not key.
    ///
    /// The only scrim left, and it is a statement about windows rather than about
    /// panes: an inactive window reads as one recessed object rather than as a
    /// window that still has a live pane in it. macOS gives no other honest
    /// signal here, since the titlebar is transparent.
    ///
    /// Light enough that the panes stay readable, because a background window is
    /// exactly when the owner is scanning them to decide which one to come back
    /// to. A heavier scrim above it once marked the focused pane by taxing every
    /// other one; the focused pane's footer wears a frame now, so no pane is
    /// taxed for being merely unfocused.
    public static let inactiveScrim: Double = 0.15

    /// The two steps of the repair chain in ``readable(_:on:minimumRatio:)``.
    private static let firstRepair: Double = 0.35
    private static let secondRepair: Double = 0.70

    /// The ends the repair chain pushes towards, chosen by ``RGB/isDark`` on the
    /// background being judged.
    private static let paleEnd = RGB(red: 1, green: 1, blue: 1)
    private static let darkEnd = RGB(red: 0, green: 0, blue: 0)
}
