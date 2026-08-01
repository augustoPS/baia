import Foundation

/// The fixed geometry of a pane's status bar.
///
/// Every value here is a constant, and ``height`` most of all. A footer that
/// grew when its pane took focus would shrink the terminal view above it, which
/// resizes the ghostty grid and sends `SIGWINCH` to whatever runs in the pane.
/// In a pane driving a coding agent, moving focus would reflow the agent's
/// output, so the act of looking at a pane would destroy what it was showing.
///
/// Focus is drawn in the bar again, as an inset stroke of ``focusFrameWidth``
/// around the bar itself. What keeps the `SIGWINCH` hazard closed is the word
/// inset: the frame lives *inside* a height that still does not branch on focus,
/// so no focus treatment can reach ``height`` or ``reservedHeight(focused:)``.
/// The absence of any focus drawing was never what made the bar safe. The
/// absence of a focus-dependent height was.
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

    /// The bar's outer edge, along the bottom, away from the terminal. One
    /// point, not one pixel: the app draws in points and a Retina backing store
    /// halves it anyway.
    ///
    /// Which edge it is on is load-bearing rather than incidental. The terminal
    /// grid has to meet the bar with nothing between them, so the separator goes
    /// on the far side, and the focus frame's bottom stroke then covers this
    /// line exactly rather than stacking beside it.
    public static let hairlineHeight: Double = 1

    /// The single text baseline every segment sits on, measured down from the
    /// bar's top edge.
    ///
    /// One baseline rather than centring each segment in the height. The bar now
    /// mixes 9.5, 10, 10.5 and 11 pt, and two sizes centred independently in
    /// 22 pt sit about a quarter of a point apart, which does not read as a
    /// deliberate difference. It reads as a typo.
    public static let baselineFromTop: Double = 15

    /// The focused bar's stroke, inset within ``height``.
    ///
    /// Inset rather than added, and that is the whole reason focus is allowed
    /// back into the bar at all: the text origin does not move, ``height`` does
    /// not branch, and ``reservedHeight(focused:)`` never sees focus. A frame
    /// that grew the bar would reflow the ghostty grid above it.
    ///
    /// Two points against a 22 pt band closes a 1,066 pt perimeter on a 511 pt
    /// pane, where the accent stripe it replaces was 511 pt along one edge.
    /// Enclosure is the fastest shape the visual system resolves.
    public static let focusFrameWidth: Double = 2

    /// The thickness of an attention line on the bar, at either edge.
    ///
    /// One value rather than one per site. The quiet treatment spends the top
    /// edge and the acknowledged level spends the bottom one, and the two reading
    /// as the same signal at two positions is the whole reason they are drawn as
    /// lines rather than as two different shapes. Two constants both spelled 2 is
    /// the arrangement that lets a later edit move one of them.
    ///
    /// Matched to ``focusFrameWidth`` for the same reason: on a focused pane the
    /// line sits directly inside the frame, and a line of a different weight
    /// beside it reads as a mistake rather than as a second signal.
    public static let attentionLine: Double = 2

    /// Below this pane width the frame drops its left and right edges.
    ///
    /// A narrow frame is nearly square and reads as a chip rather than as a
    /// band, which in a pane is the worst thing chrome can look like: nothing
    /// here may take first responder, so anything that looks pressable is a lie.
    /// Top and bottom only is a bracket, which still says "this one" without
    /// claiming to be an object.
    public static let frameCollapseWidth: Double = 120

    /// The height a pane's terminal view gives up to the bar.
    ///
    /// The parameter is deliberately ignored. It exists so that no caller can
    /// express a focus-dependent height, and so that
    /// `theBarHeightDoesNotDependOnFocus` starts failing the moment this body
    /// grows a branch on it. Reading ``height`` directly is equally correct.
    public static func reservedHeight(focused _: Bool) -> Double {
        height
    }

    /// Whether a bar this wide keeps the left and right edges of its focus frame.
    ///
    /// A function rather than a comparison written at the draw site, so the
    /// collapse threshold is stated once and tested without a window.
    public static func framesSides(atWidth width: Double) -> Bool {
        width >= frameCollapseWidth
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
