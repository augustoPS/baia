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
    /// **Cut rather than elided, which is `PaneStatusSegments`' own choice for
    /// this role** (`truncation: .none`, and the reason stated there): a
    /// half-read reason still names the problem, an ellipsis does not. There is
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
