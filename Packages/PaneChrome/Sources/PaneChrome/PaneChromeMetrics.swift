import Foundation

/// Fixed chrome geometry that outlived the bar it was written for.
///
/// **The `SIGWINCH` hazard this file was built around is closed by deletion
/// rather than by arithmetic, and that is the only reason the reasoning below
/// is shorter than it was.** The rule used to be that ``paneBarHeight`` must
/// not branch on focus, because a footer that grew when its pane took focus
/// would shrink the terminal view above it, resize the ghostty grid, and send
/// `SIGWINCH` to whatever ran in the pane: in a pane driving a coding agent,
/// the act of looking at a pane would reflow the agent's output. There is no
/// footer now, so no live drawing spends a pane's height on chrome, and no
/// height can branch on anything. The hazard is not being managed; it is gone.
///
/// What survives is the hazard's *measurement*, and it survives because two
/// things still read it. ``glassWindowPaddingBump`` is a compensation whose
/// correctness was established against a real PTY and would be silently wrong
/// if the 22 pt it derives from drifted. `Diagnostics/footer-accessory` and
/// `Diagnostics/pane-glass-stacking` reconstruct the deleted footer's exact
/// geometry, on purpose, to answer questions the deletion did not settle.
/// Those probes read the constants rather than transcribing them, which is
/// what keeps their captures comparable with what actually shipped.
///
/// So the type is named for the chrome, not for the bar. A capsule that
/// imported `PaneStatusBarMetrics` to draw its own focus stroke was the
/// confusion that made this sweep necessary: ``focusFrameWidth`` is the
/// cluster pill's stroke and has been since the footer stopped drawing one.
public enum PaneChromeMetrics: Sendable {
    /// The focused pill's stroke.
    ///
    /// Two points against a 22 pt band closes a 1,066 pt perimeter on a 511 pt
    /// pane, where the accent stripe it replaces was 511 pt along one edge.
    /// Enclosure is the fastest shape the visual system resolves.
    ///
    /// It is drawn *inset* by half its width, so the stroke lands inside the
    /// pill's edge rather than straddling it. That was once a `SIGWINCH`
    /// argument — an inset frame cannot grow the band it is drawn in — and is
    /// now only a drawing one, since the pill is an overlay that takes no
    /// height from any terminal view. `PaneClusterView` is the single reader.
    public static let focusFrameWidth: Double = 2

    // MARK: - The footer's geometry, kept as a measured record

    /// The height the deleted footer reserved from a pane's terminal view.
    ///
    /// **Nothing draws this. It is retained as a measurement, not as a
    /// layout.** Two live consumers need the exact number: the derivation in
    /// ``glassWindowPaddingBump`` below, and the probes that rebuild the bar
    /// to compare a hand-managed footer against an
    /// `NSSplitViewItemAccessoryViewController` one.
    ///
    /// Sized for the 11.5 pt terminal font the owner's ghostty config sets,
    /// and for the 11 pt anchor name that was the tallest thing drawn on it.
    /// It was identical for focused and unfocused panes, which was the whole
    /// discipline of the type this replaced.
    public static let paneBarHeight: Double = 22

    /// Matches `window-padding-x 8` from the owner's ghostty config, so a
    /// reconstructed segment's first glyph sits on the same column as the
    /// terminal text above it instead of a few points off it.
    ///
    /// Distinct from `PaneClusterMetrics.horizontalInset`, which happens to
    /// hold the same 8 for the pill's own reasons. They were never one
    /// constant and folding them would couple a live layout to a frozen one.
    public static let paneBarHorizontalInset: Double = 8

    /// The single text baseline every segment sat on, measured down from the
    /// bar's top edge.
    ///
    /// One baseline rather than centring each segment in the height: the bar
    /// mixed 9.5, 10, 10.5 and 11 pt, and two sizes centred independently in
    /// 22 pt sit about a quarter of a point apart, which does not read as a
    /// deliberate difference. It reads as a typo.
    public static let paneBarBaselineFromTop: Double = 15

