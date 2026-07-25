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
        while kept.count > 1, !fits(kept, widths: widths, in: content) {
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

    /// True when everything in `kept` fits side by side with one spacing gap
    /// between neighbours.
    ///
    /// Negative measurements are clamped before they are summed. A caller that
    /// measured an empty attributed string, or one whose font failed to load,
    /// can hand back a negative width, and a negative summand would make an
    /// overflowing bar report as fitting.
    private static func fits(_ kept: [Int], widths: [Double], in content: Double) -> Bool {
        guard !kept.isEmpty else { return true }
        let total = kept.reduce(0.0) { $0 + max(0, widths[$1]) }
        let gaps = PaneStatusBarMetrics.segmentSpacing * Double(kept.count - 1)
        return total + gaps <= content
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

        for index in kept where segments[index].alignment == .leading {
            let width = clamped(widths[index], to: content)
            leadingPlaced.append(.init(segment: segments[index], x: leadingEdge, width: width))
            leadingEdge += width + PaneStatusBarMetrics.segmentSpacing
        }

        // The trailing cluster is measured right to left, walking `kept`
        // backwards, so the last trailing segment lands against the right edge
        // and the cluster still reads in array order on screen. Measuring it
        // forwards would put the working directory to the left of the agent
        // label, which is the opposite of the table it was built from.
        for index in kept.reversed() where segments[index].alignment == .trailing {
            let width = clamped(widths[index], to: content)
            trailingEdge -= width
            trailingPlaced.append(.init(segment: segments[index], x: trailingEdge, width: width))
            trailingEdge -= PaneStatusBarMetrics.segmentSpacing
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
