import Foundation

/// The pane arrangement of one tab: a leaf is a pane, a split is a divider.
///
/// A binary tree rather than a flat list of rects, because closing a pane has to
/// hand its space to exactly one neighbour and the tree is the only record of which
/// one that is. The AppKit layer renders `layout(in:)` and keeps no layout state of
/// its own, so a pane can never be on screen in a position the tree disagrees with.
/// Every operation returns a new tree, which makes "did the layout change" an `==`
/// rather than a diff.
///
/// `ratio` is the *first* child's fraction of that split's own space. The case is
/// public, so a caller can build a split at 0, at 1, or at a non-finite ratio, and
/// `layout(in:)` therefore clamps as it reads instead of trusting what is stored. A
/// pane at ratio 0 is a zero-width live shell: invisible, unreachable by mouse, and
/// still running whatever was in it.
///
/// `Codable` is the compiler's synthesized enum conformance, verified by a round
/// trip for a four-level tree. Hand-written coding keys would need
/// `init(from:) throws` and a `try` per associated value, in a package whose only
/// `try` is the pair of `JSONCoder` calls in ``SessionStore``.
public indirect enum PaneTree: Sendable, Equatable, Codable {
    case leaf(PaneID)
    case split(axis: SplitAxis, ratio: Double, first: PaneTree, second: PaneTree)

    /// Every pane in visual order, first child before second, depth first. That
    /// reads the window left to right and top to bottom, which is the order the
    /// cycle key and any list of a tab's panes follow.
    public var paneIDs: [PaneID] {
        switch self {
        case let .leaf(id):
            return [id]
        case let .split(_, _, first, second):
            return first.paneIDs + second.paneIDs
        }
    }

    /// True when this tree shows `id`.
    ///
    /// Walks `paneIDs` rather than short-circuiting through the tree: a tab holds
    /// a handful of panes, and the flat form is the one every caller here already
    /// needs for something else.
    public func contains(_ id: PaneID) -> Bool {
        paneIDs.contains(id)
    }

    /// Replaces `id`'s leaf with a split holding it and `newPane`, or nil when the
    /// split cannot be made.
    ///
    /// `newPane` becomes the *second* child, so a split lands to the right of or
    /// below the pane it came from, which is what the keys promise: `cmd+d` splits
    /// right and `cmd+shift+d` splits down.
    ///
    /// Nil when `id` is absent, and also nil when `newPane` is already somewhere
    /// in the tree. A duplicated id would make `contains` true for two panes at
    /// once, and then `closing` would remove whichever one it reached first while
    /// the other kept its shell running off screen.
    public func splitting(
        _ id: PaneID,
        axis: SplitAxis,
        newPane: PaneID,
        ratio: Double
    ) -> PaneTree? {
        guard !contains(newPane) else { return nil }
        return splittingLeaf(id, axis: axis, newPane: newPane, ratio: Self.clamped(ratio))
    }

    /// The tree without `id`'s pane, or nil when there would be no pane left.
    ///
    /// Nil also covers an id that is not in the tree, so both answers mean "keep
    /// the tree you have". ``Workspace`` calls `contains` first when it needs to
    /// tell the two apart, because closing the last pane of a tab closes the tab
    /// while a missing id must close nothing at all.
    ///
    /// The parent split collapses and the sibling is promoted into its place,
    /// keeping the grandparent's axis and ratio. A tree that grows a split with
    /// one child would lay out that child at a fraction of the space its pane is
    /// entitled to and leave a divider on screen with nothing on the far side.
    public func closing(_ id: PaneID) -> PaneTree? {
        guard contains(id) else { return nil }
        return removing(id)
    }

    /// Moves the divider of the innermost split that holds `id`, or nil when
    /// there is no such split.
    ///
    /// The innermost one is the divider a drag on that pane's edge grabs. Nil for
    /// a single-pane tree, which has no divider, and nil for an absent id, so a
    /// stale drag that arrives after the pane closed changes nothing.
    public func replacingRatio(forSplitContaining id: PaneID, with ratio: Double) -> PaneTree? {
        switch self {
        case .leaf:
            return nil
        case let .split(axis, existing, first, second):
            if first.contains(id) {
                // A deeper split wins: it is the one closer to the pane, and the
                // outer divider keeps its own ratio so a drag on an inner edge
                // cannot move the whole column.
                if let deeper = first.replacingRatio(forSplitContaining: id, with: ratio) {
                    return .split(axis: axis, ratio: existing, first: deeper, second: second)
                }
                return .split(axis: axis, ratio: Self.clamped(ratio), first: first, second: second)
            }
            guard second.contains(id) else { return nil }
            if let deeper = second.replacingRatio(forSplitContaining: id, with: ratio) {
                return .split(axis: axis, ratio: existing, first: first, second: deeper)
            }
            return .split(axis: axis, ratio: Self.clamped(ratio), first: first, second: second)
        }
    }

    /// Where every pane sits inside `rect`, in visual order.
    ///
    /// No divider thickness is subtracted. A divider is a view the AppKit layer
    /// draws over the boundary, and taking its width out here would make the
    /// model's idea of adjacency depend on a number only the renderer knows.
    public func layout(in rect: LayoutRect) -> [(pane: PaneID, rect: LayoutRect)] {
        switch self {
        case let .leaf(id):
            return [(pane: id, rect: rect)]
        case let .split(axis, ratio, first, second):
            // Clamped here rather than trusted, because a decoded session or a
            // directly constructed case can carry any Double at all and this is
            // the one place the number turns into pixels.
            let fraction = Self.clamped(ratio)
            switch axis {
            case .horizontal:
                let width = rect.width * fraction
                return first.layout(in: LayoutRect(
                    x: rect.x,
                    y: rect.y,
                    width: width,
                    height: rect.height
                )) + second.layout(in: LayoutRect(
                    x: rect.x + width,
                    y: rect.y,
                    width: rect.width - width,
                    height: rect.height
                ))
            case .vertical:
                let height = rect.height * fraction
                return first.layout(in: LayoutRect(
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: height
                )) + second.layout(in: LayoutRect(
                    x: rect.x,
                    y: rect.y + height,
                    width: rect.width,
                    height: rect.height - height
                ))
            }
        }
    }

    /// The pane an arrow key moves to, or nil when there is none that way.
    ///
    /// Resolved against the laid-out rects, not by walking the tree. The two
    /// disagree: in a window whose two columns are split at different heights,
    /// the pane to the right of the bottom-left one is the bottom-right one, while
    /// a tree walk crosses to the right column and takes its first child, which is
    /// the pane at the top. Laying out rects is what makes the arrow keys agree
    /// with what the user can see, and it is the whole reason ``LayoutRect``
    /// exists.
    ///
    /// The winner is the candidate with the smallest gap along the direction of
    /// travel whose perpendicular span overlaps the source's. Ties on the gap go
    /// to the smallest perpendicular offset, and ties on both go to the earlier
    /// pane in visual order, so the answer never depends on iteration luck.
    ///
    /// The overlap half of that rule is what keeps it independent of the layout
    /// being a tiling. Inside a tiling it never changes the winner on its own: the
    /// pane holding the source's leading corner ties on the gap and wins on the
    /// offset regardless. So it is exercised directly against
    /// ``FocusDirection/reach(from:to:)``, where a hand-built pair of rects can
    /// sit diagonally, rather than through a tree that cannot produce that case.
    public func neighbour(of id: PaneID, direction: FocusDirection, in rect: LayoutRect) -> PaneID? {
        let placed = layout(in: rect)
        guard let source = placed.first(where: { $0.pane == id })?.rect else { return nil }

        var best: (pane: PaneID, gap: Double, offset: Double)?
        for candidate in placed where candidate.pane != id {
            guard let reach = direction.reach(from: source, to: candidate.rect) else { continue }
            guard let current = best else {
                best = (pane: candidate.pane, gap: reach.gap, offset: reach.offset)
                continue
            }
            // Strictly better, so an equal candidate later in visual order loses
            // and the tie-break stays the pane order rather than the array order
            // happening to match it.
            if reach.gap < current.gap || (reach.gap == current.gap && reach.offset < current.offset) {
                best = (pane: candidate.pane, gap: reach.gap, offset: reach.offset)
            }
        }
        return best?.pane
    }

    /// The next pane in visual order, wrapping past the last.
    ///
    /// Nil when `id` is not in the tree, and nil when it is the only pane, so a
    /// caller cannot mistake "wrapped around to where it started" for a move it
    /// should show.
    public func pane(after id: PaneID) -> PaneID? {
        let ids = paneIDs
        guard ids.count > 1, let index = ids.firstIndex(of: id) else { return nil }
        return ids[(index + 1) % ids.count]
    }

    /// The previous pane in visual order, wrapping past the first.
    public func pane(before id: PaneID) -> PaneID? {
        let ids = paneIDs
        guard ids.count > 1, let index = ids.firstIndex(of: id) else { return nil }
        return ids[(index + ids.count - 1) % ids.count]
    }

    /// The subtree that shares a divider with `id`'s pane, which is the subtree
    /// that grows into its space when it closes. Nil when the pane is the root
    /// leaf, and nil when it is not in the tree.
    ///
    /// ``Workspace`` needs this to decide where focus lands after a close, and it
    /// has to ask before the close rather than after, since the sibling is
    /// indistinguishable from the rest of the tree once it has been promoted.
    func sibling(of id: PaneID) -> PaneTree? {
        guard case let .split(_, _, first, second) = self else { return nil }
        if first == .leaf(id) { return second }
        if second == .leaf(id) { return first }
        return first.sibling(of: id) ?? second.sibling(of: id)
    }

    /// Rebuilds the spine down to `id`'s leaf, splitting it in two. Nil when no
    /// leaf on the way holds `id`.
    private func splittingLeaf(
        _ id: PaneID,
        axis: SplitAxis,
        newPane: PaneID,
        ratio: Double
    ) -> PaneTree? {
        switch self {
        case let .leaf(existing):
            guard existing == id else { return nil }
            return .split(axis: axis, ratio: ratio, first: .leaf(existing), second: .leaf(newPane))
        case let .split(splitAxis, splitRatio, first, second):
            if let replaced = first.splittingLeaf(id, axis: axis, newPane: newPane, ratio: ratio) {
                return .split(axis: splitAxis, ratio: splitRatio, first: replaced, second: second)
            }
            guard let replaced = second.splittingLeaf(id, axis: axis, newPane: newPane, ratio: ratio)
            else { return nil }
            return .split(axis: splitAxis, ratio: splitRatio, first: first, second: replaced)
        }
    }

    /// Nil when the whole of this subtree goes away, which is how a parent learns
    /// to promote the other child in its own place.
    private func removing(_ id: PaneID) -> PaneTree? {
        switch self {
        case let .leaf(existing):
            return existing == id ? nil : self
        case let .split(axis, ratio, first, second):
            if first.contains(id) {
                guard let remaining = first.removing(id) else { return second }
                return .split(axis: axis, ratio: ratio, first: remaining, second: second)
            }
            guard let remaining = second.removing(id) else { return first }
            return .split(axis: axis, ratio: ratio, first: first, second: remaining)
        }
    }

    /// The interior range a split's first fraction is held to.
    ///
    /// 0.05 rather than 0, because a pane at 0 is a live shell with no width:
    /// nothing to click, nothing to see, and a process still running in it. That
    /// is the same class of bug as the 1x32 window sliver this project already
    /// shipped once. At 0.05 of a 1400 point window a pane is 70 points wide,
    /// small but visible, and the divider is still there to drag back.
    ///
    /// The clamp bounds one divider, not a chain of them: five nested splits at
    /// 0.05 still reach three points. Only a minimum pane size in points can stop
    /// that, and a model with no idea what a point is has nothing to compare
    /// against, so per split is as far as this can go.
    private static let ratioRange = 0.05 ... 0.95

    /// Holds a stored or incoming fraction inside ``ratioRange``.
    ///
    /// A non-finite ratio resets to an even split rather than clamping. Clamping
    /// would not even work, since `min` and `max` propagate NaN and both children
    /// would end up with a NaN size, which lays out as nothing at all. JSON has
    /// no NaN or Infinity literal, so a non-finite ratio never arrives from a
    /// decoded session: it arrives from a caller building the case by hand, where
    /// the intent is a mistake rather than an extreme worth honouring.
    private static func clamped(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }
}
