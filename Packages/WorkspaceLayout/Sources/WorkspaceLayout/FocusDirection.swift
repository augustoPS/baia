import Foundation

/// Which way a directional focus move travels, one direction per arrow key.
///
/// Deliberately not `Codable`: a direction is a keystroke, never session state,
/// and a conformance nobody decodes is a conformance nobody keeps correct.
public enum FocusDirection: Sendable, Equatable {
    case left, right, up, down

    /// The split a grow key in this direction is looking for: the axis it has to
    /// cut, which child the pane has to sit in for that split to have a divider
    /// that way, and which way the *first* child's fraction moves.
    ///
    /// `first` is the left/top child, so a pane in `first` growing right pushes
    /// the divider away from the origin and the fraction rises, while a pane in
    /// `second` growing left pulls it back and the fraction falls. Reading the
    /// pair backwards is silent: the divider moves, it moves the wrong way, and
    /// the pane the user was in shrinks instead of growing.
    var growth: (axis: SplitAxis, paneIsFirstChild: Bool, sign: Double) {
        switch self {
        case .left: (axis: .horizontal, paneIsFirstChild: false, sign: -1)
        case .right: (axis: .horizontal, paneIsFirstChild: true, sign: 1)
        case .up: (axis: .vertical, paneIsFirstChild: false, sign: -1)
        case .down: (axis: .vertical, paneIsFirstChild: true, sign: 1)
        }
    }

    /// How far a candidate pane sits from `source` in this direction, or nil when
    /// the candidate is not in this direction at all.
    ///
    /// `gap` is the distance from the source's leading edge to the candidate's
    /// opposite edge, so a pane sharing a divider with the source scores 0 and
    /// the pane behind it scores that pane's whole width. `offset` is how far the
    /// two rects' near edges are apart along the perpendicular axis, which is the
    /// only thing separating two candidates that share the same divider.
    ///
    /// A candidate whose perpendicular span merely touches the source's counts as
    /// no overlap: the pane diagonally across a four-pane grid shares exactly one
    /// corner with the source, and treating that as an overlap would make an
    /// arrow key jump diagonally.
    func reach(from source: LayoutRect, to candidate: LayoutRect) -> (gap: Double, offset: Double)? {
        switch self {
        case .left:
            guard candidate.maxX <= source.x + Self.tolerance,
                  Self.spansOverlap(source.y, source.maxY, candidate.y, candidate.maxY)
            else { return nil }
            return (gap: source.x - candidate.maxX, offset: abs(candidate.y - source.y))
        case .right:
            guard candidate.x + Self.tolerance >= source.maxX,
                  Self.spansOverlap(source.y, source.maxY, candidate.y, candidate.maxY)
            else { return nil }
            return (gap: candidate.x - source.maxX, offset: abs(candidate.y - source.y))
        case .up:
            guard candidate.maxY <= source.y + Self.tolerance,
                  Self.spansOverlap(source.x, source.maxX, candidate.x, candidate.maxX)
            else { return nil }
            return (gap: source.y - candidate.maxY, offset: abs(candidate.x - source.x))
        case .down:
            guard candidate.y + Self.tolerance >= source.maxY,
                  Self.spansOverlap(source.x, source.maxX, candidate.x, candidate.maxX)
            else { return nil }
            return (gap: candidate.y - source.maxY, offset: abs(candidate.x - source.x))
        }
    }

    /// True when two intervals share more than a touching edge.
    private static func spansOverlap(
        _ lower: Double,
        _ upper: Double,
        _ otherLower: Double,
        _ otherUpper: Double
    ) -> Bool {
        lower + tolerance < otherUpper && otherLower + tolerance < upper
    }

    /// The slack allowed when deciding that two edges are the same edge.
    ///
    /// Sized for rounding, not for layout: a pane a billionth of a window wide
    /// does not exist, and the clamp in ``PaneTree`` keeps every pane at least a
    /// twentieth of its parent, so nothing real is inside this tolerance. Without
    /// it, a divider whose coordinate was reached by multiplying ratios in a
    /// different order than its neighbour's can miss the equality by one bit and
    /// an arrow key does nothing.
    private static let tolerance = 1e-9
}
