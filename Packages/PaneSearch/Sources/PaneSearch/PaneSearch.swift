import Foundation

/// The matching rule, in one place.
public enum PaneSearch {
    /// Every occurrence in every line, in reading order, up to `limit`.
    ///
    /// Every occurrence rather than one per line, because two hits on one line
    /// are two places the owner may want to go, and collapsing them makes the
    /// second unreachable from the panel.
    ///
    /// The limit exists because a needle like `e` finds 420,000 hits in a
    /// 60,000 line scrollback, and the caller turns every hit into a row: that
    /// measured 0.9 seconds to match plus 1.2 to build the rows, on the main
    /// thread, for a list that draws eight of them and that nobody reaches the
    /// end of. Stopping early costs the exact count, which the caller reports as
    /// `200+`, and that is a truer answer than a number nobody would read.
    public static func matches(
        in lines: [String],
        query: SearchQuery,
        limit: Int = .max
    ) -> [LineMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }
        var found: [LineMatch] = []
        for (index, line) in lines.enumerated() {
            found.append(contentsOf: occurrences(
                in: line,
                at: index,
                query: query,
                limit: limit - found.count
            ))
            if found.count >= limit { return found }
        }
        return found
    }

    /// One line's hits, as matches.
    ///
    /// The walk itself belongs to ``SearchQuery/hits(in:limit:)``, next to the
    /// case rule it obeys and the fast path that rule picks. This is the part
    /// that knows which line it was, which is all the pane search adds.
    private static func occurrences(
        in line: String,
        at index: Int,
        query: SearchQuery,
        limit: Int
    ) -> [LineMatch] {
        query.hits(in: line, limit: limit).map {
            LineMatch(lineIndex: index, line: line, range: $0)
        }
    }
}
