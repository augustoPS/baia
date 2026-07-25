import Foundation
import Testing

@testable import GitWorkspace

/// Ranked against the real project list of this workspace, not against invented
/// names. A scoring change that looks harmless in isolation shows up here as the
/// wrong site coming first for a two letter query, which is the only way the owner
/// experiences this code.
@Suite struct ProjectRankerTests {
    private static let relativePaths = [
        "baia",
        "lifetracker",
        "vault",
        "scripts",
        "photos",
        "skills",
        "superpowers",
        "claude-dotfiles",
        "website/pasqualo.to",
        "website/shop",
        "website/admin",
        "website/finances",
    ]

    private let projects: [Project] = ProjectRankerTests.relativePaths.map { path in
        Project(
            url: URL(filePath: "/Users/pasqualotto/Projects/\(path)", directoryHint: .isDirectory),
            displayName: (path as NSString).lastPathComponent,
            kind: .repository,
            relativePath: path
        )
    }

    private func ranked(_ query: String, recency: [String: Int] = [:]) -> [String] {
        ProjectRanker.rank(projects, query: query, recency: recency).map(\.relativePath)
    }

    @Test func ranksWebsiteShopFirstForSh() {
        // The ordering the brief names. `superpowers` starts with the `s` and holds
        // no `h` at all, so it must not appear either: a matcher that scored
        // partial subsequences would put it above the site.
        let results = ranked("sh")
        #expect(results.first == "website/shop")
        #expect(!results.contains("superpowers"))
    }

    @Test func ranksWebsiteFinancesFirstForFin() {
        #expect(ranked("fin").first == "website/finances")
    }

    @Test func ranksBaiaFirstForBa() {
        // `website/admin` and `website/pasqualo.to` both hold a `b` then an `a`, so
        // this is a real contest rather than the only match. Asserting the whole
        // head of the ordering rather than membership is what makes it one.
        #expect(Array(ranked("ba").prefix(3)) == ["baia", "website/admin", "website/pasqualo.to"])
    }

    @Test func findsWebsiteShopForWsh() {
        // A query spanning the path separator, which is how the owner reaches a
        // nested site without typing the container. Matching on `displayName` alone
        // would find nothing here.
        #expect(ranked("wsh") == ["website/shop"])
    }

    @Test func ranksTheWholeWebsiteFamilyForTheContainerName() {
        // All four sites and nothing else, in a fixed order. The tie between them
        // is settled by path length and then alphabetically, which is what keeps
        // the list from reshuffling between keystrokes.
        #expect(ranked("website/") == [
            "website/shop",
            "website/admin",
            "website/finances",
            "website/pasqualo.to",
        ])
    }

    @Test func dropsProjectsThatDoNotMatch() {
        // Dropped rather than sorted last, so the palette shrinks as the query
        // grows instead of keeping a tail nobody wants to arrow through.
        #expect(ranked("zzz").isEmpty)
    }

    @Test func returnsEveryProjectForAnEmptyQuery() {
        #expect(ranked("").count == Self.relativePaths.count)
    }

    @Test func ordersAnEmptyQueryByRecencyFirst() {
        // Before the first keystroke there is no score to sort on, so the file of
        // use counts is the whole ordering. A palette that opened alphabetically
        // would put `baia` first forever.
        let recency = [
            "/Users/pasqualotto/Projects/website/shop": 9,
            "/Users/pasqualotto/Projects/vault": 4,
        ]
        #expect(Array(ranked("", recency: recency).prefix(2)) == ["website/shop", "vault"])
    }

    @Test func recencyBreaksATieBetweenEquallyScoredProjects() {
        // `website/admin` and `website/finances` score identically for `website/`,
        // and without recency the shorter path wins. This is the one assertion that
        // fails if the recency term is dropped from the comparator.
        let recency = ["/Users/pasqualotto/Projects/website/finances": 12]
        #expect(ranked("website/", recency: recency).first == "website/finances")
    }

    @Test func recencyNeverOutranksAScore() {
        // A heavily used project that matches worse still loses. Letting the count
        // dominate makes the palette ignore what the owner is typing, which is the
        // failure everyone who has used a frecency-first launcher recognises.
        let recency = ["/Users/pasqualotto/Projects/superpowers": 500]
        #expect(ranked("sh", recency: recency).first == "website/shop")
    }

    @Test func looksRecencyUpUnderThePathWithNoTrailingSlash() {
        // `Project.url` is a directory URL, so its rendered path ends in a slash
        // while every key `RecentProjects` stores does not. Looking up the rendered
        // path verbatim finds nothing, silently, and reads as recency never having
        // been recorded: `baia` would come first here on path length alone.
        #expect(ranked("", recency: ["/Users/pasqualotto/Projects/vault": 7]).first == "vault")
    }

    @Test func ordersEquallyRankedProjectsTheSameWayEveryTime() {
        // `sorted(by:)` is not stable, so the comparator has to be a total order.
        // Ranking the reversed list must give the same answer as ranking the list,
        // and it does not when two entries compare equal.
        let forward = ProjectRanker.rank(projects, query: "s", recency: [:]).map(\.relativePath)
        let backward = ProjectRanker.rank(projects.reversed(), query: "s", recency: [:])
            .map(\.relativePath)
        #expect(forward == backward)
    }

    @Test func ranksAWorktreeUnderTheRepositoryItBelongsTo() {
        // A worktree's relative path carries the layout directory, so a query for
        // the agent's hex reaches it while a query for the repository name reaches
        // the repository first: the worktree path is longer and scores the extra
        // characters as gap.
        let repository = Project(
            url: URL(filePath: "/Users/pasqualotto/Projects/baia", directoryHint: .isDirectory),
            displayName: "baia",
            kind: .repository,
            relativePath: "baia"
        )
        let worktree = Project(
            url: URL(
                filePath: "/Users/pasqualotto/Projects/baia/.claude/worktrees/agent-4f21",
                directoryHint: .isDirectory
            ),
            displayName: "baia/agent-4f21",
            kind: .worktree(ofRepositoryNamed: "baia"),
            relativePath: "baia/.claude/worktrees/agent-4f21"
        )
        let ranked = ProjectRanker.rank([worktree, repository], query: "baia", recency: [:])
        #expect(ranked.map(\.displayName) == ["baia", "baia/agent-4f21"])
        #expect(ProjectRanker.rank([repository, worktree], query: "4f21", recency: [:])
            .map(\.displayName) == ["baia/agent-4f21"])
    }
}
