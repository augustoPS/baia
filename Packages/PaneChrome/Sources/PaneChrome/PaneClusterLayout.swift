import Foundation

/// Fixed geometry of the capsule: constants only, nothing here may branch on
/// focus, and the capsule never touches the grid. Focus changes the fill and
/// the stroke (the view's business), never a dimension, so looking at a pane
/// cannot resize what the pane is showing.
///
/// The restraint is inherited from the footer's metrics, which held it because
/// a focus-dependent *height* reflowed the ghostty grid and `SIGWINCH`'d the
/// pane's child process. The pill cannot do that — it is an overlay and takes
/// no height from any terminal view — so the rule survives here as discipline
/// rather than as a hazard. See ``PaneChromeMetrics`` for the measurement that
/// outlived the bar.
public enum PaneClusterMetrics {
    /// Sized for the same 11 pt segment text the footer drew, plus the
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

// **`PaneBottomArrangement` and `bottomArrangement(clusterOnly:underGlass:)`
// stood here until 2026-08-13.** The enum named three bottom edges — the
// surface stopping above the footer bar, running full height with a
// `window-padding-y` bump to clear a bar floating over its last points, or
// running clear to the bottom with nothing below it. Two of the three named a
// footer, and the footer view is gone: every pane wears the capsule, so
// `clusterOnly` was the constant `true`, the function returned
// `.fullHeightClear` before it ever consulted glass, and the other two cases
// were unconstructible.
//
// **The type is deleted rather than collapsed to its one surviving case,
// because a one-case enum decides nothing.** What made this a type was the
// choice between three bottom edges; with two gone there is no choice left to
// represent, and `bottomArrangement` would be a function whose answer does not
// depend on either argument. A `case fullHeightClear` retained alone would
// have every consumer switch on a value that cannot vary — the shape that
// reads as a live decision and is not one, which is how a dead branch survives
// a sweep. The pin at `TerminalPaneController.viewDidLoad` is unconditional
// now and states its own reason.
//
// **The one distinction the enum carried that still exists is glass, and it
// moved to the fact that always owned it.** `.fullHeightClear` split by
// `isSpawnedUnderGlass` at `ConfigurationCenter.apply(to:)` to pick between
// zeroing the surface's `background-opacity` and leaving it; that read the
// glass fact through the arrangement rather than directly. It now reads
// `TerminalPaneController.spawnedUnderGlass`, which is where the freeze lives
// and always did.
//
// **Deleting this moved no padding, and that was measured rather than
// reasoned.** The `+glassWindowPaddingBump` arm was the live-grid risk in this
// deletion: a changed `window-padding-y` is a SIGWINCH-bearing grid resize.
// But a pane spawning under glass already answered `.fullHeightClear` and took
// the un-bumped configuration, so the bumped arm was unreachable before this
// commit, not merely unused. Confirmed by trapping both dead arms with
// `fatalError` and running the dev build under the owner's `chromeStyle:
// glass` — the app spawned a live shell and neither fired. A real glass pane
// measured 44 rows x 106 columns before and after.

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

    /// How wide the whole pill may be on this pane.
    ///
    /// The same reservation ``noticeTextBudget(paneWidth:cornerInset:)`` makes,
    /// one level out: that budgets the notice's *glyphs*, this budgets the
    /// *pill*, so the two answers differ by exactly the pill's two insets and
    /// cannot drift apart. `cornerInset` comes off both ends for that function's
    /// reason — the trailing inset is the gap the pill sits behind, and
    /// reserving the same at the leading edge is what keeps a full-width pill
    /// from reading as a bar welded across the pane's top.
    ///
    /// Clamped at zero: a pane mid-divider-drag can be narrower than its own
    /// insets, and the harmless failure is a pill with nothing on it.
    public static func pillWidthBudget(paneWidth: Double, cornerInset: Double) -> Double {
        max(0, paneWidth - cornerInset * 2)
    }