    /// The bar's outer edge, along the bottom, away from the terminal. One
    /// point, not one pixel: the app draws in points and a Retina backing
    /// store halves it anyway.
    public static let paneBarHairlineHeight: Double = 1

    /// The gap between two segments that answered different questions, for
    /// example the repository group and the agent label.
    ///
    /// The within-group spacing (5 pt) died with the width solver that chose
    /// between the two. Only this one is still read, by the probe that draws a
    /// single reconstructed line.
    public static let paneBarSpacingBetweenGroups: Double = 12

    /// The attention capsule's band, concentric inside ``paneBarHeight``.
    public static let capsuleHeight: Double = 16

    /// A capsule narrower than this reads as a dot rather than a control
    /// surface. What a single `!` at 10 pt lands on once padded.
    public static let capsuleMinWidth: Double = 21

    /// Room either side of the glyph inside the capsule.
    public static let capsulePadding: Double = 6

    /// The gap between the capsule and the first segment after it.
    public static let capsuleGap: Double = 6

    /// Where the capsule draws, in the bar's own flipped coordinates.
    ///
    /// A pure function of the measured glyph width, so a probe's fill layer
    /// and its glyph drawing read one answer rather than two.
    public struct CapsuleFrame: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    public static func attentionCapsuleFrame(glyphWidth: Double) -> CapsuleFrame {
        CapsuleFrame(
            x: paneBarHorizontalInset,
            y: (paneBarHeight - capsuleHeight) / 2,
            width: max(capsuleMinWidth, glyphWidth + capsulePadding * 2),
            height: capsuleHeight
        )
    }

    // MARK: - Glass compensation

    /// The `window-padding-y` compensation arrangement (B) spends when the
    /// terminal surface extends under a bar instead of stopping above it
    /// (design v5, the glass-backdrop spike's verdict).
    ///
    /// Half of ``paneBarHeight``, not all of it, because baia emits
    /// `window-padding-y` as a single value and ghostty then applies it to the
    /// top edge and the bottom edge both, so raising it by `n` removes `2n`
    /// points of drawable height.
    ///
    /// **The key itself is not symmetric, and an earlier version of this
    /// comment said it was.** ghostty accepts `window-padding-y = top,bottom`
    /// (documented in `ghostty +show-config --default --docs`), and
    /// `TerminalConfigCommand.custom` can emit that form. Only baia's own
    /// emission is symmetric — `TerminalOverride.windowPadding` writes one
    /// value — which is what makes the halving correct *here* while leaving
    /// asymmetric compensation available to anything that needs it. The
    /// distinction was load-bearing when the titlebar was considered for the
    /// same treatment; see `Diagnostics/titlebar-toolbar/README.md`, which
    /// rules that out on the window's shape rather than on this arithmetic.
    ///
    /// A 22 pt bar at the *bottom* edge is bought back with half of that,
    /// `+11`, not `+22`: the full value overshoots and silently costs the grid
    /// a row. Measured against a real PTY at
    /// `Diagnostics/glass-backdrop/gridtest.swift` — `window-padding-y` raised
    /// by exactly this amount is what leaves the row count at 82x23 unchanged;
    /// the naive `+height` compensation (arm D there) measures 82x22, one row
    /// short.
    ///
    /// **No shipping code path adds this today.** `ConfigurationCenter`'s
    /// `glassCompensatedTerminalConfiguration` was its last adder and was
    /// deleted on 2026-08-13, because the arm reaching it was already
    /// unreachable. It is kept because the glass-backdrop probe still measures
    /// the arithmetic against a live PTY on every run, and because a surface
    /// extended under chrome is the arrangement design v6 is still choosing
    /// between. If that question closes the other way, this goes with it.
    ///
    /// A derived quantity rather than a second literal, so a future change to
    /// ``paneBarHeight`` cannot leave this compensation silently wrong
    /// relative to it.
    public static let glassWindowPaddingBump: Double = paneBarHeight / 2
}
