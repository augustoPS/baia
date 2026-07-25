import Foundation
import Testing

@testable import GitWorkspace

@Suite struct FuzzyMatcherTests {
    @Test func returnsNilWhenTheQueryIsNotASubsequence() {
        #expect(FuzzyMatcher.match(query: "zq", candidate: "website/shop") == nil)
    }

    @Test func returnsNilWhenTheCharactersAreOutOfOrder() {
        // A subsequence match, not a bag of characters. `ps` matching
        // `superpowers` would put every candidate holding both letters in the
        // palette regardless of what the owner typed.
        #expect(FuzzyMatcher.match(query: "hs", candidate: "shop") == nil)
    }

    @Test func matchesEverythingWithAnEmptyQuery() {
        // Score 0 and no indices, so an empty palette query shows the whole list
        // ordered by recency. Nil here would open the palette blank.
        #expect(FuzzyMatcher.match(query: "", candidate: "baia") == FuzzyMatch(score: 0, matchedIndices: []))
    }

    @Test func matchesCaseInsensitively() {
        #expect(FuzzyMatcher.match(query: "GW", candidate: "GitWorkspace") != nil)
        #expect(FuzzyMatcher.match(query: "gw", candidate: "GitWorkspace") != nil)
    }

    @Test func keepsAConsecutiveRunTogetherRatherThanTakingTheEarliestMatch() {
        // The single reason the placement is searched rather than taken greedily.
        // A greedy pass takes the `s` of `website` at index 3 and the `h` of `shop`
        // at index 9: the same match with a five character gap across a slash. The
        // indices are the tell, and they are also what a caller highlights.
        let match = FuzzyMatcher.match(query: "sh", candidate: "website/shop")
        #expect(match?.matchedIndices == [8, 9])
    }

    @Test func scoresAWordBoundaryAboveAMidWordMatch() {
        // The boundary is the start, or the character after `/`, `-`, `_`, `.`.
        let boundary = FuzzyMatcher.match(query: "d", candidate: "claude-dotfiles")
        let midWord = FuzzyMatcher.match(query: "d", candidate: "clauded")
        #expect((boundary?.score ?? 0) > (midWord?.score ?? 0))
    }

    @Test func reachesACamelCaseHumpAsABoundary() {
        // A Swift package directory carries no separator at all, so a
        // separator-only rule scores every character of `GitWorkspace` as mid-word
        // and `gw` loses to any candidate with a slash in it.
        let hump = FuzzyMatcher.match(query: "w", candidate: "GitWorkspace")
        let flat = FuzzyMatcher.match(query: "w", candidate: "gitworkspace")
        #expect((hump?.score ?? 0) > (flat?.score ?? 0))
    }

    @Test func prefersTheBasenameOverAMidPathMatch() {
        // Same character, same boundary status, different component. Without the
        // last-component bonus a query for a site's name ranks the directory that
        // contains it first.
        let basename = FuzzyMatcher.match(query: "s", candidate: "website/shop")
        let midPath = FuzzyMatcher.match(query: "s", candidate: "shop/website")
        #expect((basename?.score ?? 0) > (midPath?.score ?? 0))
    }

    @Test func penalisesTheGapBetweenMatches() {
        // Two candidates of the same length, the same boundaries, and the same
        // component. Only the distance between the matched characters differs, and
        // without the penalty a scattered match ranks with a tight one.
        let tight = FuzzyMatcher.match(query: "ab", candidate: "abxxxx")
        let scattered = FuzzyMatcher.match(query: "ab", candidate: "axxxxb")
        #expect((tight?.score ?? 0) > (scattered?.score ?? 0))
    }

    @Test func anExactCaseMatchOutranksACaseInsensitiveOne() {
        // A tiebreak and nothing more. Both candidates are structurally identical,
        // so this is the only difference left, and weighting it higher would rank
        // any capitalised directory above the sites for a lowercase query.
        let exact = FuzzyMatcher.match(query: "s", candidate: "shop")
        let folded = FuzzyMatcher.match(query: "s", candidate: "Shop")
        #expect((exact?.score ?? 0) > (folded?.score ?? 0))
    }

    @Test func reportsEveryMatchedIndexInOrder() {
        // The indices are character offsets, which is what a caller needs to
        // highlight after the string has been copied into an attributed string.
        let match = FuzzyMatcher.match(query: "wsh", candidate: "website/shop")
        #expect(match?.matchedIndices == [0, 8, 9])
    }

    @Test func matchesAQueryAsLongAsTheCandidate() {
        // The whole string, which is what the owner typing a full project name
        // produces. An off-by-one in the anchor loop shows up here and nowhere
        // else.
        #expect(FuzzyMatcher.match(query: "baia", candidate: "baia")?.matchedIndices == [0, 1, 2, 3])
    }

    @Test func returnsNilForAQueryLongerThanTheCandidate() {
        #expect(FuzzyMatcher.match(query: "baiaa", candidate: "baia") == nil)
    }
}