    /// The order resting segments are given up in when the pill will not fit
    /// its pane, first dropped first.
    ///
    /// **Why there is a drop order at all.** Every resting segment used to be
    /// treated as affordable — "the pill has never budgeted a resting segment" —
    /// which was true while the widest of them was a branch name. The operation
    /// broke it: `CHERRY-PICK (a1b2c3d) *` measures 174.8 pt against the same
    /// pane's 92.0 pt without the operation, so a pane between 98 and 181 pt
    /// wide displayed its pill correctly right up until a cherry-pick began, and
    /// then the pill grew past the pane's leading edge and drew over the
    /// neighbour. For `git bisect` that state lasts until `bisect reset`, which
    /// can be the whole session. Nothing about that is temporary enough to buy
    /// with width the pane does not have.
    ///
    /// **The order, and why the operation is not first out.** Read as a list of
    /// what a glance can least afford to lose:
    ///
    /// 1. ``PaneClusterSegmentRole/agent`` — the agent's label. The attention
    ///    dot, which is what the label is scanned *for*, survives separately and
    ///    is the last thing dropped, so losing the name costs the least.
    /// 2. ``PaneClusterSegmentRole/changes`` — `↑1*?3`. Counts, recoverable in
    ///    one click on the changes card, and meaningful only once the place is
    ///    known.
    /// 3. ``PaneClusterSegmentRole/operation`` — `CHERRY-PICK`. Third rather
    ///    than first *because* it is the widest: dropping it is what buys the
    ///    room, so it must not be spent before the two segments whose loss costs
    ///    less. It goes before place because a bare hash with no operation is
    ///    merely unexplained, while an operation with no place names work in
    ///    progress on nothing. Both facts are on the place card, one click away,
    ///    which is where the `wt:` prefix already lives for the same reason.
    /// 4. ``PaneClusterSegmentRole/place`` — the branch or hash. What the pane
    ///    *is*; the last text to go.
    ///
    /// ``PaneClusterSegmentRole/attention`` is absent from this list and is
    /// never dropped: it is 6 pt, it is the one segment a pane can be scanned
    /// for from across the window, and it is the anchor the approval popover
    /// reserves a position against
    /// (``PaneClusterView/approvalAnchorRect()``). ``PaneClusterSegmentRole/notice``
    /// is absent too, because a notice takes the pill alone and is budgeted as
    /// glyphs by ``noticeCut(_:budget:measure:)`` instead.
    ///
    /// **So a pill carrying only the dot has a floor of 22 pt and a pane below
    /// that wears a pill wider than itself.** The dot is 6 and the two pill
    /// insets are 8 each; nothing in ``fitting(segments:widths:budget:)`` can go
    /// under that, because the only thing left to give up is the one role this
    /// list deliberately excludes. A pane dragged to 20 pt or less therefore
    /// overflows by a few points, and that is chosen rather than overlooked:
    /// the alternative is a pane that is *silent* about an agent waiting on the
    /// owner, which is the one thing the capsule exists to prevent, and at 20 pt
    /// of pane there is nothing legible to protect anyway. An earlier version of
    /// this doc claimed "the pane wears no pill rather than a clipped one",
    /// which was never true of the dot.
    public static let dropOrder: [PaneClusterSegmentRole] = [
        .agent, .changes, .operation, .place,
    ]

