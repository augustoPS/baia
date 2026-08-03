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
