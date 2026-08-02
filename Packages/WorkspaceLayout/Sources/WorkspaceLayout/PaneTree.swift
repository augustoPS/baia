import Foundation

/// Which child to descend into at each step from the root of a ``PaneTree``.
/// `0` is the first child, `1` the second, and the empty path names the root.
///
/// The only way to name one split rather than one pane. Every other mutator here
/// is pane-keyed, and pane-keyed addressing cannot express a drag: the divider
/// between a pane and a nested column belongs to the outer split, while
/// ``PaneTree/replacingRatio(forSplitContaining:with:)`` deliberately resolves to
/// the innermost split holding that pane. Moving the wrong one resizes two panes
/// the user never touched.
///
/// A path is only valid against the tree it was derived from. Nothing renumbers
/// it, because every structural change tears the view hierarchy down and builds a
/// fresh set of controllers, each handed the path it has under the new tree.
public struct SplitPath: Hashable, Sendable, Codable {
    public var indices: [Int]

    public init(_ indices: [Int] = []) {
        self.indices = indices
    }

    public func appending(_ index: Int) -> SplitPath {
        SplitPath(indices + [index])
    }
}

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
        return splittingLeaf(id, axis: axis, newPane: newPane, ratio: Self.clampedRatio(ratio))
    }

    /// The tree with `id`'s pane taken out of where it sits and put back beside
    /// `target`, or nil when that describes nothing.
    ///
    /// **The pane keeps its id, and that is the whole operation.** Nothing is
    /// created and nothing is closed, so `paneIDs` holds the same set before and
    /// after and the caller's map of id to surface still answers. Spelled as a
    /// ``closing(_:)`` and a ``splitting(_:axis:newPane:ratio:)`` at the layer
    /// above, the pane would come back with a fresh id, and a fresh id is a fresh
    /// surface: the shell in it dies. Here the id is the one thing that does not
    /// move.
    ///
    /// The vacated split collapses exactly as ``closing(_:)`` collapses it, ratio
    /// and all, because it is the same walk. The new split is built at a half,
    /// which is the ratio every split the app makes starts at; the ratio of the
    /// split that collapsed is gone, and inventing a use for it here would make a
    /// move somewhere else change a divider the user set.
    ///
    /// `before` puts the pane on the near side of `target` rather than the far
    /// one. ``splitting(_:axis:newPane:ratio:)`` has no such choice because a
    /// split is always the pane the caller is looking at plus a new one to its
    /// right or below; a move names both ends, so both sides are expressible.
    ///
    /// Nil covers every request that cannot mean anything, and they are all one
    /// answer because a caller spends them the same way, by changing nothing:
    /// either pane absent from this tree, which is also how a pane in another tab
    /// reads; the same pane named twice; and a move whose result is the tree it
    /// started from. That last one is nil for ``replacingRatio(at:with:)``'s
    /// reason turned up: a structural change costs a rebuild, which reparents
    /// every live surface in the window and is a `SIGWINCH` to whatever is running
    /// in each of them. Spending that to arrive where we already are is worse than
    /// saying no.
    public func moving(
        _ id: PaneID,
        beside target: PaneID,
        axis: SplitAxis,
        before: Bool
    ) -> PaneTree? {
        guard id != target, contains(id), contains(target) else { return nil }
        // Non-nil by construction: `target` is in the tree and is not `id`, so
        // something is left after the removal. The guard is here rather than a
        // force unwrap because the alternative is trusting that argument at a
        // call site that has no way to check it.
        guard let vacated = removing(id) else { return nil }
        guard let moved = vacated.splittingLeaf(
            target,
            axis: axis,
            newPane: id,
            ratio: 0.5,
            before: before
        ) else { return nil }
        guard moved != self else { return nil }
        return moved
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
                return .split(axis: axis, ratio: Self.clampedRatio(ratio), first: first, second: second)
            }
            guard second.contains(id) else { return nil }
            if let deeper = second.replacingRatio(forSplitContaining: id, with: ratio) {
                return .split(axis: axis, ratio: existing, first: first, second: deeper)
            }
            return .split(axis: axis, ratio: Self.clampedRatio(ratio), first: first, second: second)
        }
    }

    /// The fraction the split at `path` lays out at, or nil when the path names a
    /// leaf, runs off the bottom of the tree, or steps to a child a split does not
    /// have.
    ///
    /// Clamped rather than raw, because a caller reads this to compare against a
    /// fraction measured on screen and ``layout(in:)`` clamps as it draws. Handing
    /// back a stored 0.99 would say the divider had moved when it had not.
    public func ratio(at path: SplitPath) -> Double? {
        ratio(descending: path.indices[...])
    }

    /// The tree with the split at `path` moved to `ratio`, or nil when nothing
    /// should be persisted.
    ///
    /// Nil covers the two cases a caller treats the same way, since both mean
    /// "persist nothing": the path names no split, and the clamped value is the
    /// one the split already carries. The clamp is the
    /// same ``clampedRatio(_:)`` the view layer applies before it reports a drag,
    /// so a divider dragged past 0.95 settles where the model says it is instead of
    /// being yanked back on some later layout pass.
    public func replacingRatio(at path: SplitPath, with ratio: Double) -> PaneTree? {
        replacingRatio(descending: path.indices[...], with: Self.clampedRatio(ratio))
    }

    /// The tree with the divider a grow key touches moved by `delta`, or nil when
    /// that key moves nothing.
    ///
    /// `delta` is a fraction of the governing split's own thickness, never points.
    /// This type has no idea what a point is, and a step in points would move a
    /// nested divider by a larger share of its split than the root one by the same
    /// key, which reads as the key doing more work in a small pane than a large
    /// one.
    ///
    /// Nil covers every case a caller treats the same way, since all of them mean
    /// "persist nothing and push nothing": the pane is not in the tree, no split
    /// on its path has a divider that way, and the divider is already against the
    /// clamp. A refusal at the clamp deliberately does *not* fall back to a
    /// shallower split. Moving an ancestor once the near divider has stopped would
    /// resize two panes the user never pointed at, which is the same failure the
    /// deepest-split rule exists to prevent.
    public func adjustingRatio(
        forPane id: PaneID,
        direction: FocusDirection,
        by delta: Double
    ) -> PaneTree? {
        guard let path = governingSplit(for: id, direction: direction),
              let current = ratio(at: path)
        else { return nil }
        // `ratio(at:)` hands back the clamped value and `replacingRatio(at:with:)`
        // clamps again on the way in, so every ratio a held key can ever write is
        // one ``clampedRatio(_:)`` already admits. A keyboard resize therefore
        // reaches no arrangement a mouse drag could not, which is what keeps it
        // clear of the layout loop `PaneSplitController.reachablePosition(in:)`
        // guards against.
        return replacingRatio(at: path, with: current + direction.growth.sign * delta)
    }

    /// The same tree with every pane given the same share of the window.
    ///
    /// **Not every split at a half, which is what this did until 2026-07-31 and is
    /// not the same thing.** A tree is binary and a row of three panes is not: three
    /// on a spine nest as `a | (b | c)`, so halving every split gave a half, a
    /// quarter and a quarter. The owner pressed the key on exactly that arrangement
    /// and got back the shape it was meant to undo.
    ///
    /// Each split takes the share of the *slots along its own axis* that sit in the
    /// first child, where a subtree that splits the other way is one slot however
    /// many panes it holds. Three side by side come out at a third and then a half,
    /// so every column is a third wide.
    ///
    /// **Slots, not leaves, and the difference is the whole rule.** Weighting by
    /// leaves gives every pane the same area, which sounds like the same thing and
    /// looks nothing like it: a column of three beside two single panes comes out
    /// three times as wide as either of them, since its area has to cover three
    /// panes. Tried on 2026-07-31 and rejected on sight. What the key is for is
    /// evening out siblings, and a column is one sibling.
    ///
    /// So a tall pane beside a column of two is halves, and the column divides its
    /// own half between its two. Every row divides evenly among the things in that
    /// row, and every column among the things in that column, which is the grid a
    /// window of panes reads as.
    ///
    /// Axes and pane order are untouched: this is the "put it back" key, not a
    /// reshuffle, and a user who presses it expects the panes to stay where they
    /// are and only the dividers to move.
    ///
    /// A ratio outside ``clampedRatio(_:)``'s range needs nineteen slots on one side
    /// of a split to reach, and ``layout(in:)`` clamps on the way to pixels like it
    /// does for every other ratio. What that costs is the pane on the short side
    /// keeping a twentieth rather than shrinking further, which is the clamp doing
    /// its job rather than this rule failing.
    public var equalized: PaneTree {
        guard case let .split(axis, _, first, second) = self else { return self }
        let head = first.slotCount(along: axis)
        let share = Double(head) / Double(head + second.slotCount(along: axis))
        return .split(axis: axis, ratio: share, first: first.equalized, second: second.equalized)
    }

    /// How many things this subtree contributes to a row or column running `axis`.
    ///
    /// A leaf is one. A split the same way is however many its two sides
    /// contribute, since its own divider is another divider in that same row. A
    /// split the *other* way is one, however deep it goes: it is a column sitting in
    /// a row, and what is inside it is that column's business.
    ///
    /// That last case is what makes ``equalized`` even out siblings rather than
    /// panes, and it is the only place in this type where an axis decides how far a
    /// walk goes.
    func slotCount(along axis: SplitAxis) -> Int {
        switch self {
        case .leaf:
            return 1
        case let .split(own, _, first, second):
            guard own == axis else { return 1 }
            return first.slotCount(along: axis) + second.slotCount(along: axis)
        }
    }

    /// How far a divider moves at full speed, as a fraction of that split's own
    /// thickness.
    ///
    /// **No longer what one press of a grow key moves.** ``KeyboardResizeRamp``
    /// makes the arrow keys start at a cell and reach this in four repeats, because
    /// a constant this size read as four-column steps rather than as a resize. What
    /// still moves by exactly this is `baia resize`, which takes it as the verb's
    /// default and as the floor under a caller's `--by`: a channel client sends one
    /// message per move and has no key to hold.
    ///
    /// The reasoning below is what the ramp's plateau was chosen to keep, and it is
    /// left as it was written.
    ///
    /// Chosen against two failures at once. Too large and a single tap is
    /// unusable: at 0.05 one press moves the root divider of a 1400 point window
    /// 70 points, about eight terminal columns, and a held key crosses from the
    /// centre to the stop in nine presses, well under a second at the default
    /// repeat rate. Too small and the key is useless held down: one terminal cell
    /// per press, which is what tmux does in points, would be about 0.006 here and
    /// seventy-five presses to cross. At 0.025 one press is roughly four columns
    /// of that same window and the full range is eighteen presses, a second and a
    /// half of holding.
    ///
    /// It also divides ``clampedRatio(_:)``'s range from a half exactly, so a held
    /// key lands *on* the stop rather than a step short of it with a remainder it
    /// can never spend.
    public static let keyboardResizeStep = 0.025

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
            let fraction = Self.clampedRatio(ratio)
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

    /// Which bottom corners of `rect` each pane sits in, for every pane.
    ///
    /// Read off ``layout(in:)`` rather than walked, for the same reason
    /// ``neighbour(of:direction:in:)`` is: the tree and the picture disagree. A
    /// walk would have to decide what "the last child on the bottom right" means
    /// through a chain of splits on alternating axes, and in a window whose
    /// columns are split at different heights it would name a pane the user can
    /// see is not in the corner. The rects already say it in one comparison.
    ///
    /// Every pane is a key, including the ones that own nothing, so a caller
    /// pushing a value per pane never has to decide what a missing key meant.
    public func bottomCorners(in rect: LayoutRect = .unit) -> [PaneID: BottomCorners] {
        // A fraction of the container rather than a fixed distance, because the
        // rects are built by multiplying ratios and the error grows with the
        // numbers, not with the units. Unit-rect callers and point-rect callers
        // then get the same answer, which is what
        // `theAnswerDoesNotDependOnTheSizeOfTheWindow` pins.
        let horizontal = abs(rect.width) * Self.edgeTolerance
        let vertical = abs(rect.height) * Self.edgeTolerance

        var owned: [PaneID: BottomCorners] = [:]
        for placed in layout(in: rect) {
            var corners: BottomCorners = []
            // The bottom edge first: a pane on a side but not the bottom row
            // meets no corner, and neither does one on the bottom row but in the
            // middle. Both halves have to hold.
            if abs(placed.rect.maxY - rect.maxY) <= vertical {
                if abs(placed.rect.x - rect.x) <= horizontal { corners.insert(.left) }
                if abs(placed.rect.maxX - rect.maxX) <= horizontal { corners.insert(.right) }
            }
            owned[placed.pane] = corners
        }
        return owned
    }

    /// Which bottom corners of `rect` one pane sits in, or nothing when it is not
    /// in the tree.
    ///
    /// Nothing rather than nil for an absent pane, because the two answers are
    /// spent the same way: a stale id arriving after its pane closed rounds no
    /// corner, which is what an id in the middle of the window gets too.
    public func bottomCorners(of id: PaneID, in rect: LayoutRect = .unit) -> BottomCorners {
        bottomCorners(in: rect)[id] ?? []
    }

    /// How far off an edge a pane may land and still be counted as touching it,
    /// as a fraction of the container.
    ///
    /// A split at a third puts the far edge of the last pane a few units in the
    /// last place away from the container's, and an `==` would take the corner
    /// off the pane that visibly owns it. The value is nine orders of magnitude
    /// above that drift and three below the smallest gap the layout can produce
    /// (``ratioRange``'s 0.05 nested twice is 0.0025 of the window, three and a
    /// half points of a 1400 pt one), so it cannot swallow a gap anyone could
    /// see.
    private static let edgeTolerance = 1e-9

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

    /// Walks the remaining steps. An `ArraySlice` rather than a fresh `Array` per
    /// level, so descending costs nothing beyond the recursion itself.
    private func ratio(descending steps: ArraySlice<Int>) -> Double? {
        guard case let .split(_, ratio, first, second) = self else { return nil }
        guard let step = steps.first else { return Self.clampedRatio(ratio) }
        switch step {
        case 0: return first.ratio(descending: steps.dropFirst())
        case 1: return second.ratio(descending: steps.dropFirst())
        // A split has exactly two children, so any other index names nothing.
        // Falling back to one of them would move a divider the caller did not ask
        // about.
        default: return nil
        }
    }

    /// Rebuilds the spine down to the named split. `ratio` arrives clamped, so it
    /// is not clamped again per level.
    private func replacingRatio(descending steps: ArraySlice<Int>, with ratio: Double) -> PaneTree? {
        guard case let .split(axis, existing, first, second) = self else { return nil }
        guard let step = steps.first else {
            // Nil rather than an identical tree, so a click that ended a drag
            // without moving the divider does not write the session file. A stored
            // value outside the range is not equal to any clamped one, so it gets
            // normalised here rather than kept.
            guard ratio != existing else { return nil }
            return .split(axis: axis, ratio: ratio, first: first, second: second)
        }
        switch step {
        case 0:
            guard let replaced = first.replacingRatio(descending: steps.dropFirst(), with: ratio)
            else { return nil }
            return .split(axis: axis, ratio: existing, first: replaced, second: second)
        case 1:
            guard let replaced = second.replacingRatio(descending: steps.dropFirst(), with: ratio)
            else { return nil }
            return .split(axis: axis, ratio: existing, first: first, second: replaced)
        default:
            return nil
        }
    }

    /// The split a grow key on `id` moves: the deepest one on the path from here
    /// to that pane whose axis matches the direction and that has its divider on
    /// the side the pane is growing towards. Nil when the path holds no such
    /// split, which is what the leftmost pane growing left is.
    ///
    /// Deepest, not first, and that is the whole rule. A pane can sit in `first`
    /// of an inner split and in `second` of the root at the same axis, so both
    /// qualify for opposite directions and the root qualifies for one of the ones
    /// the inner split also does. The deepest match is the divider actually
    /// touching the pane's edge; the root is a divider somewhere across the
    /// window, and moving it resizes panes the user cannot even see from here.
    ///
    /// Deeper wins by recursing before this level is considered. Anything between
    /// the pane and a matching split either has a different axis, which leaves the
    /// pane spanning that sub-region and still touching this divider, or shares
    /// the axis and is itself a match, in which case it is the deeper one.
    private func governingSplit(
        for id: PaneID,
        direction: FocusDirection,
        at path: SplitPath = SplitPath()
    ) -> SplitPath? {
        guard case let .split(axis, _, first, second) = self else { return nil }
        let paneIsFirstChild: Bool
        if first.contains(id) {
            paneIsFirstChild = true
        } else if second.contains(id) {
            paneIsFirstChild = false
        } else {
            // Neither child holds the pane, so nothing below here can, and a
            // grow key that arrived after its pane closed moves no divider at
            // all rather than the nearest one.
            return nil
        }

        let child = paneIsFirstChild ? first : second
        let step = paneIsFirstChild ? 0 : 1
        if let deeper = child.governingSplit(for: id, direction: direction, at: path.appending(step)) {
            return deeper
        }

        let growth = direction.growth
        guard axis == growth.axis, paneIsFirstChild == growth.paneIsFirstChild else { return nil }
        return path
    }

    /// Rebuilds the spine down to `id`'s leaf, splitting it in two. Nil when no
    /// leaf on the way holds `id`.
    ///
    /// **At the leaf and never at its parent**, which is the rule ``moving(_:beside:axis:before:)``
    /// leans on hardest. A pane whose parent split already runs the asked-for axis
    /// makes it tempting to hang the newcomer off that parent instead, which reads
    /// the same on screen for two panes and is a different tree: the pane lands
    /// beside the parent's *other child*, a whole column rather than the one leaf
    /// the caller named, and the move can no longer be undone by naming panes.
    ///
    /// - Parameter before: which side of `id` the new pane takes. False is what a
    ///   split means, the new pane second, so `⌘D` and `baia split --right` land
    ///   to the right and below. Only a move names the other side.
    private func splittingLeaf(
        _ id: PaneID,
        axis: SplitAxis,
        newPane: PaneID,
        ratio: Double,
        before: Bool = false
    ) -> PaneTree? {
        switch self {
        case let .leaf(existing):
            guard existing == id else { return nil }
            return before
                ? .split(axis: axis, ratio: ratio, first: .leaf(newPane), second: .leaf(existing))
                : .split(axis: axis, ratio: ratio, first: .leaf(existing), second: .leaf(newPane))
        case let .split(splitAxis, splitRatio, first, second):
            if let replaced = first.splittingLeaf(
                id, axis: axis, newPane: newPane, ratio: ratio, before: before
            ) {
                return .split(axis: splitAxis, ratio: splitRatio, first: replaced, second: second)
            }
            guard let replaced = second.splittingLeaf(
                id, axis: axis, newPane: newPane, ratio: ratio, before: before
            ) else { return nil }
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
    /// Public because the view layer has to clamp with the *same* function before
    /// it settles a finished drag. Clamping in only one of the two places stores
    /// 0.95 while the divider sits at 0.98, and the divider then jumps on whatever
    /// later layout pass happens to notice, which is a worse bug than the one that
    /// made this necessary.
    ///
    /// A non-finite ratio resets to an even split rather than clamping. Clamping
    /// would not even work, since `min` and `max` propagate NaN and both children
    /// would end up with a NaN size, which lays out as nothing at all. JSON has
    /// no NaN or Infinity literal, so a non-finite ratio never arrives from a
    /// decoded session: it arrives from a caller building the case by hand, where
    /// the intent is a mistake rather than an extreme worth honouring.
    public static func clampedRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }
}