    /// The segments that fit `budget`, dropped in ``dropOrder`` until they do.
    ///
    /// **Dropped whole, never truncated, and that is the capsule's existing
    /// grammar rather than a new one.** ``PaneClusterSegments/build(from:)``
    /// already states it — "a segment with nothing to say is absent, never
    /// empty, which is the footer's vanish discipline, moved" — and a half-drawn
    /// `CHERRY-P` would be a fact the owner cannot act on wearing the colour that
    /// says act now. The notice is the one thing here that *is* cut, because a
    /// half-read sentence still names its problem; a half-read label names a
    /// different operation.
    ///
    /// Returns the survivors in the input's order, so the caller's placement
    /// pass is unchanged. `widths` is what the caller measured, in the caller's
    /// font; a role missing from it counts as zero-wide, matching
    /// ``solve(segments:widths:)``'s own tolerance.
    ///
    /// A budget that not even the smallest survivor fits answers what is left
    /// after every droppable role is gone, which is the attention dot alone. The
    /// dot's own 22 pt pill can still exceed a degenerate budget; see
    /// ``fitting(segments:widths:budget:)``'s note on the pane that is narrower
    /// than a dot.
    ///
    /// **Keep what fits, not drop until it fits, and the difference is a third
    /// of the pill.** The first version of this walked ``dropOrder`` and removed
    /// each role permanently, stopping at the first survivor set that fit. That
    /// reads like the drop order but implements a one-way ratchet: once
    /// ``PaneClusterSegmentRole/changes`` was given up it stayed given up even
    /// after ``PaneClusterSegmentRole/operation`` was given up too and freed 82.8
    /// pt, far more than changes had needed. Measured on the shipped widths, a
    /// 200 pt pane kept `operation, place, attention` at 174.0 while `place,
    /// changes, attention` at 106.0 would also have fit; a 160 pt pane kept 91.2
    /// of its 148.0 budget and a 100 pt pane showed a bare dot against 88.0 pt of
    /// room. The owner dragging a divider watched the branch name vanish with the
    /// pill two-thirds empty.
    ///
    /// **``dropOrder`` is a precedence, so the search is lexicographic and not a
    /// sum.** Every subset of the droppable roles is a candidate; the winner is
    /// the widest-ranked one that fits, compared by reading the drop order
    /// backwards — does it keep ``PaneClusterSegmentRole/place``, then
    /// ``PaneClusterSegmentRole/operation``, then
    /// ``PaneClusterSegmentRole/changes``, then ``PaneClusterSegmentRole/agent``.
    /// Lexicographic rather than "most segments" or a weighted count, because
    /// those let three cheap low-rank segments outbid one precious one: scoring
    /// by a bitmask sum drops the branch name to keep `agent` and `changes`
    /// together, which is exactly the trade the doc above says never to make.
    /// Under this comparison one more precious role beats any number of cheaper
    /// ones, which is what "least missed first" meant.
    ///
    /// A consequence worth naming, because it looks like a bug and is not: the
    /// survivors are not monotonic in the budget. At 100 pt of budget the pill
    /// keeps `place, attention` (91.2); at 91 it keeps `changes, agent,
    /// attention` (85.6), having given the branch name up — because at 91 no set
    /// containing place fits at all (place with the dot alone is 91.2), so
    /// precedence falls through to the next rank and spends the room on what
    /// does fit. Dropping a role frees its width for cheaper ones; that is the
    /// whole point of reconsidering.
    ///
    /// **Cost is a subset enumeration and that is affordable because the set is
    /// four.** ``dropOrder`` has four members, so this is at most sixteen
    /// candidate sets, each measured by a `reduce` over at most five segments,
    /// and it runs from `remeasure` on a status change or a divider drag rather
    /// than per `draw`. Written as a bitmask loop rather than a recursive
    /// power-set for the same reason ``noticeCut(_:budget:measure:)`` keeps its
    /// simple loop: the bound is fixed by a constant in this file, and a reader
    /// can check sixteen. `theFitIsTheBestRankedSetThatFitsRatherThanTheFirstOne`
    /// pins the property against a brute-force oracle, so if `dropOrder` ever
    /// grows past what enumeration can afford, that test is where the cost shows
    /// up.
    ///
    /// Returns the survivors in the input's order regardless of which subset
    /// won, so the caller's placement pass is unchanged.
    public static func fitting(
        segments: [PaneClusterSegment],
        widths: [PaneClusterSegmentRole: Double],
        budget: Double
    ) -> [PaneClusterSegment] {
        // The roles actually present that may be given up, in `dropOrder`'s own
        // order. Anything not in `dropOrder` — the attention dot, a notice — is
        // never a candidate for dropping and is carried by every subset below.
        let droppable = dropOrder.filter { role in segments.contains { $0.role == role } }
        guard !droppable.isEmpty else { return segments }

        // Precedence, most precious first: `dropOrder` read backwards. The
        // comparison below is lexicographic on this sequence.
        let precedence = Array(droppable.reversed())

        var best: [PaneClusterSegment]?
        var bestRank: [Int]?
        // Every subset of `droppable`, as a bitmask. At most sixteen.
        for mask in 0..<(1 << droppable.count) {
            var keptRoles: Set<PaneClusterSegmentRole> = []
            for (index, role) in droppable.enumerated() where mask & (1 << index) != 0 {
                keptRoles.insert(role)
            }
            // Undroppable roles ride along in every candidate.
            let candidate = segments.filter {
                keptRoles.contains($0.role) || !droppable.contains($0.role)
            }
            guard width(of: candidate, widths: widths) <= budget else { continue }

            // Rank as a most-precious-first vector of "is this role kept".
            // `true` sorts above `false`, so the lexicographically greatest
            // vector is the set that keeps the most precious role it can, and
            // breaks ties on the next most precious, and so on.
            let rank = precedence.map { keptRoles.contains($0) ? 1 : 0 }
            if let current = bestRank, !current.lexicographicallyPrecedes(rank) { continue }
            bestRank = rank
            best = candidate
        }

        // No subset fits, not even the empty one: the budget is under what the
        // undroppable roles alone cost. They survive anyway — the dot is what a
        // pane is scanned for and `dropOrder` deliberately excludes it — so the
        // answer is those roles and the pill overflows a pane narrower than a
        // dot. See the note on ``dropOrder`` for why that is preferred to a pane
        // that goes dark.
        return best ?? segments.filter { !droppable.contains($0.role) }
    }

