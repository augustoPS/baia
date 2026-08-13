import Foundation
import Testing

@testable import GitWorkspace

/// How often `git` is allowed to run.
///
/// The rest of this suite asks what the commands return. These ask how many times
/// they run, which is the property the sidebar's whole design rests on and the one
/// nothing else would catch: a doubled read returns exactly the same answer and
/// shows up only as heat and battery, on a path that fires per pane, per poll, and
/// per focus change.
///
/// Each test owns its own `GitCommand` through the suite's fixture, so the counts
/// here cannot be disturbed by another suite spawning git in parallel. That is why
/// the counter is per command rather than per process.
@Suite final class SpawnBudgetTests {
    let fixture: DirectoryFixture
    let git = GitCommand()

    init() throws {
        fixture = try DirectoryFixture()
    }

    @discardableResult
    private func run(_ arguments: [String], in path: String = "") -> String? {
        git.output(
            of: [
                "-c", "user.name=baia",
                "-c", "user.email=baia@example.invalid",
                "-c", "commit.gpgsign=false",
                "-c", "init.defaultBranch=main",
            ] + arguments,
            in: path.isEmpty ? fixture.root : fixture.root.appending(path: path)
        )
    }

    private func repository(_ path: String) throws -> URL {
        let root = try fixture.directory(path)
        run(["init", "--quiet"], in: path)
        try fixture.file("\(path)/c.txt", contents: "base\n")
        run(["add", "-A"], in: path)
        run(["commit", "--quiet", "--no-verify", "-m", "base"], in: path)
        return root
    }

    /// The reason `read(ofRepositoryRoot:)` exists at all. The capsule wants counts
    /// and the sidebar wants paths, they come out of the same bytes, and asking
    /// twice would double the busiest git call in the app.
    @Test func oneReadServesBothTheStatusAndTheChanges() throws {
        let root = try repository("proj")
        try fixture.file("proj/dirty.txt", contents: "x\n")

        git.resetSpawnCount()
        let (status, changes) = git.read(ofRepositoryRoot: root)

        #expect(git.spawnCount == 1)
        #expect(status != nil)
        #expect(changes.contains { $0.path == "dirty.txt" })
    }

    /// The shape this replaced, kept as the comparison that gives the number above
    /// its meaning: one call rather than two, on a path that runs every two seconds
    /// for every pane in every window.
    @Test func askingSeparatelyWouldCostTwice() throws {
        let root = try repository("proj")

        git.resetSpawnCount()
        _ = git.status(ofRepositoryRoot: root)
        _ = git.files(ofRepositoryRoot: root)

        #expect(git.spawnCount == 2)
    }

    @Test func theFileTreeIsOneInvocation() throws {
        let root = try repository("proj")
        try fixture.file("proj/Sources/app.swift", contents: "")

        git.resetSpawnCount()
        _ = git.files(ofRepositoryRoot: root)

        #expect(git.spawnCount == 1)
    }

    /// A directory that is not a repository must not be retried inside one call.
    @Test func aFailedReadIsStillOneInvocation() throws {
        let plain = try fixture.directory("notes")

        git.resetSpawnCount()
        _ = git.read(ofRepositoryRoot: plain)

        #expect(git.spawnCount == 1)
    }
}

/// The rule that keeps focus changes free.
///
/// Pure, so it is tested here rather than in a probe that would need a window, live
/// panes and Metal to drive the same decision.
@Suite struct FileTreeCacheTests {
    private let root = URL(filePath: "/tmp/repo")
    private let other = URL(filePath: "/tmp/elsewhere")

    @Test func theFirstAskClaimsAReadAndTheSecondDoesNot() {
        var cache = FileTreeCache()
        let first = cache.claimRead(of: root)
        // The read is out and has not landed. This is the case a busy grid produces
        // and the one a naive "is it cached yet" check gets wrong.
        let second = cache.claimRead(of: root)
        #expect(first)
        #expect(!second)
    }

    @Test func nothingIsDrawnUntilAReadLands() {
        var cache = FileTreeCache()
        _ = cache.claimRead(of: root)
        #expect(cache.tree(for: root) == nil)

        cache.store([FileTreeNode(name: "a", path: "a", isDirectory: false, children: [])], for: root)
        #expect(cache.tree(for: root)?.map(\.name) == ["a"])
    }

    /// A hundred focus changes across a repository already read: zero claims, which
    /// is the assertion the sidebar's design rests on.
    @Test func aHundredFocusChangesClaimNothing() {
        var cache = FileTreeCache()
        _ = cache.claimRead(of: root)
        cache.store([], for: root)

        var claims = 0
        for _ in 0 ..< 100 where cache.claimRead(of: root) { claims += 1 }

        #expect(claims == 0)
    }

    /// Two panes in one repository are two askers of one question.
    @Test func repositoriesAreCachedSeparatelyAndIndependently() {
        var cache = FileTreeCache()
        _ = cache.claimRead(of: root)
        cache.store([], for: root)

        let again = cache.claimRead(of: root)
        let fresh = cache.claimRead(of: other)
        #expect(!again)
        #expect(fresh)
    }

    /// A read that produced nothing must not refuse every later ask. A repository
    /// mid-clone resolves itself, and a cache that never retried would need a
    /// relaunch to notice.
    @Test func aFailedReadCanBeRetried() {
        var cache = FileTreeCache()
        _ = cache.claimRead(of: root)
        cache.forget(root)
        let retried = cache.claimRead(of: root)
        #expect(retried)
    }

    @Test func invalidatingMakesTheNextAskReadAgain() {
        var cache = FileTreeCache()
        _ = cache.claimRead(of: root)
        cache.store([], for: root)
        cache.invalidate(root)
        let reread = cache.claimRead(of: root)
        #expect(reread)
    }
}
