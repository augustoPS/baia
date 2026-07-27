import Testing

@testable import PaneSearch

@Suite struct PaneSearchTests {
    @Test func everyOccurrenceInALineIsItsOwnMatch() {
        // Two hits on one line are two places to go, not one. Reporting the
        // line once would make the second occurrence unreachable.
        let matches = PaneSearch.matches(
            in: ["error here and error there"],
            query: SearchQuery(needle: "error")
        )
        #expect(matches.count == 2)
        #expect(matches[0].range == 0 ..< 5)
        #expect(matches[1].range == 15 ..< 20)
        #expect(matches.allSatisfy { $0.lineIndex == 0 })
    }

    @Test func theLineIndexIsTheIndexIntoTheInput() {
        let matches = PaneSearch.matches(
            in: ["one", "two", "needle", "four"],
            query: SearchQuery(needle: "needle")
        )
        #expect(matches.count == 1)
        #expect(matches[0].lineIndex == 2)
        #expect(matches[0].line == "needle")
    }

    @Test func anEmptyNeedleFindsNothing() {
        let matches = PaneSearch.matches(
            in: ["a", "b", "c"],
            query: SearchQuery(needle: "")
        )
        #expect(matches.isEmpty)
    }

    /// The property the whole design rests on. The screen read returns logical
    /// lines, so a line far longer than any terminal is one line here and one
    /// match, rather than several fragments split at a wrap the reader never
    /// typed.
    @Test func alineLongerThanAnyTerminalIsStillOneLine() {
        let long = String(repeating: "x", count: 500) + "needle"
        let matches = PaneSearch.matches(
            in: [long],
            query: SearchQuery(needle: "needle")
        )
        #expect(matches.count == 1)
        #expect(matches[0].range == 500 ..< 506)
    }

    /// Offsets are character offsets, so a range never splits a grapheme. The
    /// palette's highlight ranges have this same class of bug available to them,
    /// and a range that lands mid-emoji renders as a broken box.
    @Test func offsetsCountCharactersNotBytes() {
        let matches = PaneSearch.matches(
            in: ["🇧🇷 café needle"],
            query: SearchQuery(needle: "needle")
        )
        #expect(matches.count == 1)
        let line = Array("🇧🇷 café needle")
        let hit = matches[0].range
        #expect(String(line[hit]) == "needle")
    }

    /// The limit is what keeps a common needle from turning a scrollback into
    /// hundreds of thousands of rows the panel draws eight of.
    @Test func theLimitStopsTheScan() {
        let lines = Array(repeating: "a a a", count: 100)
        let capped = PaneSearch.matches(in: lines, query: SearchQuery(needle: "a"), limit: 7)
        #expect(capped.count == 7)
        // The cap counts hits, not lines, so it stops inside a line too.
        #expect(capped.map(\.lineIndex) == [0, 0, 0, 1, 1, 1, 2])
        #expect(PaneSearch.matches(in: lines, query: SearchQuery(needle: "a"), limit: 0).isEmpty)
        #expect(PaneSearch.matches(in: lines, query: SearchQuery(needle: "a")).count == 300)
    }

    /// A single line with many hits is the case that used to be quadratic: the
    /// old walk rebuilt the rest of the line after every hit, so 8,000 hits in
    /// one 80,000 character line took 9.9 seconds. A `cat` of a minified bundle
    /// arrives as exactly one such line.
    @Test func alineWithManyHitsIsWalkedOnce() {
        let line = String(repeating: "abcdefghij", count: 20_000)
        let matches = PaneSearch.matches(in: [line], query: SearchQuery(needle: "a"))
        #expect(matches.count == 20_000)
        #expect(matches.first?.range == 0 ..< 1)
        #expect(matches.last?.range == 199_990 ..< 199_991)
    }

    /// Overlapping needles report once, and the resumption that makes that true
    /// is also what keeps the offsets right after the first hit.
    @Test func overlappingNeedlesReportOnce() {
        let matches = PaneSearch.matches(in: ["aaaa"], query: SearchQuery(needle: "aa"))
        #expect(matches.map(\.range) == [0 ..< 2, 2 ..< 4])
    }

    /// Offsets after the first hit are still counted in characters of the whole
    /// line, which is the arithmetic the resumption has to get right: an
    /// astral character before the first hit shifts every later offset.
    @Test func offsetsAfterTheFirstHitCountFromTheLineStart() {
        let matches = PaneSearch.matches(
            in: ["\u{1F600} needle \u{1F600} needle"],
            query: SearchQuery(needle: "needle")
        )
        let line = Array("\u{1F600} needle \u{1F600} needle")
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { String(line[$0.range]) == "needle" })
        #expect(matches.map(\.range) == [2 ..< 8, 11 ..< 17])
    }

    /// Case-insensitive matching against a line whose hit is a different length
    /// than the needle. The offsets come from the hit's own bounds, not from the
    /// needle's length, so a fold that changes the count cannot desynchronise
    /// the walk.
    @Test func acaseInsensitiveHitIsMeasuredByItsOwnBounds() {
        let matches = PaneSearch.matches(
            in: ["Stra\u{00DF}e and STRASSE"],
            query: SearchQuery(needle: "strasse")
        )
        let line = Array("Stra\u{00DF}e and STRASSE")
        #expect(matches.allSatisfy { $0.range.upperBound <= line.count })
        #expect(matches.allSatisfy { !$0.range.isEmpty })
    }

    @Test func matchesAreOrderedByLineThenByPosition() {
        let matches = PaneSearch.matches(
            in: ["b b", "a", "b"],
            query: SearchQuery(needle: "b")
        )
        #expect(matches.map(\.lineIndex) == [0, 0, 2])
        #expect(matches.map(\.range.lowerBound) == [0, 2, 0])
    }
}
