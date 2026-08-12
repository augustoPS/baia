import Foundation

/// Fixed geometry of the capsule, the ``PaneStatusBarMetrics`` restraint
/// applied to the pill: constants only, nothing here may branch on focus, and
/// the capsule never touches the grid. Focus changes the fill and the stroke
/// (the view's business), never a dimension, so looking at a pane cannot
/// resize what the pane is showing.
public enum PaneClusterMetrics {
    /// Sized for the same 11 pt segment text the footer draws, plus the
    /// pill's vertical breathing room.
    public static let height: Double = 20

    /// Pill padding at both ends, before the first segment and after the
    /// last.
    public static let horizontalInset: Double = 8

    /// The gap between adjacent segments. One value, not the footer's
    /// within/between pair: the capsule's segments are all different
    /// questions, so there is no same-question grouping to express.
    public static let segmentGap: Double = 8

    /// The attention dot. Drawn, never read; ``PaneClusterSegment/text`` is
    /// empty for the attention role.
    public static let dotDiameter: Double = 6

    /// Pill to the pane's top-right corner, both axes.
    public static let cornerInset: Double = 6
}

/// What a pane's surface pins to at its bottom edge, decided once at spawn.
///
/// Three answers rather than a pair of Bools, because only three of the four
/// combinations exist: a pane with no footer never needs the bump, whatever
/// its chrome, so the fourth cell (clear, but bumped) is unrepresentable
/// here rather than a state every consumer has to know not to build.
public enum PaneBottomArrangement: Sendable, Equatable {
    /// The surface stops above the bar: a flat pane wearing the footer.
    case insetAboveBar
    /// The surface runs to the view's bottom and the grid keeps its inset
    /// through the `window-padding-y` bump: a glass pane with the footer
    /// floating over its last points.
    case fullHeightWithBump
    /// The surface runs to the view's bottom with no bump: nothing sits
    /// below it and nothing floats over it.
    case fullHeightClear
}

public extension PaneClusterMetrics {
    /// Which ``PaneBottomArrangement`` a pane spawns with.
    ///
    /// `clusterOnly` is whether the pane's mode at spawn is `.cluster`, the
    /// only mode with no footer; `underGlass` is whether its chrome resolved
    /// to glass at the same moment. Both inputs are spawn-frozen facts and
    /// the answer freezes with them: moving an existing pane between
    /// arrangements means changing its bottom anchor or its padding, and
    /// either is the live grid resize that signals SIGWINCH to whatever the
    /// pane is running. `TerminalPaneController.spawnedUnderGlass` carries
    /// the full argument; this function only decides, it never re-decides.
    static func bottomArrangement(clusterOnly: Bool, underGlass: Bool) -> PaneBottomArrangement {
        if clusterOnly { return .fullHeightClear }
        return underGlass ? .fullHeightWithBump : .insetAboveBar
    }
}

/// Where each segment sits inside the pill and which segment a click lands
/// on. The caller measures text (measuring needs a font, fonts need AppKit);
/// this solves placement and hit resolution, which is arithmetic the package
/// tests can reach.
public enum PaneClusterLayout {
    public struct Placed: Sendable, Equatable {
        public var segment: PaneClusterSegment
        public var x: Double
        public var width: Double

        public init(segment: PaneClusterSegment, x: Double, width: Double) {
            self.segment = segment
            self.x = x
            self.width = width
        }
    }

    /// Left-to-right placement from measured widths, in the order the
    /// segments arrive (``PaneClusterSegments/build(from:)`` owns that
    /// order). A role missing from `widths` places at zero width rather than
    /// throwing: the caller measured what it was given, and a zero-width
    /// segment is invisible and unhittable, which is the harmless failure.
    public static func solve(
        segments: [PaneClusterSegment],
        widths: [PaneClusterSegmentRole: Double]
    ) -> [Placed] {
        var x = PaneClusterMetrics.horizontalInset
        var placed: [Placed] = []
        for segment in segments {
            let width = widths[segment.role] ?? 0
            placed.append(Placed(segment: segment, x: x, width: width))
            x += width + PaneClusterMetrics.segmentGap
        }
        return placed
    }

    /// The pill's total width: the last segment's trailing edge plus the
    /// closing inset. Zero for an empty placement, because a pane with no
    /// segments wears no capsule at all rather than an empty pill.
    public static func pillWidth(for placed: [Placed]) -> Double {
        guard let last = placed.last else { return 0 }
        return last.x + last.width + PaneClusterMetrics.horizontalInset
    }

    /// The segment under `x`, in the pill's own coordinate space. The gap
    /// between segments resolves to nil on purpose: a click there opens
    /// nothing rather than whichever card is nearer.
    public static func segment(at x: Double, in placed: [Placed]) -> PaneClusterSegment? {
        placed.first { x >= $0.x && x < $0.x + $0.width }?.segment
    }
}