    /// What ``solve(segments:widths:)`` followed by ``pillWidth(for:)`` would
    /// answer, without building the placement. Kept beside them so the budget
    /// and the layout cannot disagree about what a set of segments costs.
    ///
    /// Zero for no segments, matching ``pillWidth(for:)``: a pane with nothing
    /// to say wears no capsule rather than an empty pill.
    public static func width(
        of segments: [PaneClusterSegment],
        widths: [PaneClusterSegmentRole: Double]
    ) -> Double {
        guard !segments.isEmpty else { return 0 }
        let text = segments.reduce(0.0) { $0 + (widths[$1.role] ?? 0) }
        let gaps = Double(segments.count - 1) * PaneClusterMetrics.segmentGap
        return text + gaps + PaneClusterMetrics.horizontalInset * 2
    }

    /// How much text width a notice may claim, given the pane it floats over.
    ///
    /// **The one place the capsule bounds itself, and only the notice needs
    /// it.** Every resting segment is a short label the pane was always wide
    /// enough for — a branch name, `↑1*?3`, an agent's label — so
    /// ``solve(segments:widths:)`` lets the pill size to its content and the
    /// question of a budget never arises. A notice is a sentence: the longest
    /// ``PanePrompt/PromptPath/Refusal/notice`` runs sixty-six characters,
    /// about 435 pt in the capsule's 11 pt monospace, which is wider than a
    /// split pane and often wider than the window. Unbounded, the pill would
    /// grow leftward off the pane it belongs to, because it is pinned by its
    /// top-right corner and nothing else.
    ///
    /// `paneWidth` is the width of the view the capsule is installed in.
    /// `cornerInset` is subtracted at *both* ends rather than the one the pill
    /// is pinned at: the trailing inset is the gap the pill actually sits
    /// behind, and reserving the same at the leading edge is what keeps a
    /// full-width notice from reading as a bar welded across the pane's top.
    /// The two pill insets come off after that, leaving what the glyphs may
    /// have.
    ///
    /// **`cornerInset` is a parameter and not
    /// ``PaneClusterMetrics/cornerInset`` read from here, because the pill is
    /// not pinned at the constant.** `chrome.cluster.cornerInset` is a live
    /// dial and `TerminalPaneController.resolvedClusterInset` is what the two
    /// edge constraints actually carry. Reading the constant while the dial
    /// held 40 over-allowed by 68 pt and the notice ran off the pane's leading
    /// edge — the exact failure this budget exists to prevent, reintroduced by
    /// the budget itself. The caller passes what it pinned; there is one
    /// resolution of the inset and it lives at the constraint.
    ///
    /// The answer is clamped at zero, never negative: a pane mid-divider-drag
    /// can be narrower than its own insets, and a negative budget handed to a
    /// truncator is a crash or a garbage width rather than an empty pill. Zero
    /// draws nothing, which is the harmless failure and the same one
    /// ``pillWidth(for:)`` gives an empty placement.
    ///
    /// The caller truncates its measured string to fit this, and the pill then
    /// takes its width from the truncated measurement the ordinary way, so a
    /// notice shorter than the budget wears a pill exactly as wide as it needs
    /// and no wider.
    public static func noticeTextBudget(paneWidth: Double, cornerInset: Double) -> Double {
        max(0, paneWidth
            - cornerInset * 2
            - PaneClusterMetrics.horizontalInset * 2)
    }

