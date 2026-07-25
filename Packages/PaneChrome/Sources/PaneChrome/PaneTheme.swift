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

    /// Tinted towards the accent rather than brightened, and only slightly. A
    /// focused bar that gets much lighter eats the contrast every text colour on
    /// it depends on, and the repair chain in
    /// ``readable(_:on:minimumRatio:)`` would then quietly hand back a different
    /// colour for a focused pane than for an unfocused one.
    public var focusedBarBackground: RGB {
        background.blended(with: focusedAccent, fraction: Self.focusedTint)
    }

    /// The colour to draw a segment of this emphasis in, on this pane's bar.
    ///
    /// Focus changes colour and nothing else. Compare
    /// ``PaneStatusBarMetrics/height``, which is the geometry half of the same
    /// rule.
    public func color(for emphasis: PaneStatusEmphasis, focused: Bool) -> RGB {
        let bar = focused ? focusedBarBackground : barBackground
        let base = baseColor(for: emphasis, focused: focused)

        // An unfocused pane's ordinary text recedes, but an alert never does. The
        // pane that needs the owner is by definition not the one he is looking
        // at: the signal this replaces is a single `afplay Blow.aiff` on the Stop
        // hook, identical for every session, and dimming its visible replacement
        // in exactly the panes it is meant for would put baia back where it
        // started. A strong segment holds too, because scanning a wall of
        // unfocused panes for a project name is what the bar is for.
        let dims = !focused && (emphasis == .normal || emphasis == .muted)
        let shown = dims ? base.blended(with: bar, fraction: Self.unfocusedDim) : base

        return readable(shown, on: bar, minimumRatio: Self.minimumTextContrast)
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
        // The accent only appears on the focused pane's name, which is what makes
        // one bar out of five identifiable at a glance without any of them
        // changing size.
        case .strong: return focused ? focusedAccent : foreground
        case .normal: return foreground
        case .muted: return foreground.blended(with: background, fraction: Self.mutedFade)
        case .alert: return ansiColor(1)
        }
    }

    /// The ANSI colour at `index`, or ``foreground`` when the palette is too
    /// short. A missing palette entry is a fallible read, so it answers with
    /// something drawable rather than trapping inside a draw call, in the same way
    /// a failed working-directory read leaves the last known directory in place.
    private func ansiColor(_ index: Int) -> RGB {
        ansi.indices.contains(index) ? ansi[index] : foreground
    }

    /// How far ``barBackground`` moves off the terminal background. Small enough
    /// that the bar is not a bright band across a dark pane, large enough that
    /// the boundary is visible without the hairline.
    private static let barLift: Double = 0.08

    /// How far ``focusedBarBackground`` moves towards the accent.
    private static let focusedTint: Double = 0.10

    /// How far a muted segment fades towards the background. Held at 0.18 because
    /// 0.25 puts the result under ``minimumTextContrast`` on the bar it is drawn
    /// on, at which point ``readable(_:on:minimumRatio:)`` repairs it back up and
    /// muted stops meaning anything.
    private static let mutedFade: Double = 0.18

    /// How far an unfocused pane's ordinary text fades into its bar. Bounded by
    /// the same collision: dim a muted segment much harder and the repair chain
    /// undoes the dimming.
    private static let unfocusedDim: Double = 0.15

    /// The two steps of the repair chain in ``readable(_:on:minimumRatio:)``.
    private static let firstRepair: Double = 0.35
    private static let secondRepair: Double = 0.70

    /// The ends the repair chain pushes towards, chosen by ``RGB/isDark`` on the
    /// background being judged.
    private static let paleEnd = RGB(red: 1, green: 1, blue: 1)
    private static let darkEnd = RGB(red: 0, green: 0, blue: 0)
}
