/// Where a divider can sit for a stored ratio given the drawn thickness and both
/// minimums, and whether this split should keep asking AppKit for it.
///
/// The decision, not the divider. `PaneSplitController` keeps the AppKit half:
/// the drag guard, reading bounds, `setPosition`, and measuring whether the
/// request landed.
public struct SplitSeat: Equatable, Sendable {
    /// The narrowest either pane may be, in points, and therefore how close to an
    /// edge a divider can ever sit. A pane narrower than this cannot show a
    /// useful terminal, and a pane at zero width is an invisible live shell.
    ///
    /// Shared with the items rather than written only there, because a ratio
    /// whose position falls inside this margin is a target `NSSplitView` will
    /// refuse, and asking for it again on every layout pass is a loop the process
    /// does not survive.
    public static let minimumPaneThickness: Double = 96

    /// Three, which is generous for something that either lands or does not.
    public static let refusalLimit = 3

    /// A half point of tolerance. Reassigning the position on every layout
    /// pass would fight the user's own divider drag, since a drag triggers
    /// the layout that would immediately undo it.
    public static let tolerance = 0.5

    /// How many times running this split has asked for a position and not been
    /// given it, and the thickness those asks were made at.
    ///
    /// **The loop is asking forever, not asking wrongly, and a bound is the only
    /// guard that needs to know nothing about why.** ``reachablePosition(thickness:ratio:dividerThickness:)``
    /// decides what to ask for; whether AppKit grants it depends on the minimums of
    /// everything nested below. Two attempts at computing those from this side were
    /// both wrong: the first took a subtree's minimum to be one pane's 96 points,
    /// the second counted panes along this axis and still returned 96 for a column,
    /// which holds only when every row in that column is a single pane. A model of
    /// AppKit's constraint solver that is close is still a model that spins.
    ///
    /// A third attempt remembered the exact position refused and skipped that one
    /// ask. Construction defeated it in a minute: the thickness changes on every
    /// pass while the hierarchy is still being built, so the pair never repeated and
    /// nothing was ever suppressed. The count does not care. Three refusals at one
    /// size and this split stops asking until something deliberate happens.
    ///
    /// Deliberate is a new size or a new ratio. A resize resets the count, because a
    /// position that was impossible at one width may be fine at another, and
    /// ``ratioChanged()`` resets it because the owner asking for something is worth
    /// three more attempts. Everything else, including every layout pass a refusal
    /// itself provokes, is bounded.
    ///
    /// Caught on 2026-07-31 by instrumenting the shipped app after five probe cases
    /// failed to reproduce it: 3,560 identical lines, `[1, 0]` at thickness 671
    /// asking for 335.5 and being given something else, every pass until AppKit gave
    /// up on the update-constraints count.
    ///
    /// The least a side can be given along this split's axis is **not 96 points,
    /// which is what this took it to be until 2026-07-31 and is the whole of that
    /// day's crash.** A side holding a spine of three panes needs three minimums
    /// and the two dividers between them, so a position that leaves it 145 points
    /// is one `NSSplitView` refuses however legal it looks here. The refusal is
    /// invisible from this side: `setPosition` returns, `current` never reaches
    /// `target`, and the next layout pass asks for the same number again. The app
    /// was caught doing that 16,769 times in a row before AppKit gave up on the
    /// update-constraints pass count.
    ///
    /// Counted through the view hierarchy rather than the tree, because the
    /// controller has no tree: it is handed a ratio and a path and knows only what
    /// is beneath it. A child split the *other* way is one slot however deep it
    /// goes, for the reason ``PaneTree/equalized`` counts the same way: its panes
    /// stack across this axis rather than along it, so they share whatever this side
    /// is given. `isVertical` describes the divider, not the arrangement, so two
    /// splits share an axis exactly when it matches.
    private var refusals = 0
    private var refusedAt: Double?

    public init() {}

    /// What this split should do on this layout pass.
    public enum Decision: Equatable, Sendable {
        /// The first child already sits within ``SplitSeat/tolerance`` of the
        /// legal seat.
        case settled
        /// Ask AppKit to put the divider here. The position is clamped; the
        /// stored ratio is not.
        case request(position: Double)
        /// Three refusals at this thickness. Stop asking until a new size or a
        /// new ratio.
        case spent
        /// The split is too small to give both panes their minimum. Not a
        /// refusal: there is no legal position to ask for.
        case noLegalSeat
    }

    /// The legal seat for `ratio` at `thickness`, and whether this split should
    /// keep asking for it.
    ///
    /// Clamping the applied position and not the stored ratio is deliberate. The
    /// tree keeps what the user asked for, so re-widening the window restores the
    /// arrangement instead of a value bent to fit the smallest it ever got.
    public mutating func decide(
        thickness: Double,
        ratio: Double,
        current: Double,
        dividerThickness: Double
    ) -> Decision {
        guard let target = reachablePosition(
            thickness: thickness,
            ratio: ratio,
            dividerThickness: dividerThickness
        ) else { return .noLegalSeat }
        // A new size earns fresh attempts. See ``refusals``.
        if refusedAt != thickness {
            refusedAt = thickness
            refusals = 0
        }
        guard refusals < Self.refusalLimit else { return .spent }
        guard abs(current - target) > Self.tolerance else {
            refusals = 0
            return .settled
        }
        return .request(position: target)
    }

    /// Whether the last ``Decision/request(position:)`` landed.
    ///
    /// `landed` is the caller's: only the controller can measure
    /// `firstChildThickness` after `setPosition`. Three `false` observations at
    /// one thickness and the next ``decide(thickness:ratio:current:dividerThickness:)``
    /// returns ``Decision/spent``.
    public mutating func observed(landed: Bool) {
        refusals = landed ? 0 : refusals + 1
    }

    /// The owner asking for something is worth three more attempts, whatever
    /// this split has been refused so far. See ``refusals``.
    public mutating func ratioChanged() {
        refusals = 0
    }

    /// Where the divider can actually sit for the stored ratio, or nil when the
    /// split is too small to give both panes their minimum and there is no legal
    /// position at all.
    ///
    /// This is the difference between a divider that stops at the edge of the
    /// last usable column and a dead app. `NSSplitViewItem.minimumThickness`
    /// refuses any position inside its margin, so once `thickness * ratio` falls
    /// there, `setPosition` never lands, `current` never equals `target`, and
    /// every layout pass asks again. Each refused request re-dirties layout, and
    /// for a nested split, which its parent re-lays out on every pass anyway,
    /// that never converges: AppKit gives up with `NSGenericException`, "the
    /// window has been marked as needing another Update Constraints in Window
    /// pass", and the process dies. It is reachable two ways, both ordinary. Drag
    /// a nested divider near its stop and then make the window smaller. Or do
    /// that, quit, and relaunch into the saved frame, which is worse: the crash
    /// arrives during construction, every launch reads the same session file, and
    /// the only way out is deleting it by hand.
    ///
    /// Clamping the applied position and not the stored ratio is deliberate. The
    /// tree keeps what the user asked for, so re-widening the window restores the
    /// arrangement instead of a value bent to fit the smallest it ever got.
    private func reachablePosition(
        thickness: Double,
        ratio: Double,
        dividerThickness: Double
    ) -> Double? {
        let lowest = Self.minimumPaneThickness
        let highest = thickness - Self.minimumPaneThickness - dividerThickness
        guard highest >= lowest else { return nil }
        return min(max(thickness * ratio, lowest), highest)
    }
}
