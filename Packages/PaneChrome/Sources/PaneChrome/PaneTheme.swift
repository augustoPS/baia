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
    public var divider: RGB {
        background.blended(with: foreground, fraction: 0.12)
    }

    /// The line between the terminal and its own footer.
    public var hairline: RGB {
        background.blended(with: foreground, fraction: 0.18)
    }

    /// The stroke around a focused pane under `FocusStyle.frame`, and the colour
    /// a divider takes while it is being dragged.
    public var edgeFocus: RGB {
        background.blended(with: focusedAccent, fraction: 0.55)
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

    /// A conflicted tree, and an agent asking for input. Nothing else.
    public var alert: RGB { ansiColor(1) }

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
    /// The bar is passed in rather than assumed, because it is no longer always
    /// ``barBackground``: an inverted focused pane fills it with the focus
    /// colour, and an asking pane fills it with ``alert``. Judging contrast
    /// against the wrong surface is precisely the mistake
    /// ``readable(_:on:minimumRatio:)`` was written to prevent, so the caller
    /// that decided the fill is the one that has to name it.
    ///
    /// Nothing dims here any more. Unfocused panes recede behind a scrim drawn
    /// over the whole pane, which has no ceiling, where fading text into its own
    /// bar was bounded by the repair chain undoing it.
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

    /// The text colour for a bar that has been filled with `fill`: an inverted
    /// focused footer, or an asking one.
    ///
    /// The candidate is ``background`` rather than the emphasis colour, and that
    /// is the whole point. A fill loud enough to be worth filling a bar with is
    /// bright, so ``RGB/isDark`` flips on it and the repair chain turns around
    /// and pushes towards black. Handing it a foreground-derived candidate means
    /// starting at the wrong end and walking away from the answer: on the alert
    /// fill the chain runs out of steps at about 4.3:1 and then falls back to
    /// ``foreground``, which scores 1.4:1 and is genuinely unreadable.
    /// ``background`` starts at the far end and lands around 6:1 on the first
    /// try, which is also why option A's inverted bar needs no hand-written
    /// branch for its alert red.
    public func ink(on fill: RGB) -> RGB {
        readable(background, on: fill, minimumRatio: Self.minimumTextContrast)
    }

    /// The quieter text colour on a filled bar, for tier 4 on an inverted footer.
    ///
    /// Pulled towards the fill rather than towards the foreground, so it recedes
    /// into the bar it sits on the way ``inkContext`` recedes into an ordinary
    /// one. Bounded by the same collision as every other tier: blend further and
    /// the repair chain hands back something brighter than the tier above it.
    public func mutedInk(on fill: RGB) -> RGB {
        readable(
            background.blended(with: fill, fraction: 0.35),
            on: fill,
            minimumRatio: Self.minimumTextContrast
        )
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
    /// The chain pushes the candidate away from the background, by a third and
    /// then by two thirds, towards white or black according to ``RGB/isDark`` on
    /// the background so the push agrees with the terminal's own theme test. The
    /// last resort is the theme foreground, which passes for any theme whose text
    /// is legible on its own background, and a theme that fails that is broken in
    /// the surface long before it is broken in the bar.
    public func readable(_ candidate: RGB, on background: RGB, minimumRatio: Double) -> RGB {
        let away = background.isDark ? Self.paleEnd : Self.darkEnd
        let chain = [
            candidate,
            candidate.blended(with: away, fraction: Self.firstRepair),
            candidate.blended(with: away, fraction: Self.secondRepair),
        ]
        for colour in chain where colour.contrastRatio(against: background) >= minimumRatio {
            return colour
        }
        return foreground
    }

    /// The colour an emphasis starts from, before an unfocused pane dims it.
    private func baseColor(for emphasis: PaneStatusEmphasis, focused: Bool) -> RGB {
        switch emphasis {
        // The accent only appears on the focused pane's name. It is the one place
        // focus still touches the bar, and it is a colour swap on text that was
        // going to be drawn anyway, so it cannot change the bar's height.
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
    /// Public so the app can resolve a `focusAccent` choice against the live
    /// palette. Reaching into ``ansi`` directly would be an unchecked index, and
    /// the whole reason this exists is that a theme is allowed to declare fewer
    /// than sixteen colours.
    public func ansiColor(_ index: Int) -> RGB {
        ansi.indices.contains(index) ? ansi[index] : foreground
    }

    /// How far ``barBackground`` moves off the terminal background. Small enough
    /// that the bar is not a bright band across a dark pane, large enough that
    /// the boundary is visible without the hairline.
    private static let barLift: Double = 0.08

    /// How far an unfocused pane is covered by its own background.
    ///
    /// The default for `FocusStyle.recede`, and the reason `focusedTint` and
    /// `unfocusedDim` are gone. Both of those fought the repair chain: text faded
    /// into its own bar gets repaired back up the moment it drops under
    /// ``minimumTextContrast``, so the dimming had a ceiling built into it. A
    /// scrim sits *above* the surface and has no such ceiling, which is what lets
    /// one mechanism carry the whole treatment.
    ///
    /// The app overrides this from the config file. It lives here as well so that
    /// `PaneChrome` states the design's own number rather than depending on a
    /// settings package it must not import.
    public static let unfocusedScrim: Double = 0.28

    /// How far *every* pane is covered when the window is not key.
    ///
    /// Lighter than ``unfocusedScrim``, and applied on top of nothing else: an
    /// inactive window reads as one recessed object rather than as a window that
    /// still has a focused pane in it. macOS gives no other honest signal here,
    /// since the titlebar is transparent.
    public static let inactiveScrim: Double = 0.15

    /// The two steps of the repair chain in ``readable(_:on:minimumRatio:)``.
    private static let firstRepair: Double = 0.35
    private static let secondRepair: Double = 0.70

    /// The ends the repair chain pushes towards, chosen by ``RGB/isDark`` on the
    /// background being judged.
    private static let paleEnd = RGB(red: 1, green: 1, blue: 1)
    private static let darkEnd = RGB(red: 0, green: 0, blue: 0)
}
