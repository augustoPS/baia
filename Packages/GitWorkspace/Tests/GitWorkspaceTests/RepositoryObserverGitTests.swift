import Foundation
import Testing

@testable import GitWorkspace

/// A reader that forwards to a real `GitCommand` and counts each kind of read, so
/// a test can say how many `git` processes each mechanism cost.
private final class CountingReader: RepositoryReading, @unchecked Sendable {
    private let command: GitCommand
    private let lock = NSLock()
    private var counts = (status: 0, tree: 0, defaultBranch: 0)

    init(_ command: GitCommand) {
        self.command = command
    }

    var statusReads: Int { lock.withLock { counts.status } }
    var treeReads: Int { lock.withLock { counts.tree } }
    var defaultBranchReads: Int { lock.withLock { counts.defaultBranch } }

    func readStatus(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryStatusRead {
        lock.withLock { counts.status += 1 }
        return command.readStatus(ofRepositoryRoot: root, cancellation: cancellation)
    }

    func readTree(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryTreeRead {
        lock.withLock { counts.tree += 1 }
        return command.readTree(ofRepositoryRoot: root, cancellation: cancellation)
    }

    func readDefaultBranch(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryDefaultBranchRead {
        lock.withLock { counts.defaultBranch += 1 }
        return command.readDefaultBranch(ofRepositoryRoot: root, cancellation: cancellation)
    }
}

/// The observer over real repositories and a real `git`, with a spawn counter.
///
/// What the scripted suite cannot say: that a clean checkout with no event and
/// no status difference still reaches the tree, that an empty repository costs
/// one tree process and no more, and that linked worktrees and default branches
/// come out of real metadata.
@Suite(.serialized) @MainActor final class RepositoryObserverGitTests {
    let fixture: DirectoryFixture
    /// The fixture's own git, so its spawns never land in the counts under test.
    private let setup = GitCommand()

    init() throws {
        fixture = try DirectoryFixture()
    }

    @discardableResult
    private func run(_ arguments: [String], in path: String) -> String? {
        setup.output(
            of: [
                "-c", "user.name=baia",
                "-c", "user.email=baia@example.invalid",
                "-c", "commit.gpgsign=false",
                "-c", "init.defaultBranch=main",
            ] + arguments,
            in: fixture.root.appending(path: path)
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

    private func policy(
        statusInterval: TimeInterval = 0.1,
        treeRefreshInterval: TimeInterval = 60
    ) -> RepositoryObservationPolicy {
        RepositoryObservationPolicy(
            statusInterval: statusInterval,
            treeRefreshInterval: treeRefreshInterval,
            treeCoalesceWindow: 0.02,
            minimumTreeReadSpacing: 0.05,
            failureBackoffBase: 0.05,
            failureBackoffCap: 0.2
        )
    }

    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func names(_ snapshot: RepositorySnapshot?) -> [String] {
        (snapshot?.tree.nodes.map(\.name) ?? []).sorted()
    }

    /// **Empty repository, one process.** Six status polls later the tree has
    /// been read exactly once, the default branch exactly once, and the spawn
    /// counter agrees with the sum.
    @Test func anEmptyRepositoryCostsOneTreeProcessWhileStatusKeepsPolling() async throws {
        let empty = try fixture.directory("empty")
        run(["init", "--quiet"], in: "empty")
        let command = GitCommand()
        let reader = CountingReader(command)
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let root = RepositoryRoot(empty)
        var redraws = 0

        let subscription = observer.observe(root) { _ in
            redraws += 1
            _ = observer.snapshot(of: root)
        }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusReads >= 6 })

        #expect(observer.snapshot(of: root)?.tree == .empty)
        #expect(observer.snapshot(of: root)?.status?.head == .unborn("main"))
        #expect(reader.treeReads == 1)
        #expect(reader.defaultBranchReads == 1)
        // The reader counts a read as it starts and the command counts it as it
        // spawns, so a status read in flight at this instant is in the first
        // count and not yet in the second. Read the reader last, so the spawn
        // count can trail it by at most that one read.
        let spawned = command.spawnCount
        let started = reader.statusReads + reader.treeReads + reader.defaultBranchReads
        #expect(spawned == started || spawned == started - 1, "spawned \(spawned), started \(started)")
        #expect(redraws >= 2)
    }

    /// **A clean checkout, no events.** Switching to a branch whose tracked
    /// files differ leaves the status clean on both sides; the head change is
    /// what reaches the tree.
    @Test func aCleanCheckoutChangeReachesTheTreeThroughTheStatusPoll() async throws {
        let root = try repository("proj")
        run(["checkout", "--quiet", "-b", "feature"], in: "proj")
        try fixture.file("proj/feature.txt", contents: "f\n")
        run(["add", "-A"], in: "proj")
        run(["commit", "--quiet", "--no-verify", "-m", "feature"], in: "proj")
        run(["checkout", "--quiet", "main"], in: "proj")
        let reader = CountingReader(GitCommand())
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let observed = RepositoryRoot(root)

        let subscription = observer.observe(observed) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { self.names(observer.snapshot(of: observed)) == ["c.txt"] })
        let treeReadsBefore = reader.treeReads

        run(["checkout", "--quiet", "feature"], in: "proj")

        #expect(await eventually { self.names(observer.snapshot(of: observed)) == ["c.txt", "feature.txt"] })
        #expect(observer.snapshot(of: observed)?.status?.head == .branch("feature"))
        #expect(observer.snapshot(of: observed)?.changes.isEmpty == true)
        #expect(reader.treeReads == treeReadsBefore + 1)

        run(["checkout", "--quiet", "main"], in: "proj")

        #expect(await eventually { self.names(observer.snapshot(of: observed)) == ["c.txt"] })
    }

    /// **Same head, clean status, different tree.** A commit on the current
    /// branch adds a tracked file and leaves nothing for the status compare to
    /// see. The periodic refresh is the only thing that can catch it, and does.
    @Test func aChangeWithTheSameHeadAndACleanStatusIsCaughtByThePeriodicRefresh() async throws {
        let root = try repository("proj")
        let reader = CountingReader(GitCommand())
        let observer = RepositoryObserver(reader: reader, policy: policy(treeRefreshInterval: 0.2))
        let observed = RepositoryRoot(root)

        let subscription = observer.observe(observed) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { self.names(observer.snapshot(of: observed)) == ["c.txt"] })

        try fixture.file("proj/later.txt", contents: "l\n")
        run(["add", "-A"], in: "proj")
        run(["commit", "--quiet", "--no-verify", "-m", "later"], in: "proj")

        #expect(await eventually { self.names(observer.snapshot(of: observed)) == ["c.txt", "later.txt"] })
        #expect(observer.snapshot(of: observed)?.status?.head == .branch("main"))
    }

    @Test func linkedWorktreeAndDefaultBranchStateArePublished() async throws {
        let main = try repository("main")
        run(["branch", "feature"], in: "main")
        run(["worktree", "add", "--quiet", "../linked", "feature"], in: "main")
        let linked = fixture.root.appending(path: "linked")
        let observer = RepositoryObserver(reader: CountingReader(GitCommand()), policy: policy(statusInterval: 60))
        let mainRoot = RepositoryRoot(main)
        let linkedRoot = RepositoryRoot(linked)

        let onMain = observer.observe(mainRoot) { _ in }
        let onLinked = observer.observe(linkedRoot) { _ in }
        defer { onMain.cancel(); onLinked.cancel() }
        #expect(await eventually {
            observer.snapshot(of: mainRoot)?.health == .ok && observer.snapshot(of: linkedRoot)?.health == .ok
        })

