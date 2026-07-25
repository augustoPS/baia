import Foundation

/// The fixed geometry of a pane's status bar.
///
/// Every value here is a constant, and ``height`` most of all. A footer that
/// grew when its pane took focus would shrink the terminal view above it, which
/// resizes the ghostty grid and sends `SIGWINCH` to whatever runs in the pane.
/// In a pane driving a coding agent, moving focus would reflow the agent's
/// output, so the act of looking at a pane would destroy what it was showing.
/// Focus is carried by colour (``PaneTheme/focusedBarBackground``) and by an
/// accent stripe drawn *inside* this height, never by the height itself.
public struct PaneStatusBarMetrics: Sendable, Equatable {
    /// Identical for focused and unfocused panes. Sized for the 11.5 pt terminal
    /// font the owner's ghostty config sets, with room for ``accentStripeHeight``
    /// above the text rather than beside it.
    public static let height: Double = 22

    /// Matches `window-padding-x 8` from the owner's ghostty config, so a
    /// segment's first glyph sits on the same column as the terminal text above
    /// it instead of a few points off it.
    public static let horizontalInset: Double = 8

    /// Wide enough that `main` and `↑1↓2*?3` read as two facts rather than one
    /// run-together string, which is what the owner's own statusline gets wrong
    /// when a branch name ends in a digit.
    public static let segmentSpacing: Double = 8

    /// The divider between the terminal and the bar. One point, not one pixel:
    /// the app draws in points and a Retina backing store halves it anyway.
    public static let hairlineHeight: Double = 1

    /// Drawn along the bar's top edge, over the bar. Adding it to ``height``
    /// instead is the mistake this whole type exists to prevent.
    public static let accentStripeHeight: Double = 2

    /// The height a pane's terminal view gives up to the bar.
    ///
    /// The parameter is deliberately ignored. It exists so that no caller can
    /// express a focus-dependent height, and so that
    /// `theBarHeightDoesNotDependOnFocus` starts failing the moment this body
    /// grows a branch on it. Reading ``height`` directly is equally correct.
    public static func reservedHeight(focused _: Bool) -> Double {
        height
    }
}
