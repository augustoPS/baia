import Foundation

/// Where every surviving segment goes, and which ones did not survive.
public struct PaneStatusLayoutResult: Sendable, Equatable {
    /// One segment and its rectangle along the bar. The vertical extent is
    /// ``PaneStatusBarMetrics/height`` for every segment, so it is not repeated
    /// here.
    public struct Placed: Sendable, Equatable {
        public var segment: PaneStatusSegment
        public var x: Double
        public var width: Double

        public init(segment: PaneStatusSegment, x: Double, width: Double) {
            self.segment = segment
            self.x = x
            self.width = width
        }
    }

    /// Ordered left to right, so a caller can draw straight through it and get
    /// the bar as it reads.
    public var placed: [Placed]

    /// In the order they arrived, not the order they were dropped. The app shows
    /// them in the pane's tooltip, where the bar's own order is the one the owner
    /// recognises.
    public var dropped: [PaneStatusSegment]

    public init(placed: [Placed], dropped: [PaneStatusSegment]) {
        self.placed = placed
        self.dropped = dropped
    }
}

/// Fits segments into a bar of a known width, dropping the least useful ones.
public enum PaneStatusLayout {
    /// `widths` is parallel to `segments`, measured by the caller with the real
    /// font. A mismatched count returns an empty result rather than trapping,
    /// because a measurement bug must not crash the app.
    public static func solve(
        segments: [PaneStatusSegment],
        widths: [Double],
        availableWidth: Double
    ) -> PaneStatusLayoutResult {
        guard segments.count == widths.count else {
            return PaneStatusLayoutResult(placed: [], dropped: [])
        }

        let content = availableWidth - PaneStatusBarMetrics.horizontalInset * 2

        // A bar narrower than its own insets has nowhere to draw. Everything is
        // reported dropped rather than placed at a negative width, which is the
        // state a pane passes through while the split view animates a divider to
        // the edge.
        guard content > 0 else {
            return PaneStatusLayoutResult(placed: [], dropped: segments)
        }

        var kept = Array(segments.indices)

        // Stops at one segment rather than at zero. A single segment wider than
        // the whole bar is placed and truncated, because a bar with nothing in it
        // is worse than a clipped project name.
        while kept.count > 1, !fits(kept, segments: segments, widths: widths, in: content) {
            kept.remove(at: positionOfWeakest(in: kept, segments: segments))
        }

        return place(
            kept,
            segments: segments,
            widths: widths,
            availableWidth: availableWidth,
            content: content
        )
    }

    /// True when everything in `kept` fits side by side with the gap each pair of
    /// neighbours actually calls for.
    ///
    /// The gaps are summed rather than multiplied out. With one spacing constant
    /// `spacing × (n − 1)` was the same number; with a tight gap inside a group
    /// and a wide one between two, it is not, and a solver that assumed either
    /// constant would either drop a segment that fitted or place one past the
    /// inset. Which of those two you get would depend on how many groups happened
    /// to survive, so it would show up as a bar that overflows only on the panes
    /// carrying the most state.
    ///
    /// Negative measurements are clamped before they are summed. A caller that
    /// measured an empty attributed string, or one whose font failed to load,
    /// can hand back a negative width, and a negative summand would make an
    /// overflowing bar report as fitting.
    private static func fits(
        _ kept: [Int],
        segments: [PaneStatusSegment],
        widths: [Double],
        in content: Double
    ) -> Bool {
        guard !kept.isEmpty else { return true }
        let total = kept.reduce(0.0) { $0 + max(0, widths[$1]) }
        return total + totalGaps(kept, segments: segments) <= content
    }

    /// The sum of the gaps between neighbouring survivors, in array order.
    ///
    /// Array order spans the leading and trailing clusters once, at the boundary
    /// between them. That pair is always two different groups, so it contributes
    /// the wide gap, which is the guarantee ``place(_:segments:widths:availableWidth:content:)``
    /// relies on when it concatenates the two clusters instead of sorting them.
    private static func totalGaps(_ kept: [Int], segments: [PaneStatusSegment]) -> Double {
        zip(kept, kept.dropFirst()).reduce(0.0) { sum, pair in
            sum + PaneStatusBarMetrics.spacing(
                from: segments[pair.0].group,
                to: segments[pair.1].group
            )
        }
    }