    /// The longest prefix of `text` whose measured width fits `budget`.
    ///
    /// **Cut rather than elided, which the footer ruled first and this inherited
    /// on its merits.** Its notice segment took `truncation: .none` while every
    /// other segment elided, on the argument that a half-read reason still names
    /// the problem where an ellipsis does not. The footer was deleted on
    /// 2026-08-13; the argument is about reading a refusal rather than about a
    /// bar, so it moved here with the notice. There is
    /// no `…` appended for the same reason — the glyph would cost the width of
    /// another word of the reason to say something the cut already implies.
    ///
    /// `measure` is injected because measuring text needs a font and a font
    /// needs AppKit, and the decision this function makes — where a sentence
    /// stops — is the one thing about the notice the owner actually sees. It
    /// lived in the view until the fifth review found it there untested; the
    /// AppKit half that remains at the call site is a single
    /// `NSAttributedString.size().width`.
    ///
    /// **Prefixes, and the cost is quadratic in measured characters.** Each
    /// candidate is the whole prefix `text[startIndex..<next]`, so the loop makes
    /// O(n) calls to `measure` but hands it O(n²) characters in total: the
    /// longest refusal, sixty-six characters against a budget that admits sixty,
    /// is 62 calls and 1957 characters; a hypothetical 400-character sentence
    /// would be 382 calls and 73171 characters. `String(text[a..<b])` is a fresh
    /// allocation of that prefix, not a view, so the allocation count follows the
    /// same curve.
    ///
    /// **That is accepted rather than unnoticed.** The input is a
    /// ``PanePrompt/PromptPath/Refusal/notice``, whose longest member is those
    /// sixty-six characters, and this runs once per notice from `remeasure`
    /// rather than per `draw` — two thousand characters of `NSAttributedString`
    /// measurement, three seconds apart, on a string bounded by a fixed
    /// vocabulary. Binary search over the indices would make it O(log n) calls
    /// and O(n log n) characters, and at n=66 it would save an invisible
    /// fraction of a millisecond while trading a loop whose stopping condition
    /// is obvious for one whose invariant needs an argument. The cost is bounded
    /// by the vocabulary, so the simple loop is kept and
    /// `theCutMeasuresNoMoreCharactersThanTheSentenceCanCost` pins the real
    /// number: if a notice ever grows unbounded — a path substituted into a
    /// refusal, say — that test fails and this comment is the wrong one to
    /// believe.
    ///
    /// Measuring per-character advances and accumulating them is not the escape
    /// it looks like. The sentence is not guaranteed all-ASCII — the refusals
    /// name filenames' problems today and could name the filenames tomorrow —
    /// and a font's advance for a run is not the sum of its characters' advances
    /// once kerning or a ligature is involved, so summing would cut in the wrong
    /// place on exactly the reason that needed reading.
    ///
    /// **Characters, so a grapheme cluster is never split.** The loop walks
    /// `String.Index` by `Character`, Swift's extended grapheme cluster, so a
    /// family emoji or an `é` spelled as `e` + U+0301 either fits whole or is
    /// dropped whole. Cutting between the scalars of one cluster would render a
    /// combining mark on nothing.
    ///
    /// A `budget` of zero (or less) answers the empty string without measuring
    /// anything, which is what a pane narrower than its own insets gets from
    /// ``noticeTextBudget(paneWidth:cornerInset:)``.
    public static func noticeCut(_ text: String, budget: Double, measure: (String) -> Double)
        -> String {
        guard budget > 0 else { return "" }
        // The whole sentence first, because it is the common case on any pane
        // wider than a sixty-six character run and the loop below would
        // otherwise measure every prefix of it to reach the same answer.
        guard measure(text) > budget else { return text }

        var fits = text.startIndex
        var index = text.startIndex
        // Each step measures the whole prefix, not the character added to it,
        // because a font's advance for a run is not the sum of its characters'
        // advances. That is what makes the loop quadratic in measured
        // characters; the doc comment above argues why that is affordable at a
        // sixty-six character sentence and what pins it.
        while index < text.endIndex {
            let next = text.index(after: index)
            guard measure(String(text[text.startIndex..<next])) <= budget else { break }
            fits = next
            index = next
        }
        return String(text[text.startIndex..<fits])
    }
}
