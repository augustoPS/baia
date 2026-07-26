import Foundation

/// The fixed geometry of a pane's status bar.
///
/// Every value here is a constant, and ``height`` most of all. A footer that
/// grew when its pane took focus would shrink the terminal view above it, which
/// resizes the ghostty grid and sends `SIGWINCH` to whatever runs in the pane.
/// In a pane driving a coding agent, moving focus would reflow the agent's
/// output, so the act of looking at a pane would destroy what it was showing.
///
/// Focus is no longer drawn in the bar at all. It is carried by a scrim over
/// every *other* pane, which is why the accent stripe that used to live inside
/// this height is gone: with nothing here varying on focus, there is no branch
/// left for a later edit to make conditional.
public struct PaneStatusBarMetrics: Sendable, Equatable {
    /// Identical for focused and unfocused panes. Sized for the 11.5 pt terminal
    /// font the owner's ghostty config sets, and for the 11 pt anchor name that
    /// is the tallest thing drawn on it.
    public static let height: Double = 22

    /// Matches `window-padding-x 8` from the owner's ghostty config, so a
    /// segment's first glyph sits on the same column as the terminal text above
    /// it instead of a few points off it.
    public static let horizontalInset: Double = 8

    /// The gap between two segments that answer the same question, for example a
    /// branch and its markers.
    ///
    /// Tighter than the 8 pt single spacing it replaces. Spacing is the only
    /// grouping device the bar has left once every tier is one baseline, so the
    /// two values have to be far enough apart to read as different: `main` and
    /// `↑1↓2*?3` belong together, and `main` and the agent label do not.
    public static let spacingWithinGroup: Double = 5

    /// The gap between two segments that answer different questions, for example
    /// the repository group and the agent label.
    ///
    /// Groups are the contiguous runs `[name, PIN]`, `[operation, branch,
    /// markers]`, `[agent]` and `[working directory]`. Because segments vanish
    /// rather than render empty, a group can be one segment wide or absent
    /// entirely, and the gap has to be computed from what actually survived
    /// rather than assumed from a fixed row of slots.
    public static let spacingBetweenGroups: Double = 12

    /// The divider between the terminal and the bar. One point, not one pixel:
    /// the app draws in points and a Retina backing store halves it anyway.
    public static let hairlineHeight: Double = 1

    /// The single text baseline every segment sits on, measured down from the
    /// bar's top edge.
    ///
    /// One baseline rather than centring each segment in the height. The bar now
    /// mixes 9.5, 10, 10.5 and 11 pt, and two sizes centred independently in
    /// 22 pt sit about a quarter of a point apart, which does not read as a
    /// deliberate difference. It reads as a typo.
    public static let baselineFromTop: Double = 15

    /// The height a pane's terminal view gives up to the bar.
    ///
    /// The parameter is deliberately ignored. It exists so that no caller can
    /// express a focus-dependent height, and so that
    /// `theBarHeightDoesNotDependOnFocus` starts failing the moment this body
    /// grows a branch on it. Reading ``height`` directly is equally correct.
    public static func reservedHeight(focused _: Bool) -> Double {
        height
    }

    /// The gap to leave between two neighbouring segments.
    ///
    /// The only place the two spacings are chosen between, so the width solver
    /// and the drawing code cannot disagree about what a bar is going to look
    /// like. They did have to agree before, when there was one constant; now
    /// that there are two, agreeing by construction is what stops a bar from
    /// measuring as fitting and then drawing past its own inset.
    public static func spacing(from: PaneStatusGroup, to: PaneStatusGroup) -> Double {
        from == to ? spacingWithinGroup : spacingBetweenGroups
    }
}
