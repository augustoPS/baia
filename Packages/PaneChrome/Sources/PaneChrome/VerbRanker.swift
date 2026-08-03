import Foundation
import GitWorkspace

/// One verb the palette can offer, reduced to what ranking and drawing need.
///
/// Deliberately not a `MenuCommand`. The verbs come from `WorkspaceMenu` and the
/// ranker lives here beside ``PaletteRow``, and making this package import that
/// one to rank a title would buy nothing: what a ranker needs is a string to
/// score and something opaque to hand back. The app target owns the translation,
/// which is the same shape ``PaletteRow/kind(of:)`` uses for `Project.Kind`.
///
/// `id` is that opaque handle. It is the command's `tag`, an integer chosen in
/// `MenuCommand` precisely because it survives being stored somewhere that knows
/// nothing about the enum.
public struct PaletteVerb: Sendable, Equatable {
    /// What the menu calls it, which is what the owner reads and types against.
    public let title: String

    /// The shortcut as it is drawn, `⌃⌘=` or empty when there is none.
    public let shortcut: String

    /// `MenuCommand.tag`, so the caller can recover the command it sent.
    public let id: Int

    public init(title: String, shortcut: String = "", id: Int) {
        self.title = title
        self.shortcut = shortcut
        self.id = id
    }
}

/// Orders the palette's verbs for a query.
///
/// A second ranker rather than a widened ``ProjectRanker``, which is the whole
/// point of the prefix mode: the two populations never mix, so neither needs a
/// rule for what the other's score means. `ProjectRanker` breaks ties on a
/// recency count keyed by path, and a verb has no path to key on.
public enum VerbRanker {
    /// Verbs matching `query`, best first.
    ///
    /// Matching runs against ``PaletteVerb/title``, because the title is what the
    /// menu shows and therefore the only spelling the owner has ever seen. A
    /// verb has no second name worth typing, unlike a project, whose path is more
    /// typeable than its display name.
    ///
    /// An empty query answers everything, in the order given. That is what makes
    /// the mode teach itself: `>` alone lists every verb available right now, so
    /// entering the mode by accident shows what it is for rather than an empty
    /// box.
    public static func rank(_ verbs: [PaletteVerb], query: String) -> [PaletteVerb] {
        guard !query.isEmpty else { return verbs }

        var scored: [(verb: PaletteVerb, score: Int)] = []
        for verb in verbs {
            guard let match = FuzzyMatcher.match(query: query, candidate: verb.title) else {
                continue
            }
            guard accepts(query, in: verb.title) else { continue }
            scored.append((verb, match.score))
        }

        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }

            // A total order, for the reason `ProjectRanker`'s comparator spells
            // out: `sorted(by:)` is not stable, so two equally scored verbs would
            // otherwise swap between calls and the highlighted row would move
            // under the owner's fingers as he types a character that changes
            // nothing about the ranking.
            //
            // Shorter first, because a shorter title that scored the same reached
            // that score with less around the match.
            if left.verb.title.count != right.verb.title.count {
                return left.verb.title.count < right.verb.title.count
            }
            return left.verb.title < right.verb.title
        }.map(\.verb)
    }

    /// Whether a title is a close enough match to show, which is a stricter
    /// question for a verb than for a project.
    ///
    /// **`FuzzyMatcher` was built for paths and is too permissive on prose.**
    /// `>set` matched `Show Next Tab` through the `S` of Show, the `e` inside
    /// Next and the `t` of Tab: a subsequence, and for `website/shop` that kind
    /// of spread is a legitimate match, because a path is short and every
    /// component is a word the owner chose. A menu title is a sentence, and three
    /// characters scattered across three words is noise that pushes the verb
    /// actually wanted down the list.
    ///
    /// Measured before it was written rather than tuned afterwards. Against the
    /// real titles, `>set` scores `Settings…` and `Set Project Directory…` at 46,
    /// `Reset Sidebar Size` at 37, and `Show Next Tab` at 24, so the *ranking*
    /// was already right and the defect was only that the tail was shown at all.
    /// What separates them is fragmentation: the three wanted matches are one
    /// unbroken run, and every unwanted one is two or three pieces.
    ///
    /// So the rule is one contiguous run, **or** fragments that each begin a
    /// word. The second half is what keeps an acronym working: `>snt` still finds
    /// `Show Next Tab` through `S`, `N`, `T`, while `>set` no longer does,
    /// because its `e` sits inside Next. A cutoff on the score would have been
    /// smaller and worse: the number would be tuned to the titles that exist
    /// today and a longer one added later would quietly change what survives.
    ///
    /// **Asked of the title, not of the placement `FuzzyMatcher` returned.** That
    /// was the first version of this and it was wrong: the matcher answers with
    /// the highest-scoring placement, which is not the most acceptable one. For
    /// `snt` on `Show Next Tab` it reports `[0, 5, 8]`, taking the `t` inside
    /// *Next* rather than the `T` of *Tab* at index 10, because the gap penalty
    /// costs more than reaching the later word earns. Filtering that placement
    /// would refuse the candidate over a placement nobody asked about while the
    /// acronym the reader typed sat one index further on.
    ///
    /// So the question is whether an acceptable placement **exists**. Two are
    /// acceptable: the query appearing as one unbroken run, or every character
    /// landing on a word start in order.
    static func accepts(_ query: String, in title: String) -> Bool {
        let lowerQuery = query.lowercased()
        guard lowerQuery.count > 1 else { return true }
        if title.lowercased().contains(lowerQuery) { return true }
        return matchesWordStarts(lowerQuery, in: title)
    }

    /// Whether the query can be spelled by taking word-start characters in
    /// order, one per fragment.
    ///
    /// Greedy, and it can be: word starts are sparse, so taking the earliest
    /// available one never blocks a later character that a different choice
    /// would have reached. A title would need the same letter starting two words
    /// for the distinction to arise, and then either choice spells the same
    /// query.
    private static func matchesWordStarts(_ lowerQuery: String, in title: String) -> Bool {
        let characters = Array(title)
        var remaining = Array(lowerQuery)[...]

        for index in characters.indices where startsWord(index, in: characters) {
            guard let wanted = remaining.first else { break }
            if Character(characters[index].lowercased()) == wanted {
                remaining = remaining.dropFirst()
            }
        }
        return remaining.isEmpty
    }

    /// The first character, one after a space or a separator, or a lowercase to
    /// uppercase transition.
    ///
    /// The space is what `FuzzyMatcher.isBoundary` does not consider, and it is
    /// the one that matters here: its separators are `/`, `-`, `_` and `.`,
    /// which are what a path is made of, and a menu title is separated by spaces.
    private static func startsWord(_ index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == " " || separators.contains(previous) { return true }
        return previous.isLowercase && characters[index].isUppercase
    }

    private static let separators: Set<Character> = ["/", "-", "_", ".", "…"]

    /// The query with the mode prefix removed, or nil when the query is not in
    /// verb mode.
    ///
    /// `>` is the prefix. Leading whitespace after it is dropped, so `> equal`
    /// and `>equal` are the same query: the space is what a person types out of
    /// habit and refusing it would be a rule with no reason behind it.
    public static func verbQuery(from query: String) -> String? {
        guard query.hasPrefix(Self.prefix) else { return nil }
        return String(query.dropFirst(Self.prefix.count)).drop(while: \.isWhitespace).description
    }

    public static let prefix = ">"
}
