import Testing

@testable import PaneChrome

/// The verb half of the palette, which exists as its own ranker so the two
/// populations never have to be scored against each other.
@Suite struct VerbRankerTests {
    private let verbs: [PaletteVerb] = [
        PaletteVerb(title: "Settings…", shortcut: "⌘,", id: 100),
        PaletteVerb(title: "Equalize Panes", shortcut: "⌃⌘=", id: 101),
        PaletteVerb(title: "Reset Sidebar Size", id: 102),
        PaletteVerb(title: "Split Right", shortcut: "⌘D", id: 103),
        PaletteVerb(title: "Reload Project List", id: 104),
    ]

    // MARK: - The prefix

    @Test func aQueryWithNoPrefixIsNotAVerbQuery() {
        #expect(VerbRanker.verbQuery(from: "website") == nil)
        #expect(VerbRanker.verbQuery(from: "") == nil)
    }

    @Test func thePrefixAloneIsAnEmptyVerbQuery() {
        #expect(VerbRanker.verbQuery(from: ">") == "")
    }

    /// The space after the prefix is what a person types out of habit, so both
    /// spellings are one query. Refusing the spaced one would be a rule with
    /// nothing behind it.
    @Test func theSpaceAfterThePrefixIsOptional() {
        #expect(VerbRanker.verbQuery(from: ">equal") == "equal")
        #expect(VerbRanker.verbQuery(from: "> equal") == "equal")
        #expect(VerbRanker.verbQuery(from: ">   equal") == "equal")
    }

    /// A `>` inside the query is content rather than a second prefix, so a title
    /// holding one stays reachable.
    @Test func onlyTheLeadingAngleIsThePrefix() {
        #expect(VerbRanker.verbQuery(from: ">a > b") == "a > b")
    }

    // MARK: - Ranking

    /// The empty query is what makes the mode teach itself: entering it by
    /// accident shows every verb rather than an empty box.
    @Test func anEmptyQueryAnswersEveryVerbInOrder() {
        let ranked = VerbRanker.rank(verbs, query: "")
        #expect(ranked.map(\.title) == verbs.map(\.title))
    }

    @Test func aQueryFindsAVerbByItsTitle() {
        let ranked = VerbRanker.rank(verbs, query: "equal")
        #expect(ranked.first?.title == "Equalize Panes")
    }

    /// Non-matching verbs are dropped rather than sorted last, the same rule
    /// `ProjectRanker` follows, so the list shrinks as the query grows.
    @Test func verbsThatDoNotMatchAreDropped() {
        let ranked = VerbRanker.rank(verbs, query: "zzzz")
        #expect(ranked.isEmpty)
    }

    /// Two verbs sharing a prefix both survive, and the shorter title wins the
    /// tie when the scores are equal.
    @Test func theShorterTitleWinsAnEqualScore() {
        let pair = [
            PaletteVerb(title: "Reset Sidebar Size and More", id: 1),
            PaletteVerb(title: "Reset Sidebar", id: 2),
        ]
        let ranked = VerbRanker.rank(pair, query: "reset")
        #expect(ranked.map(\.id) == [2, 1])
    }

    /// The comparator has to be a total order, or the highlighted row moves under
    /// the owner's fingers when he types a character that changes no ranking.
    /// Same-length titles at the same score therefore fall back to the title
    /// itself.
    @Test func equalScoresAndEqualLengthsStillHaveOneOrder() {
        let pair = [
            PaletteVerb(title: "Bxx", id: 1),
            PaletteVerb(title: "Axx", id: 2),
        ]
        #expect(VerbRanker.rank(pair, query: "xx").map(\.id) == [2, 1])
        // Twice, because an unstable sort can answer differently on a second
        // call over the same array.
        #expect(VerbRanker.rank(pair, query: "xx").map(\.id) == [2, 1])
    }

    /// The id is the handle the caller recovers its command through, so it has
    /// to survive ranking untouched.
    @Test func theIdSurvivesRanking() {
        let ranked = VerbRanker.rank(verbs, query: "settings")
        #expect(ranked.first?.id == 100)
        #expect(ranked.first?.shortcut == "⌘,")
    }
}