        let mainSnapshot = observer.snapshot(of: mainRoot)
        let linkedSnapshot = observer.snapshot(of: linkedRoot)
        #expect(mainSnapshot?.isLinkedWorktree == false)
        #expect(linkedSnapshot?.isLinkedWorktree == true)
        #expect(mainSnapshot?.defaultBranch == .known(nil))
        #expect(mainSnapshot?.isOnDefaultBranch == true)
        #expect(linkedSnapshot?.status?.head == .branch("feature"))
        #expect(linkedSnapshot?.isOnDefaultBranch == false)
        #expect(observer.observedRoots.count == 2)
    }

    /// **A remote added after observation began, then its HEAD moved.** Neither
    /// reaches the published default branch through polling; each reaches it
    /// through `invalidateStatus`, which is where the metadata adapter and the
    /// refresh command arrive.
    @Test func aNewRemoteAndAChangedRemoteHeadReachTheDefaultBranchOnInvalidation() async throws {
        let root = try repository("proj")
        run(["branch", "feature"], in: "proj")
        try fixture.directory("remote.git")
        run(["init", "--quiet", "--bare"], in: "remote.git")
        let reader = CountingReader(GitCommand())
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let observed = RepositoryRoot(root)

        let subscription = observer.observe(observed) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { observer.snapshot(of: observed)?.defaultBranch == .known(nil) })
        #expect(await eventually { reader.statusReads >= 3 })
        #expect(reader.defaultBranchReads == 1)

        run(["remote", "add", "origin", fixture.root.appending(path: "remote.git").path(percentEncoded: false)], in: "proj")
        run(["push", "--quiet", "origin", "main", "feature"], in: "proj")
        run(["remote", "set-head", "origin", "main"], in: "proj")
        let polls = reader.statusReads
        #expect(await eventually { reader.statusReads >= polls + 2 })
        #expect(observer.snapshot(of: observed)?.defaultBranch == .known(nil))
        #expect(reader.defaultBranchReads == 1)

        observer.invalidateStatus(of: observed)
        #expect(await eventually { observer.snapshot(of: observed)?.defaultBranch == .known("main") })
        #expect(reader.defaultBranchReads == 2)
        #expect(observer.snapshot(of: observed)?.isOnDefaultBranch == true)

        run(["remote", "set-head", "origin", "feature"], in: "proj")
        observer.refresh(observed)
        #expect(await eventually { observer.snapshot(of: observed)?.defaultBranch == .known("feature") })
        #expect(reader.defaultBranchReads == 3)
        // On `main` with the default now `feature`: the tab would say so.
        #expect(observer.snapshot(of: observed)?.isOnDefaultBranch == false)
    }

    /// **First subscriber used a symlink; that spelling then dies.** A second
    /// subscriber on the physical path must keep seeing the live repository.
    /// Reading through the dead alias would publish `.notARepository` for both.
    @Test func deletingAFirstSubscriberSymlinkDoesNotPoisonAPhysicalPathSubscriber() async throws {
        let physical = try repository("proj")
        try fixture.file("proj/physical-only.txt", contents: "p\n")
        run(["add", "-A"], in: "proj")
        run(["commit", "--quiet", "--no-verify", "-m", "physical"], in: "proj")
        let link = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: physical)

        let observer = RepositoryObserver(
            reader: CountingReader(GitCommand()),
            policy: policy(statusInterval: 60, treeRefreshInterval: 60)
        )
        let viaLink = RepositoryRoot(link)
        let viaPhysical = RepositoryRoot(physical)
        #expect(viaLink == viaPhysical)
        #expect(viaLink.path == link.path(percentEncoded: false))

        let first = observer.observe(viaLink) { _ in }
        let second = observer.observe(viaPhysical) { _ in }
        defer { first.cancel(); second.cancel() }
        #expect(await eventually { self.names(observer.snapshot(of: viaPhysical)).contains("physical-only.txt") })
        #expect(observer.snapshot(of: viaPhysical)?.root.path == viaLink.path)

        try FileManager.default.removeItem(at: link)
        try fixture.file("proj/after-delete.txt", contents: "still-there\n")
        run(["add", "-A"], in: "proj")
        run(["commit", "--quiet", "--no-verify", "-m", "after-delete"], in: "proj")
        observer.refresh(viaPhysical)

        #expect(await eventually { self.names(observer.snapshot(of: viaPhysical)).contains("after-delete.txt") })
        // The tree and the status are read on their own cadences, so the tree
        // landing does not mean the status has. Wait for the status too before
        // asserting on health and head.
        #expect(await eventually { observer.snapshot(of: viaPhysical)?.status?.head == .branch("main") })
        #expect(observer.snapshot(of: viaPhysical)?.health == .ok)
        #expect(observer.snapshot(of: viaPhysical)?.isGone != true)
        #expect(observer.snapshot(of: viaPhysical)?.status?.head == .branch("main"))
        #expect(observer.snapshot(of: viaPhysical)?.root.path == viaLink.path)
    }

    /// **First subscriber's alias is retargeted at a different repository.**
    /// Shared reads must keep answering for the physical identity captured at
    /// subscribe time, not for whatever now lives under the old spelling.
    @Test func retargetingAFirstSubscriberSymlinkDoesNotReadTheNewRepository() async throws {
        let original = try repository("original")
        try fixture.file("original/from-original.txt", contents: "a\n")
        run(["add", "-A"], in: "original")
        run(["commit", "--quiet", "--no-verify", "-m", "original"], in: "original")
        let other = try repository("other")
        try fixture.file("other/from-other.txt", contents: "b\n")
        run(["add", "-A"], in: "other")
        run(["commit", "--quiet", "--no-verify", "-m", "other"], in: "other")
        run(["checkout", "--quiet", "-b", "other-branch"], in: "other")

        let link = fixture.root.appending(path: "moving")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)

        let observer = RepositoryObserver(
            reader: CountingReader(GitCommand()),
            policy: policy(statusInterval: 60, treeRefreshInterval: 60)
        )
        let viaLink = RepositoryRoot(link)
        let viaOriginal = RepositoryRoot(original)
        let first = observer.observe(viaLink) { _ in }
        let second = observer.observe(viaOriginal) { _ in }
        defer { first.cancel(); second.cancel() }
        #expect(await eventually { self.names(observer.snapshot(of: viaOriginal)).contains("from-original.txt") })

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try fixture.file("original/after-retarget.txt", contents: "still-a\n")
        run(["add", "-A"], in: "original")
        run(["commit", "--quiet", "--no-verify", "-m", "after-retarget"], in: "original")
        observer.refresh(viaOriginal)

        #expect(await eventually {
            self.names(observer.snapshot(of: viaOriginal)).contains("after-retarget.txt")
        })
        // As above: the tree landing does not imply the status read has finished.
        #expect(await eventually { observer.snapshot(of: viaOriginal)?.status?.head == .branch("main") })
        let snapshot = observer.snapshot(of: viaOriginal)
        #expect(snapshot?.health == .ok)
        #expect(snapshot?.status?.head == .branch("main"))
        #expect(names(snapshot).contains("from-original.txt"))
        #expect(!names(snapshot).contains("from-other.txt"))
        #expect(snapshot?.root.path == viaLink.path)
    }

    @Test func aPlainDirectoryPublishesGoneHealthAndAFailedTree() async throws {
        let plain = try fixture.directory("notes")
        let observer = RepositoryObserver(reader: CountingReader(GitCommand()), policy: policy(statusInterval: 60))
        let root = RepositoryRoot(plain)

        let subscription = observer.observe(root) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { observer.snapshot(of: root)?.isGone == true })

        let snapshot = observer.snapshot(of: root)
        #expect(snapshot?.status == nil)
        #expect(snapshot?.changes.isEmpty == true)
        #expect(await eventually { observer.snapshot(of: root)?.tree == .failed(.notARepository, attempts: 1) })
    }
}
