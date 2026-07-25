import Foundation

/// Orders the palette's projects for a query.
public enum ProjectRanker {
    /// `recency` maps a project path to a use count; higher wins ties.
    ///
    /// Matching runs against `relativePath`, not `displayName`. `website/shop` and
    /// `website/admin` share no distinguishing display name worth typing, and the
    /// path is what the owner already types in a shell. It is also what makes
    /// `wsh` find `website/shop`.
    ///
    /// Projects that do not match are dropped rather than sorted last, so the
    /// palette shrinks as the query grows instead of keeping a tail nobody wants.
    public static func rank(_ projects: [Project], query: String, recency: [String: Int]) -> [Project] {
        var scored: [(project: Project, score: Int, uses: Int)] = []
        for project in projects {
            guard let match = FuzzyMatcher.match(query: query, candidate: project.relativePath) else {
                continue
            }
            let key = RecentProjects.key(of: project.url.path(percentEncoded: false))
            scored.append((project, match.score, recency[key] ?? 0))
        }

        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.uses != right.uses { return left.uses > right.uses }

            // `sorted(by:)` is not a stable sort, so the comparator has to be a
            // total order. Without these last two the order of two equally ranked
            // projects is whatever the sort happened to do, and it can differ
            // between two calls over the same array: the highlighted row would
            // move under the owner's fingers as he types a character that changes
            // nothing about the ranking.
            //
            // Shorter first, because a shorter path that scored the same reached
            // that score with less noise around the match.
            if left.project.relativePath.count != right.project.relativePath.count {
                return left.project.relativePath.count < right.project.relativePath.count
            }
            return left.project.relativePath < right.project.relativePath
        }.map(\.project)
    }
}