    /// The position *in `kept`* of the segment to drop next: the lowest priority,
    /// and on a tie the greatest index into `segments`.
    ///
    /// The tie is broken by hand rather than by sorting on a priority key.
    /// `Array.sort` is not documented as stable, so a sort-based drop order could
    /// take two segments that share a priority in either order, and a bar whose
    /// pin vanishes on one launch and whose rebase label vanishes on the next is
    /// a bar nobody can learn to read.
    private static func positionOfWeakest(in kept: [Int], segments: [PaneStatusSegment]) -> Int {
        var weakest = 0
        for position in kept.indices.dropFirst() {
            // `kept` is ascending, so taking the later position on an equal
            // priority is exactly the greatest-index rule.
            if segments[kept[position]].priority <= segments[kept[weakest]].priority {
                weakest = position
            }
        }
        return weakest
    }

    /// Lays the survivors out from both edges inwards.
    private static func place(
        _ kept: [Int],
        segments: [PaneStatusSegment],
        widths: [Double],
        availableWidth: Double,
        content: Double
    ) -> PaneStatusLayoutResult {
        var leadingPlaced: [PaneStatusLayoutResult.Placed] = []
        var trailingPlaced: [PaneStatusLayoutResult.Placed] = []
        var leadingEdge = PaneStatusBarMetrics.horizontalInset
        var trailingEdge = availableWidth - PaneStatusBarMetrics.horizontalInset

        // Each cluster is gathered before it is placed, because the gap after a
        // segment now depends on which segment comes next. Advancing by a
        // constant and correcting later would put the correction in a different
        // place from the measurement in `fits`, and the two have to agree exactly.
        let leading = kept.filter { segments[$0].alignment == .leading }
        for (position, index) in leading.enumerated() {
            let width = clamped(widths[index], to: content)
            leadingPlaced.append(.init(segment: segments[index], x: leadingEdge, width: width))
            leadingEdge += width
            guard position + 1 < leading.count else { continue }
            leadingEdge += PaneStatusBarMetrics.spacing(
                from: segments[index].group,
                to: segments[leading[position + 1]].group
            )
        }

        // The trailing cluster is measured right to left, so the last trailing
        // segment lands against the right edge and the cluster still reads in
        // array order on screen. Measuring it forwards would put the working
        // directory to the left of the agent label, which is the opposite of the
        // table it was built from.
        let trailing = Array(kept.filter { segments[$0].alignment == .trailing }.reversed())
        for (position, index) in trailing.enumerated() {
            let width = clamped(widths[index], to: content)
            trailingEdge -= width
            trailingPlaced.append(.init(segment: segments[index], x: trailingEdge, width: width))
            // The neighbour to the left is the next one in this reversed walk, so
            // the gap is measured from its group to this one, keeping the pair in
            // the same order `fits` summed them in.
            guard position + 1 < trailing.count else { continue }
            trailingEdge -= PaneStatusBarMetrics.spacing(
                from: segments[trailing[position + 1]].group,
                to: segments[index].group
            )
        }

        let keptIndices = Set(kept)
        let dropped = segments.indices
            .filter { !keptIndices.contains($0) }
            .map { segments[$0] }

        // Concatenated rather than sorted on `x`. `fits` guarantees a whole
        // spacing gap between the two clusters, so leading rectangles are all to
        // the left of trailing ones, and concatenation cannot be perturbed by an
        // unstable sort the way two zero-width segments at the same `x` could be.
        return PaneStatusLayoutResult(
            placed: leadingPlaced + trailingPlaced.reversed(),
            dropped: dropped
        )
    }

    /// A measured width made safe to draw with: never negative, never wider than
    /// the bar's content box. The upper clamp is what truncates the last
    /// surviving segment instead of letting it run out past the inset.
    private static func clamped(_ width: Double, to content: Double) -> Double {
        min(max(0, width), content)
    }
}
