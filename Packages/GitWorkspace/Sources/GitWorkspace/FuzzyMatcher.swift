import Foundation

/// What a query matched in a candidate, and how well.
public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    /// Character offsets into the candidate, ascending. Offsets rather than
    /// `String.Index` values, because a caller highlights them after copying the
    /// string into an attributed one, which invalidates indices taken from the
    /// original.
    public let matchedIndices: [Int]

    public init(score: Int, matchedIndices: [Int]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// Subsequence matching for the project palette.
public enum FuzzyMatcher {
    /// Nil when the query is not a subsequence of the candidate, ignoring case.
    ///
    /// The score exists only to be compared against other candidates and means
    /// nothing on its own. It rewards a match at a word boundary, a run of
    /// consecutive matches, and a match inside the last path component; it
    /// penalises the gap between matches; and it breaks a tie in favour of the
    /// candidate whose case matches the query exactly.
    ///
    /// The best placement is found rather than the first one. A greedy pass taking
    /// the earliest occurrence of each query character scores `wsh` against
    /// `website/shop` as the `w` of `website`, the `s` of `website`, and the `h` of
    /// `shop`: a five character gap across a slash instead of the consecutive pair
    /// sitting in the basename, worth a third of the score and a highlight in the
    /// wrong half of the string.
    public static func match(query: String, candidate: String) -> FuzzyMatch? {
        let queryCharacters = Array(query)

        // An empty query matches everything with score 0, so the palette shows the
        // whole project list before the first keystroke and the ranking falls
        // through to recency. Nil here would open the palette blank.
        guard !queryCharacters.isEmpty else { return FuzzyMatch(score: 0, matchedIndices: []) }

        let candidateCharacters = Array(candidate)
        let loweredQuery = queryCharacters.map { Character($0.lowercased()) }
        let loweredCandidate = candidateCharacters.map { Character($0.lowercased()) }

        // Everything at or after the last slash is the basename.
        let lastComponentStart = (loweredCandidate.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        // `best[index]` is the highest score for matching the query up to the
        // current character with that character landing on `candidate[index]`, or
        // nil when it cannot land there. `cameFrom[position][index]` remembers
        // which index the previous query character used, which is the only way to
        // report the winning placement rather than just its score.
        var best: [Int?] = Array(repeating: nil, count: candidateCharacters.count)
        var cameFrom = Array(
            repeating: Array(repeating: -1, count: candidateCharacters.count),
            count: queryCharacters.count
        )

        for position in queryCharacters.indices {
            var next: [Int?] = Array(repeating: nil, count: candidateCharacters.count)
            for index in candidateCharacters.indices
                where loweredCandidate[index] == loweredQuery[position] {
                let landing = landingScore(
                    at: index,
                    matching: queryCharacters[position],
                    in: candidateCharacters,
                    lastComponentStart: lastComponentStart
                )
                if position == 0 {
                    // No gap penalty for the distance from the start of the
                    // string. The brief's rule is a penalty between matches, and
                    // charging for the offset as well would rank a short name
                    // above a long one twice, since the last-component bonus
                    // already covers it.
                    next[index] = landing
                    continue
                }

                var carried: Int?
                var from = -1
                for earlier in 0 ..< index {
                    guard let reached = best[earlier] else { continue }
                    let bridged = reached + (
                        index == earlier + 1
                            ? consecutiveBonus
                            : -gapPenalty * (index - earlier - 1)
                    )
                    if bridged > (carried ?? Int.min) {
                        carried = bridged
                        from = earlier
                    }
                }
                guard let carried else { continue }
                next[index] = carried + landing
                cameFrom[position][index] = from
            }
            best = next
        }

        var end = -1
        var score = Int.min
        for index in best.indices {
            guard let reached = best[index], reached > score else { continue }
            score = reached
            end = index
        }
        guard end >= 0 else { return nil }

        // Walked backwards from the winning end, so the indices describe the
        // placement that actually scored rather than a second greedy guess at it.
        var indices = [end]
        var position = queryCharacters.count - 1
        while position > 0 {
            let previous = cameFrom[position][indices[0]]
            indices.insert(previous, at: 0)
            position -= 1
        }
        return FuzzyMatch(score: score, matchedIndices: indices)
    }

    private static let boundaryBonus = 10
    private static let consecutiveBonus = 8
    private static let lastComponentBonus = 6
    private static let exactCaseBonus = 1
    private static let gapPenalty = 1

    /// Separators that make the character after them a word boundary. The
    /// workspace's own names need all four: `website/shop`, `claude-dotfiles`,
    /// `__pycache__`, `pasqualo.to`.
    private static let separators: Set<Character> = ["/", "-", "_", "."]

    /// What one matched character is worth where it landed, independent of what
    /// came before it.
    private static func landingScore(
        at index: Int,
        matching queryCharacter: Character,
        in candidate: [Character],
        lastComponentStart: Int
    ) -> Int {
        var score = 0
        if isBoundary(index, in: candidate) { score += boundaryBonus }
        if index >= lastComponentStart { score += lastComponentBonus }

        // Case is consulted last and worth one point, so it can only settle a tie
        // between two structurally identical matches. Weighting it higher would
        // rank `Sources` above `website/shop` for `s` on nothing but a capital
        // letter.
        if candidate[index] == queryCharacter { score += exactCaseBonus }
        return score
    }

    /// The start of the string, the character after a separator, or a lowercase to
    /// uppercase transition.
    ///
    /// The camel case half is what lets `gw` reach the `W` of `GitWorkspace`. A
    /// Swift package directory carries no separator at all, so a separator-only
    /// rule scores every character of it as mid-word and it loses to any candidate
    /// with a slash in it.
    private static func isBoundary(_ index: Int, in candidate: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = candidate[index - 1]
        if separators.contains(previous) { return true }
        return previous.isLowercase && candidate[index].isUppercase
    }
}
