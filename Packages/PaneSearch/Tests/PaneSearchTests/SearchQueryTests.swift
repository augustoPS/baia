import Testing

@testable import PaneSearch

@Suite struct SearchQueryTests {
    /// Smart case, the rule every editor has already trained the owner on: a
    /// lowercase needle is case-insensitive, and one uppercase character makes
    /// the whole query exact. One rule and no toggle, because a toggle is a
    /// second thing to remember and to get wrong.
    @Test func alowercaseNeedleIgnoresCase() {
        let query = SearchQuery(needle: "error")
        #expect(query.isCaseSensitive == false)
        #expect(query.matches(line: "ERROR: build failed"))
        #expect(query.matches(line: "Error: build failed"))
        #expect(query.matches(line: "error: build failed"))
    }

    @Test func anyUppercaseMakesTheQueryExact() {
        let query = SearchQuery(needle: "Error")
        #expect(query.isCaseSensitive)
        #expect(query.matches(line: "Error: build failed"))
        #expect(query.matches(line: "error: build failed") == false)
        #expect(query.matches(line: "ERROR: build failed") == false)
    }

    /// An empty needle finds nothing rather than everything. Returning every
    /// line for an empty field would fill the panel the instant it opened and
    /// then empty it on the first keystroke, which reads as a bug both times.
    @Test func anEmptyNeedleIsNotAMatch() {
        let query = SearchQuery(needle: "")
        #expect(query.isEmpty)
        #expect(query.matches(line: "anything at all") == false)
    }

    /// Whitespace is a legitimate thing to search for, so it is not trimmed
    /// away. A needle of only spaces still finds indented output.
    @Test func whitespaceIsANeedleLikeAnyOther() {
        let query = SearchQuery(needle: "  ")
        #expect(query.isEmpty == false)
        #expect(query.matches(line: "a  b"))
        #expect(query.matches(line: "ab") == false)
    }

    /// The byte walk is a second implementation of the matching rule, and a
    /// second implementation is a second answer unless something compares them.
    /// This runs both over the same generated lines, which is the only reason
    /// the fast path is allowed to exist.
    @Test func theTwoWalksAgreeOnAsciiLines() {
        var seed: UInt64 = 0x5DEE_CE66_D2CB
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        let alphabet = Array("aAbB cC.-/eErR01")
        for needle in ["a", "aa", "ab", "A", "eR", "  ", ".", "/e", "rrr"] {
            let query = SearchQuery(needle: needle)
            for _ in 0 ..< 200 {
                let line = String((0 ..< next(40)).map { _ in alphabet[next(alphabet.count)] })
                let fast = query.asciiHits(in: line, limit: .max)
                let general = query.generalHits(in: line, limit: .max)
                #expect(fast != nil, "an ASCII line must take the byte walk: '\(line)'")
                #expect(fast ?? [] == general, "needle '\(needle)' in '\(line)'")
            }
        }
    }

    /// The byte walk hands back any line it cannot measure in bytes. A byte
    /// offset stops being a character offset the moment a character spans more
    /// than one byte, and a carriage return before a newline is one character
    /// spelled with two bytes.
    @Test func theByteWalkRefusesWhatItCannotMeasure() {
        let query = SearchQuery(needle: "needle")
        #expect(query.asciiHits(in: "a plain ascii needle", limit: .max) != nil)
        #expect(query.asciiHits(in: "caf\u{00E9} needle", limit: .max) == nil)
        #expect(query.asciiHits(in: "one\r\ntwo needle", limit: .max) == nil)
        #expect(SearchQuery(needle: "caf\u{00E9}").asciiHits(in: "cafe", limit: .max) == nil)

        // And the answers still come out right through the general walk.
        let line = "caf\u{00E9} needle"
        #expect(query.hits(in: line, limit: .max) == [5 ..< 11])
        #expect(String(Array(line)[5 ..< 11]) == "needle")
    }

    /// The limit stops the walk, in both of them.
    @Test func theLimitAppliesToEitherWalk() {
        let query = SearchQuery(needle: "a")
        #expect(query.hits(in: "aaaa", limit: 2) == [0 ..< 1, 1 ..< 2])
        #expect(query.hits(in: "caf\u{00E9} aaaa", limit: 2) == [1 ..< 2, 5 ..< 6])
        #expect(query.hits(in: "aaaa", limit: 0).isEmpty)
    }
}
