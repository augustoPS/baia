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

/// How close a match has to be before a verb is shown at all.
///
/// `FuzzyMatcher` was built for paths, where a spread-out subsequence is a fair
/// match because every component is a word the owner chose. A menu title is a
/// sentence, and the same rule let `>set` return `Show Next Tab`.
@Suite struct VerbMatchStrictnessTests {
    /// The real titles, so these arms fail if the menu is renamed under them.
    private let verbs: [PaletteVerb] = [
        PaletteVerb(title: "Settings…", id: 1),
        PaletteVerb(title: "Set Project Directory…", id: 2),
        PaletteVerb(title: "Reset Sidebar Size", id: 3),
        PaletteVerb(title: "Select All", id: 4),
        PaletteVerb(title: "Select Next Pane", id: 5),
        PaletteVerb(title: "Show Next Tab", id: 6),
        PaletteVerb(title: "Show Previous Tab", id: 7),
    ]

    /// The reported defect. `S`(Show) + `e`(inside Next) + `t`(Tab) is a
    /// subsequence and was accepted; the `e` is what makes it noise.
    @Test func setNoLongerReachesShowNextTab() {
        let titles = VerbRanker.rank(verbs, query: "set").map(\.title)
        #expect(!titles.contains("Show Next Tab"))
        #expect(!titles.contains("Show Previous Tab"))
    }

    /// The verbs a person typing `set` means, all of which are one unbroken run.
    @Test func setStillFindsEveryContiguousMatch() {
        let titles = VerbRanker.rank(verbs, query: "set").map(\.title)
        #expect(titles.contains("Settings…"))
        #expect(titles.contains("Set Project Directory…"))
        #expect(titles.contains("Reset Sidebar Size"))
    }

    /// Contiguity is not required, word starts are. Dropping the second half of
    /// the rule for a substring test would take this with it.
    @Test func anAcronymOfWordStartsStillMatches() {
        let titles = VerbRanker.rank(verbs, query: "snt").map(\.title)
        #expect(titles.contains("Show Next Tab"))
    }

    /// The mirror of the acronym arm, and the pair is the whole rule: same
    /// candidate, same length of query, accepted through word starts and refused
    /// through a word's interior.
    @Test func aFragmentInsideAWordIsRefused() {
        let single = [PaletteVerb(title: "Show Next Tab", id: 1)]
        #expect(VerbRanker.rank(single, query: "snt").count == 1)
        #expect(VerbRanker.rank(single, query: "set").isEmpty)
    }

    /// A single character cannot be fragmented, so it is always acceptable and
    /// the ranking alone orders it.
    @Test func oneCharacterIsAlwaysAccepted() {
        #expect(!VerbRanker.rank(verbs, query: "s").isEmpty)
    }

    /// Two words joined by the rule's other boundaries, so a hyphenated or
    /// camel-cased title is reachable the same way a spaced one is.
    @Test func separatorsAndCamelCaseStartWordsToo() {
        let odd = [
            PaletteVerb(title: "Reset-Sidebar Size", id: 1),
            PaletteVerb(title: "ShowNextTab", id: 2),
        ]
        #expect(VerbRanker.rank(odd, query: "rss").count == 1)
        #expect(VerbRanker.rank(odd, query: "snt").count == 1)
    }
}
