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
